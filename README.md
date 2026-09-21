# Cookie Munch Ruby SDK

A small, **dependency-free** (stdlib-only) Ruby client for the [Cookie Munch](https://cookiemunch.net)
Developer API (the `/v1` surface), plus a helper for the public consent-ingest
endpoint.

- Ruby 3.0+ (tested on 4.0)
- No runtime dependencies — just `net/http` + `json` from the standard library
- Bearer + `X-API-Key` auth
- Resource groups that map one-to-one onto the `/v1` REST surface
- Raises `CookieMunch::ApiError` (with `status`, `body`, and `code`) on any non-2xx

## Installation

Add to your Gemfile:

```ruby
gem "cookiemunch"
```

Or build and install locally from this directory:

```bash
gem build cookiemunch.gemspec
gem install ./cookiemunch-0.1.0.gem
```

## Quick start

```ruby
require "cookiemunch"

cm = CookieMunch::Client.new(api_key: "fck_your_key")
# base_url defaults to https://api.cookiemunch.net; override for self-hosted:
# cm = CookieMunch::Client.new(api_key: "fck_…", base_url: "https://cmp.example.com")

cm.me
# => { "orgId" => "org_123", "plan" => "pro", "keyPrefix" => "fck_ab" }

cm.sites.list
# => [ { "cbid" => "…", "orgId" => "…", "domain" => "example.com", "verified" => true, … }, … ]
```

The org is derived server-side from the API key, so you never pass an org id.
Every response is returned as **parsed JSON** — a `Hash` or `Array` of `Hash`
with string keys, exactly as the API sends it. CSV exports come back as a `String`.

## Authentication

The key is sent on every request as both `Authorization: Bearer <key>` and
`X-API-Key: <key>`.

## Error handling

Any non-2xx response raises `CookieMunch::ApiError`:

```ruby
begin
  cm.sites.get("unknown")
rescue CookieMunch::ApiError => e
  e.status  # => 404 (Integer)
  e.message # => the server's `error` field, or "request failed with status 404"
  e.code    # => the server's `code` field when present, else nil
  e.body    # => the raw response body String
end
```

`CookieMunch::ApiError < CookieMunch::Error < StandardError`.

## The consent-log helper (public ingest)

`log_consent` posts to the **public** `POST /api/v1/consent` endpoint — the same
endpoint the browser embed beacons to. Use it to record consent captured
server-side or outside the browser. `stamp` (a unique receipt id) and `utc`
(epoch-ms) are auto-generated when omitted.

```ruby
cm.log_consent(
  cbid: "cbid_123",
  choices: { statistics: true, marketing: false }, # preferences defaults to false
  method: "explicit",                              # or "implied"
  url: "https://example.com/pricing",
  region: "eu"                                     # optional; sent as X-CookieMunch-Region
)
# => nil (the endpoint returns 204 No Content)
```

Optional fields are forwarded when supplied: `ver:` (default 1), `stamp:`,
`utc:`, `tc_string:`, `gpp_string:`, `purposes:` (a `{ name => bool }` map),
`subject_policy_hash:`, and `variant:` (for A/B).

## Method surface

Top-level: `me`, `usage`, `audit(limit: nil)`, `log_consent(...)`.

### `sites`
`list`, `create(domain:, cbid: nil)`, `get(cbid)`, `delete(cbid)`,
`get_config(cbid)`, `put_config(cbid, config)`, `cookies(cbid)`, `scan(cbid)`,
`scan_status(cbid)`, `ab(cbid)`, `banner(cbid)`, `snippet(cbid, blocking_mode: nil, culture: nil)`,
`policy(cbid, contact_email:, effective_date:, jurisdictions:)` (Markdown `String`),
`set_ad_personalization(cbid, enabled:, default:, label:)`, `analyze_session(cbid, har:, requests:, consent:, gpc:)`,
`verify(cbid, method)`, `brand(cbid)`, `get_flow(cbid)`,
`edit_flow(cbid, operations)`, `set_flow(cbid, config)`.

### `consent`
`stats(cbid, from:, to:)`, `log(cbid, from:, to:, limit:)`,
`export(cbid, from:, to:)` (raw CSV `String`), `receipt(cbid, stamp)`,
`erase_subject(cbid, stamp)`, `export_subject(cbid, stamp)`.

### `dsar`
`list`, `create(type:, subject_email:, regulation:, note: nil)`,
`advance(id, to_status)`, `response(id)` (plain-text notice),
`erase(id, cbid, stamp)`, `export(id, cbid, stamp)`.

### `vendors`
`list`, `create(vendor_hash)`.

### `ropa`
`list`, `create(entry_hash)`, `export_csv` (CSV `String`).

### `brand_kits`
`list`, `create(kit_hash)`, `delete(id)`.

### `preferences`
`list`, `save(subject_id, purposes)`, `get(subject_id)`.

### `members`
`list`, `invite(email, role)`, `set_role(user_id, role)`, `remove(user_id)`.

### `keys`
`list`, `issue(name:, scopes:, cbids:, expires_in_days:)` — the issued `key` is returned **once**.
Pass `scopes` and/or `cbids` for a least-privilege key; a key locked with `cbids` works only
on those sites and on no org-wide endpoint. `roll(prefix)` rotates the secret (also
returned once); `update(prefix, name:, scopes:, cbids:)` changes only the fields sent.

### `webhooks`
`list`, `create(url:, events:, cbid: nil)`, `update(id, url:, events:, cbid:, active:)`,
`delete(id)`, `roll_secret(id)`, `test(id)`, `dead_letters`, `replay_dead_letter(id)`.

### `banners`
`list`, `create(name:, json:)`, `get(id)`, `update(id, name:, json:)`,
`delete(id)`, `assignments(id)`, `set_assignments(id, cbids)`, `publish(id)`.

### `org`
Requires an unscoped key that is not property-locked. `get`, `update(name:, logo_url:)`
— pass `logo_url: nil` to remove the logo (sent as JSON `null`); omit it to leave the
logo unchanged. Deleting the org is not available through the API.

### `assets`
`upload(data:, content_type:)` — uploads a banner image (base64, or a `data:` URL;
`image/png` | `image/jpeg` | `image/webp` | `image/gif` | `image/svg+xml`) and returns
its public URL, `{ "url" }`. Requires sites:write.

### The privacy platform

Identity, vault and profile reads are `POST`s on purpose: a person's identifiers travel in
the request body, never in a URL where logs and proxies would keep them. `identifiers` is
an Array of `{ "space" => …, "value" => … }`.

- `identity` — `resolve(identifiers)`, `link(identifiers)`, `cluster(subject_id)`
- `vault` — `record(identifiers, decisions)`, `current(identifiers)`, `permits(identifiers)`
- `profile` — `get(identifiers)`, `set_attributes(identifiers, attributes)`, `activate(identifiers, purpose)`
- `subscriptions` — `topics`, `set_topics(topics)`, `get(subject_id)`, `set(subject_id, topic, channel, opted_in)`, `unsubscribe_all(subject_id)`, `resubscribe(subject_id)`, `activation(subject_id, topics)`
- `assessments` — `templates`, `list`, `start(template, subject)`, `get(id)`, `answer(id, question_id, value)`, `auto_populate_from_map(id)`, `auto_populate(id, evidence, source)`, `submit(id)`, `approve(id, by)`, `reject(id, by, reason)`
- `discovery` — `ingest_map(map)`, `get_map`, `ropa_drafts`, `evidence`, `drift`, `plan_enforcement(dialect, rules, permits_table:, policy_prefix:)`
- `ai` — `get_policy`, `set_policy(policy)`, `inspect_prompt(input)`, `inventory`, `lineage`, `register_system(id:, name:, provider:, purpose:)`, `systems`, `audit(limit:)`. (`inspect_prompt`, not `inspect`, so as not to shadow `Object#inspect`.)
- `fulfillment` — `sla`, `plan(request_id, systems, include_historical:)`, `status(request_id)`, and for the in-environment agent `pending_tasks(limit:)`, `report_task(task_id, ok, error:)`
- `regulatory` — `feed(jurisdictions:)`, `upcoming(days:)`

### `reseller`

Needs a key with the `reseller:*` scopes. `list`, `create(name:, owner_email:, controller:,
white_label:, delegated_access:, mint_key:, key_scopes:)`, `get(id)`,
`update(id, status:, delegated_access:, dsar_routing:, controller:)` — pass
`dsar_routing: nil` to clear an override — `deprovision(id, purge: false)`,
`list_keys(id)`, `mint_key(id, name:, scopes:, cbids:)`, `revoke_key(id, prefix)`.

`deprovision` suspends, which is reversible. `purge: true` deletes the org and its data,
which is not.

Every operation of the `/v1` API is reachable, and `test/parity_test.rb` keeps it that way
against `sdks/operations.json`, generated from the server's OpenAPI document.

## Examples

```ruby
# Create a site and fetch its install snippet
site = cm.sites.create(domain: "example.com")
snippet = cm.sites.snippet(site["cbid"], blocking_mode: "auto")
puts snippet["snippet"]

# Per-day consent stats for a window
cm.consent.stats(site["cbid"], from: 1_700_000_000_000, to: 1_701_000_000_000)

# Fetch a signed consent receipt
cm.consent.receipt(site["cbid"], "the-consent-stamp")

# Open a DSAR and advance it
req = cm.dsar.create(type: "access", subject_email: "user@example.com", regulation: "gdpr")
cm.dsar.advance(req["request"]["id"], "in_progress")

# Subscribe to webhooks
cm.webhooks.create(url: "https://hooks.example.com/cm", events: ["consent.recorded", "dsar.created"])
```

## Response shapes (authoritative reference)

Because responses are plain `Hash`es, the wire shapes come straight from the API.
A few notable ones (per the server's OpenAPI schema):

- `usage` → `{ "domains", "seats", "monthlyEvents" }`
- `sites.scan` / `sites.scan_status` → `{ "status" => "idle"|"scanning", "lastScannedAt" => Integer|nil }`
- `sites.cookies` → `{ "updatedAt" => Integer, "cookies" => [ { "name", "category", … } ] }` (a `CookieDeclaration`, not a bare array)
- `sites.ab` → `[ { "variant", "impressions", "optIns", "optInRate" } ]`
- `keys.list` → `[ { "prefix", "createdAt" } ]`; `keys.issue` → `{ "key", "prefix" }`
- `members.list` → `[ { "userId", "email", "role" } ]`
- `sites.get_flow` / `set_flow` / `edit_flow` → a flow write result — **check the `"ok"` key**; on lint/validation failure the HTTP status is still 200 with `{ "ok" => false, "issues" => [...] }`.

## Custom transport (testing)

Any object responding to `call(method, url, headers, body)` and returning
`[status_integer, headers_hash, body_string]` can be injected:

```ruby
fake = ->(method, url, headers, body) { [200, { "content-type" => "application/json" }, "{}"] }
cm = CookieMunch::Client.new(api_key: "test", transport: fake)
```

## Development

```bash
ruby -Ilib -Itest test/*_test.rb   # run the test suite (no network)
# or
rake test
```

## License

MIT — see [LICENSE](LICENSE).
