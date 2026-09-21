# frozen_string_literal: true

require "uri"

module CookieMunch
  # @api private — shared base for the resource groups.
  class Resource
    def initialize(client)
      @client = client
    end

    private

    # URL-encode a single path segment (space -> %20, not +).
    def enc(value)
      URI.encode_www_form_component(value.to_s).gsub("+", "%20")
    end

    # Build a "?a=1&b=2" query string, skipping nil values. Empty => "".
    def qs(params)
      pairs = params.reject { |_, v| v.nil? }
      return "" if pairs.empty?

      "?" + URI.encode_www_form(pairs)
    end
  end

  # /v1/sites/* — site CRUD, config, cookies, scans, A/B, snippet, verify,
  # brand extraction, and the v2 banner flow authoring surface.
  class Sites < Resource
    def list
      @client.get("/sites")
    end

    def create(domain:, cbid: nil)
      body = { "domain" => domain }
      body["cbid"] = cbid unless cbid.nil?
      @client.request("POST", "/sites", body: body)
    end

    def get(cbid)
      @client.get("/sites/#{enc(cbid)}")
    end

    def delete(cbid)
      @client.request("DELETE", "/sites/#{enc(cbid)}")
    end

    def get_config(cbid)
      @client.get("/sites/#{enc(cbid)}/config")
    end

    def put_config(cbid, config)
      @client.request("PUT", "/sites/#{enc(cbid)}/config", body: config)
    end

    # Latest categorized cookie declaration (most recent scan snapshot).
    # @return [Hash] { "updatedAt", "cookies" => [...] } (CookieDeclaration).
    def cookies(cbid)
      @client.get("/sites/#{enc(cbid)}/cookies")
    end

    # Kick off an async cookie crawl. @return [Hash] ScanStatus.
    def scan(cbid)
      @client.request("POST", "/sites/#{enc(cbid)}/scan")
    end

    # Current cookie-scan status. @return [Hash] { "status", "lastScannedAt" }.
    def scan_status(cbid)
      @client.get("/sites/#{enc(cbid)}/scan")
    end

    # A/B experiment results. @return [Array<Hash>] each AbResult.
    def ab(cbid)
      @client.get("/sites/#{enc(cbid)}/ab")
    end

    # Which banner design the site uses: { "bannerId" => String | nil }.
    def banner(cbid)
      @client.get("/sites/#{enc(cbid)}/banner")
    end

    # The site's privacy and cookie policy, as Markdown.
    def policy(cbid, contact_email: nil, effective_date: nil, jurisdictions: nil)
      query = qs("contactEmail" => contact_email, "effectiveDate" => effective_date,
                 "jurisdictions" => jurisdictions&.join(","))
      @client.request("GET", "/sites/#{enc(cbid)}/policy#{query}", raw: true)
    end

    # Add or remove the separate personalised-ads choice on the site's banner.
    def set_ad_personalization(cbid, enabled:, default: nil, label: nil)
      body = { "enabled" => enabled }
      body["default"] = default unless default.nil?
      body["label"] = label unless label.nil?
      @client.request("POST", "/sites/#{enc(cbid)}/elements/ad-personalization", body: body)
    end

    # Which trackers fired after opt-out in a captured session, and what personal data left the page.
    def analyze_session(cbid, har: nil, requests: nil, consent: nil, gpc: nil)
      body = { "har" => har, "requests" => requests, "consent" => consent, "gpc" => gpc }.reject { |_, v| v.nil? }
      @client.request("POST", "/sites/#{enc(cbid)}/sentry", body: body)
    end

    # GET /v1/sites/:cbid/snippet — the install snippet.
    # @param blocking_mode [String, nil] "auto" | "manual" | "checklist".
    # @param culture [String, nil] language culture override, e.g. "en".
    def snippet(cbid, blocking_mode: nil, culture: nil)
      query = qs("blockingmode" => blocking_mode, "culture" => culture)
      @client.get("/sites/#{enc(cbid)}/snippet#{query}")
    end

    # Verify the site's domain. @param method [String] "dns" | "meta" | "file".
    def verify(cbid, method)
      @client.request("POST", "/sites/#{enc(cbid)}/verify", body: { "method" => method })
    end

    # Extract brand tokens from the site homepage ("Match my site").
    # @return [Hash] { "suggestion" => { ... } }.
    # Exactly what to publish to prove control of the domain, for each method.
    def verify_challenge(cbid)
      @client.get("/sites/#{enc(cbid)}/verify/challenge")
    end

    # Create up to 100 sites. Partial success: each item reports "ok" or its own error.
    # @param sites [Array<Hash>] { "domain" => ..., "cbid" => ..., "platform" => ... }
    def create_bulk(sites)
      @client.request("POST", "/sites/bulk", body: { "sites" => sites })
    end

    def brand(cbid)
      @client.request("POST", "/sites/#{enc(cbid)}/brand", body: {})
    end

    # Read the v2 banner flow (design) with lint findings.
    def get_flow(cbid)
      @client.get("/sites/#{enc(cbid)}/flow")
    end

    # Apply an ordered batch of structured edit ops (validated + linted before
    # persist). @return [Hash] a FlowWriteResult — check the "ok" key.
    def edit_flow(cbid, operations)
      @client.request("POST", "/sites/#{enc(cbid)}/flow/ops", body: { "operations" => operations })
    end

    # Replace the v2 banner flow wholesale with a full FlowConfig.
    # @return [Hash] a FlowWriteResult — check the "ok" key.
    def set_flow(cbid, config)
      @client.request("PUT", "/sites/#{enc(cbid)}/flow", body: config)
    end
  end

  # /v1/sites/:cbid/consent/* plus receipt / subject erase & export.
  class Consent < Resource
    # Aggregated per-day consent stats. @return [Array<Hash>] ConsentDay rows.
    def stats(cbid, from: nil, to: nil)
      @client.get("/sites/#{enc(cbid)}/consent/stats#{qs("from" => from, "to" => to)}")
    end

    # Recent anonymised consent records (newest first).
    def log(cbid, from: nil, to: nil, limit: nil)
      @client.get("/sites/#{enc(cbid)}/consent/log#{qs("from" => from, "to" => to, "limit" => limit)}")
    end

    # CSV audit export. @return [String] raw CSV text.
    def export(cbid, from: nil, to: nil)
      @client.request("GET", "/sites/#{enc(cbid)}/consent/export#{qs("from" => from, "to" => to)}", raw: true)
    end

    # Signed ISO-27560 consent receipt (JSON). @return [Hash].
    def receipt(cbid, stamp)
      @client.get("/sites/#{enc(cbid)}/receipt/#{enc(stamp)}")
    end

    # Crypto-erase a subject's consent records by receipt stamp. Irreversible.
    # @return [Hash] { "erased" => n }.
    def erase_subject(cbid, stamp)
      @client.request("POST", "/sites/#{enc(cbid)}/erase-consent", body: { "stamp" => stamp })
    end

    # Export a subject's consent records by receipt stamp (GDPR access/portability).
    def export_subject(cbid, stamp)
      @client.get("/sites/#{enc(cbid)}/subject-export?stamp=#{enc(stamp)}")
    end
  end

  # /v1/dsar/* — data-subject access requests.
  class Dsar < Resource
    def list
      @client.get("/dsar")
    end

    # @param type [String] access | deletion | rectification | portability | opt-out.
    # @param regulation [String] "gdpr" | "ccpa".
    def create(type:, subject_email:, regulation:, note: nil)
      body = { "type" => type, "subjectEmail" => subject_email, "regulation" => regulation }
      body["note"] = note unless note.nil?
      @client.request("POST", "/dsar", body: body)
    end

    # @param to_status [String] received | verifying | in_progress | completed | rejected.
    def advance(id, to_status)
      @client.request("POST", "/dsar/#{enc(id)}/advance", body: { "toStatus" => to_status })
    end

    # The subject-facing response notice for a request, as plain text.
    def response(id)
      @client.request("GET", "/dsar/#{enc(id)}/response", raw: true)
    end

    # Crypto-erase a subject's consent records on a site, for a deletion request. The
    # request must be past identity verification. Requires dsar:write and consent:write.
    # @return [Hash] { "erased", "encryptionEnabled", "warning" => String|nil, "request" }.
    def erase(id, cbid, stamp)
      @client.request("POST", "/dsar/#{enc(id)}/erase", body: { "cbid" => cbid, "stamp" => stamp })
    end

    # Return a subject's consent records on a site, for an access or portability
    # request. The request must be past identity verification. Requires dsar:write and
    # consent:read.
    # @return [Hash] { "records", "count", "request" }.
    def export(id, cbid, stamp)
      @client.request("POST", "/dsar/#{enc(id)}/export", body: { "cbid" => cbid, "stamp" => stamp })
    end
  end

  # /v1/vendors/* — vendors with computed risk scores.
  class Vendors < Resource
    def list
      @client.get("/vendors")
    end

    # @param vendor [Hash] VendorInput (name, category, dataShared, dpaSigned, ...).
    def create(vendor)
      @client.request("POST", "/vendors", body: vendor)
    end
  end

  # /v1/ropa/* — Records of Processing Activities.
  class Ropa < Resource
    def list
      @client.get("/ropa")
    end

    # @param entry [Hash] RopaInput (name, purpose, legalBasis, ...).
    def create(entry)
      @client.request("POST", "/ropa", body: entry)
    end

    # The org's RoPA (GDPR Art. 30), as CSV.
    def export_csv
      @client.request("GET", "/ropa/export.csv", raw: true)
    end
  end

  # /v1/brand-kits/* — reusable, org-level banner themes.
  class BrandKits < Resource
    def list
      @client.get("/brand-kits")
    end

    # @param kit [Hash] BrandKitCreate (name, theme, content?, logoUrl?, customCss?).
    def create(kit)
      @client.request("POST", "/brand-kits", body: kit)
    end

    def delete(id)
      @client.request("DELETE", "/brand-kits/#{enc(id)}")
    end
  end

  # /v1/preferences — the org's preference-center records.
  class Preferences < Resource
    def list
      @client.get("/preferences")
    end

    # @param purposes [Hash] purpose => bool map.
    def save(subject_id, purposes)
      @client.request("POST", "/preferences", body: { "subjectId" => subject_id, "purposes" => purposes })
    end

    # One subject's preference record. A subject with none has empty "purposes".
    # Requires consent:read.
    def get(subject_id)
      @client.get("/preferences/#{enc(subject_id)}")
    end
  end

  # /v1/members/* — org membership.
  class Members < Resource
    def list
      @client.get("/members")
    end

    # @param role [String] admin | member | viewer. (An owner cannot be invited.)
    def invite(email, role)
      @client.request("POST", "/members", body: { "email" => email, "role" => role })
    end

    def set_role(user_id, role)
      @client.request("PATCH", "/members/#{enc(user_id)}", body: { "role" => role })
    end

    def remove(user_id)
      @client.request("DELETE", "/members/#{enc(user_id)}")
    end
  end

  # /v1/keys — API-key prefixes + issuing new keys.
  class Keys < Resource
    # @return [Array<Hash>] key prefixes (display metadata; never the secret).
    def list
      @client.get("/keys")
    end

    # Issue a new API key. The "key" is returned ONCE.
    #
    # Pass +scopes+ and/or +cbids+ for a least-privilege key — omit both for full access
    # to the whole org. A key locked with +cbids+ works only on those sites and on no
    # org-wide endpoint.
    # @return [Hash] { "key", "prefix" }.
    def issue(name: nil, scopes: nil, cbids: nil, expires_in_days: nil)
      body = { "name" => name, "scopes" => scopes, "cbids" => cbids, "expiresInDays" => expires_in_days }
      @client.request("POST", "/keys", body: body.reject { |_, v| v.nil? })
    end

    # Revoke a key by its prefix. Immediate.
    def revoke(prefix)
      @client.request("DELETE", "/keys/#{enc(prefix)}")
    end

    # Rotate a key: a new secret, returned once, with the same scopes, lock and expiry.
    # The old one stops working.
    # @return [Hash] { "key", "prefix" }.
    def roll(prefix)
      @client.request("POST", "/keys/#{enc(prefix)}/roll")
    end

    # Rename a key, or replace its scopes or property lock. Only the fields sent change.
    def update(prefix, name: nil, scopes: nil, cbids: nil)
      body = { "name" => name, "scopes" => scopes, "cbids" => cbids }.reject { |_, v| v.nil? }
      @client.request("PATCH", "/keys/#{enc(prefix)}", body: body)
    end
  end

  # /v1/webhooks/* — webhook subscriptions.
  class Webhooks < Resource
    def list
      @client.get("/webhooks")
    end

    # @param events [Array<String>] e.g. ["consent.recorded", "scan.completed"].
    # @param cbid [String, nil] optional property filter; nil = all properties.
    def create(url:, events:, cbid: nil)
      body = { "url" => url, "events" => events }
      body["cbid"] = cbid unless cbid.nil?
      @client.request("POST", "/webhooks", body: body)
    end

    UNSET = Object.new.freeze

    # Change or pause a subscription. +active: false+ pauses it; +cbid: nil+ widens it to the whole org.
    def update(id, url: nil, events: nil, cbid: UNSET, active: nil)
      body = { "url" => url, "events" => events, "active" => active }.reject { |_, v| v.nil? }
      body["cbid"] = cbid unless cbid.equal?(UNSET)
      @client.request("PATCH", "/webhooks/#{enc(id)}", body: body)
    end

    def delete(id)
      @client.request("DELETE", "/webhooks/#{enc(id)}")
    end

    # Rotate a subscription's signing secret. The new secret is returned once.
    # @return [Hash] { "secret" }.
    def roll_secret(id)
      @client.request("POST", "/webhooks/#{enc(id)}/roll")
    end

    # Send a signed test event to the subscription now, and report what the endpoint answered.
    # @return [Hash] { "ok", "status" => Integer|nil, "error" => String|nil }.
    def test(id)
      @client.request("POST", "/webhooks/#{enc(id)}/test")
    end

    # Deliveries that failed every retry, newest first.
    # @return [Hash] { "deadLetters" => [...] }.
    def dead_letters
      @client.get("/webhooks/dead-letters")
    end

    # Deliver a dead-lettered event again, to the subscription as it is now.
    def replay_dead_letter(id)
      @client.request("POST", "/webhooks/dead-letters/#{enc(id)}/replay")
    end
  end

  # /v1/banners/* — reusable, account-level banner designs.
  class Banners < Resource
    def list
      @client.get("/banners")
    end

    # @param json [Hash] the design payload (a v2 banner config).
    def create(name:, json:)
      @client.request("POST", "/banners", body: { "name" => name, "json" => json })
    end

    def get(id)
      @client.get("/banners/#{enc(id)}")
    end

    def update(id, name: nil, json: nil)
      patch = {}
      patch["name"] = name unless name.nil?
      patch["json"] = json unless json.nil?
      @client.request("PUT", "/banners/#{enc(id)}", body: patch)
    end

    def delete(id)
      @client.request("DELETE", "/banners/#{enc(id)}")
    end

    # @return [Hash] { "cbids" => [...] }.
    def assignments(id)
      @client.get("/banners/#{enc(id)}/assignments")
    end

    def set_assignments(id, cbids)
      @client.request("PUT", "/banners/#{enc(id)}/assignments", body: { "cbids" => cbids })
    end

    # Compile the design into every assigned site's SiteConfig.
    # @return [Hash] { "publishedCbids" => [...] }.
    def publish(id)
      @client.request("POST", "/banners/#{enc(id)}/publish")
    end
  end

  # ---- the privacy platform -------------------------------------------------------
  #
  # Identity, vault and profile reads are POSTs on purpose: a person's identifiers travel
  # in the request body, never in a URL where logs and proxies would keep them.
  # +identifiers+ is an Array of { "space" => ..., "value" => ... }.

  # /v1/identity/* — a person as a cluster of identifiers.
  class Identity < Resource
    def resolve(identifiers)
      @client.request("POST", "/identity/resolve", body: { "identifiers" => identifiers })
    end

    # Stitch identifiers into one subject. A durable merge.
    def link(identifiers)
      @client.request("POST", "/identity/link", body: { "identifiers" => identifiers })
    end

    def cluster(subject_id)
      @client.get("/identity/#{enc(subject_id)}")
    end
  end

  # /v1/vault/* — a resolved person's consent.
  class Vault < Resource
    def record(identifiers, decisions)
      @client.request("POST", "/vault/record", body: { "identifiers" => identifiers, "decisions" => decisions })
    end

    # Allow/deny per purpose, across all of the person's identifiers.
    def current(identifiers)
      @client.request("POST", "/vault/current", body: { "identifiers" => identifiers })
    end

    # The same decisions in full: legal basis, jurisdiction, provenance, time.
    def permits(identifiers)
      @client.request("POST", "/vault/permits", body: { "identifiers" => identifiers })
    end
  end

  # /v1/profile/* — attributes, with consent enforced when they are used.
  class Profile < Resource
    def get(identifiers)
      @client.request("POST", "/profile/get", body: { "identifiers" => identifiers })
    end

    def set_attributes(identifiers, attributes)
      @client.request("POST", "/profile/attributes", body: { "identifiers" => identifiers, "attributes" => attributes })
    end

    # Attribute values usable for +purpose+ — empty when the person has not consented to it.
    def activate(identifiers, purpose)
      @client.request("POST", "/profile/activate", body: { "identifiers" => identifiers, "purpose" => purpose })
    end
  end

  # /v1/subscriptions/* — marketing preferences as topics x channels.
  class Subscriptions < Resource
    def topics
      @client.get("/subscriptions/topics")
    end

    # Replace the topic catalog. It is authored whole; anything omitted is removed.
    def set_topics(topics)
      @client.request("PUT", "/subscriptions/topics", body: { "topics" => topics })
    end

    def get(subject_id)
      @client.get("/subscriptions/#{enc(subject_id)}")
    end

    def set(subject_id, topic, channel, opted_in)
      @client.request("PUT", "/subscriptions/#{enc(subject_id)}",
                      body: { "topic" => topic, "channel" => channel, "optedIn" => opted_in })
    end

    def unsubscribe_all(subject_id)
      @client.request("POST", "/subscriptions/#{enc(subject_id)}/unsubscribe-all")
    end

    # Lift a global unsubscribe, restoring the per-topic choices from before it.
    def resubscribe(subject_id)
      @client.request("POST", "/subscriptions/#{enc(subject_id)}/resubscribe")
    end

    def activation(subject_id, topics)
      @client.request("POST", "/subscriptions/#{enc(subject_id)}/activation", body: { "topics" => topics })
    end
  end

  # /v1/assessments/* — DPIA, PIA, LIA, TIA, AI-impact and vendor assessments.
  class Assessments < Resource
    def templates
      @client.get("/assessments/templates")
    end

    def list
      @client.get("/assessments")
    end

    def start(template, subject)
      @client.request("POST", "/assessments", body: { "template" => template, "subject" => subject })
    end

    def get(id)
      @client.get("/assessments/#{enc(id)}")
    end

    def answer(id, question_id, value)
      @client.request("POST", "/assessments/#{enc(id)}/answer", body: { "questionId" => question_id, "value" => value })
    end

    # Fill factual answers from the latest data map. Never overwrites a human answer.
    def auto_populate_from_map(id)
      @client.request("POST", "/assessments/#{enc(id)}/autopopulate-from-map")
    end

    # Fill from evidence you supply, stamped with +source+. Never overwrites a human answer.
    def auto_populate(id, evidence, source = nil)
      body = { "evidence" => evidence }
      body["source"] = source unless source.nil?
      @client.request("POST", "/assessments/#{enc(id)}/autopopulate", body: body)
    end

    def submit(id)
      @client.request("POST", "/assessments/#{enc(id)}/submit")
    end

    # Record approval. +by+ becomes the approval record — pass the person who approved.
    def approve(id, by)
      @client.request("POST", "/assessments/#{enc(id)}/approve", body: { "by" => by })
    end

    def reject(id, by, reason)
      @client.request("POST", "/assessments/#{enc(id)}/reject", body: { "by" => by, "reason" => reason })
    end
  end

  # /v1/discovery/* — the data map from an in-environment scan (metadata only).
  class Discovery < Resource
    def ingest_map(map)
      @client.request("POST", "/discovery/map", body: { "map" => map })
    end

    def get_map
      @client.get("/discovery/map")
    end

    def ropa_drafts
      @client.get("/discovery/ropa-drafts")
    end

    def evidence
      @client.get("/discovery/evidence")
    end

    # What changed since the last scan, and where the RoPA disagrees with reality.
    def drift
      @client.get("/discovery/drift")
    end

    # Plan masking / row-access policy for a warehouse. Applies nothing.
    def plan_enforcement(dialect, rules, permits_table: nil, policy_prefix: nil)
      body = { "dialect" => dialect, "rules" => rules, "permitsTable" => permits_table,
               "policyPrefix" => policy_prefix }.reject { |_, v| v.nil? }
      @client.request("POST", "/discovery/enforcement", body: body)
    end
  end

  # /v1/ai/* — AI governance: policy, the inline gateway, inventory and lineage.
  class Ai < Resource
    def get_policy
      @client.get("/ai/policy")
    end

    # Replace the AI gateway policy.
    def set_policy(policy)
      @client.request("PUT", "/ai/policy", body: { "policy" => policy })
    end

    # Enforce consent and policy on a prompt or response. Needs the ai:inspect scope.
    def inspect_prompt(input)
      @client.request("POST", "/ai/inspect", body: input)
    end

    def inventory
      @client.get("/ai/inventory")
    end

    def lineage
      @client.get("/ai/lineage")
    end

    def register_system(id:, name:, provider: nil, purpose: nil)
      body = { "id" => id, "name" => name, "provider" => provider, "purpose" => purpose }.reject { |_, v| v.nil? }
      @client.request("POST", "/ai/systems", body: body)
    end

    def systems
      @client.get("/ai/systems")
    end

    def audit(limit: nil)
      @client.get("/ai/audit#{qs("limit" => limit)}")
    end
  end

  # /v1/dsar/* fulfilment — plan work per system, and the in-environment agent's protocol.
  class Fulfillment < Resource
    def sla
      @client.get("/dsar/sla")
    end

    def plan(request_id, systems, include_historical: false)
      body = { "systems" => systems }
      body["includeHistorical"] = true if include_historical
      @client.request("POST", "/dsar/#{enc(request_id)}/plan", body: body)
    end

    def status(request_id)
      @client.get("/dsar/#{enc(request_id)}/fulfillment")
    end

    # For the in-environment agent: tasks to execute inside your network.
    def pending_tasks(limit: nil)
      @client.get("/dsar/agent/tasks#{qs("limit" => limit)}")
    end

    # For the in-environment agent: report an outcome. Only the outcome crosses the boundary.
    def report_task(task_id, ok, error: nil)
      body = { "ok" => ok }
      body["error"] = error unless error.nil?
      @client.request("POST", "/dsar/agent/tasks/#{enc(task_id)}/result", body: body)
    end
  end

  # /v1/regulatory/* — the curated privacy-law dataset.
  class Regulatory < Resource
    def feed(jurisdictions: nil)
      @client.get("/regulatory/feed#{qs("jurisdictions" => jurisdictions&.join(","))}")
    end

    def upcoming(days: nil)
      @client.get("/regulatory/upcoming#{qs("days" => days)}")
    end
  end

  # /v1/subjects/* — one person's consent across every site, by the subject id your apps attach.
  class Subjects < Resource
    # Needs consent:read; not available to property-locked keys.
    def consent(subject_id)
      @client.get("/subjects/#{enc(subject_id)}/consent")
    end
  end

  # /v1/org — the key's organisation. Requires an unscoped key that is not property-locked.
  class Org < Resource
    def get
      @client.get("/org")
    end

    # Sentinel so update can tell "remove the logo" (nil) from "leave it".
    UNSET = Object.new.freeze

    # Rename the org or set its logo. +logo_url: nil+ removes the logo; omitting it
    # leaves the logo unchanged. Deleting the org is not available through the API.
    def update(name: nil, logo_url: UNSET)
      body = { "name" => name }.reject { |_, v| v.nil? }
      body["logoUrl"] = logo_url unless logo_url.equal?(UNSET)
      @client.request("PATCH", "/org", body: body)
    end
  end

  # /v1/assets — upload a banner image / org logo.
  class Assets < Resource
    # @param content_type [String] image/png | image/jpeg | image/webp | image/gif | image/svg+xml.
    # @return [Hash] { "url" }.
    def upload(data:, content_type:)
      @client.request("POST", "/assets", body: { "data" => data, "contentType" => content_type })
    end

    # Delete a stored image. Takes the URL +upload+ returned, or just its file name. Only
    # your own org's images are reachable: the folder comes from your API key.
    # @return [nil]
    def delete(url_or_file_name)
      name = url_or_file_name.to_s.split("/").last.to_s
      @client.request("DELETE", "/assets/#{enc(name)}")
      nil
    end
  end

  # /v1/reseller/* — provision and manage child orgs. Needs the reseller:* scopes.
  class Reseller < Resource
    # Sentinel so update can tell "clear the DSAR routing override" (nil) from "leave it".
    UNSET = Object.new.freeze

    def list
      @client.get("/reseller/customers")
    end

    # Provision a child org. With +mint_key+, its first API key is returned once as "apiKey".
    def create(name:, owner_email: nil, controller: nil, white_label: nil, delegated_access: nil,
               mint_key: nil, key_scopes: nil)
      body = { "name" => name, "ownerEmail" => owner_email, "controller" => controller,
               "whiteLabel" => white_label, "delegatedAccess" => delegated_access,
               "mintKey" => mint_key, "keyScopes" => key_scopes }.reject { |_, v| v.nil? }
      @client.request("POST", "/reseller/customers", body: body)
    end

    def get(id)
      @client.get("/reseller/customers/#{enc(id)}")
    end

    # Update a child. Pass +dsar_routing: nil+ to clear its override.
    def update(id, status: nil, delegated_access: nil, dsar_routing: UNSET, controller: nil)
      body = { "status" => status, "delegatedAccess" => delegated_access, "controller" => controller }
             .reject { |_, v| v.nil? }
      body["dsarRouting"] = dsar_routing unless dsar_routing.equal?(UNSET)
      @client.request("PATCH", "/reseller/customers/#{enc(id)}", body: body)
    end

    # Suspend a child (reversible). +purge: true+ deletes it and its data — irreversibly.
    def deprovision(id, purge: false)
      @client.request("DELETE", "/reseller/customers/#{enc(id)}#{qs("purge" => (purge ? "true" : nil))}")
    end

    def list_keys(id)
      @client.get("/reseller/customers/#{enc(id)}/keys")
    end

    # Mint an API key for a child org; the secret is returned once.
    def mint_key(id, name: nil, scopes: nil, cbids: nil)
      body = { "name" => name, "scopes" => scopes, "cbids" => cbids }.reject { |_, v| v.nil? }
      @client.request("POST", "/reseller/customers/#{enc(id)}/keys", body: body)
    end

    def revoke_key(id, prefix)
      @client.request("DELETE", "/reseller/customers/#{enc(id)}/keys/#{enc(prefix)}")
    end
  end
end
