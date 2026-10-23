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

    # A number for a query string: "30", not "30.0". nil stays nil.
    def num(value)
      return nil if value.nil?

      f = value.to_f
      f == f.to_i ? f.to_i.to_s : f.round(3).to_s
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

    UNSET_NAME = Object.new.freeze

    # PATCH /v1/sites/{cbid} — rename or move a site. The cbid and the consent ledger stay; a
    # domain move clears verification. name: nil clears the display name; aliases: [] clears them.
    # dry_run: true answers with the diff and stores nothing.
    def update(cbid, domain: nil, name: UNSET_NAME, aliases: nil, dry_run: false)
      body = {}
      body["domain"] = domain unless domain.nil?
      body["name"] = name unless name.equal?(UNSET_NAME)
      body["aliases"] = aliases unless aliases.nil?
      @client.request("PATCH", "/sites/#{enc(cbid)}#{qs("dryRun" => dry_run ? "1" : nil)}", body: body)
    end

    def delete(cbid)
      @client.request("DELETE", "/sites/#{enc(cbid)}")
    end

    # GET /v1/sites/{cbid}/partners — partner links and the partner catalogue.
    def list_partners(cbid)
      @client.get("/sites/#{enc(cbid)}/partners")
    end

    # POST /v1/sites/{cbid}/partners — grant a partner platform ("forumulate", "atlas") the
    # site's consent events. No secret is created; idempotent.
    def link_partner(cbid, partner:, external_id:, label: nil, events: nil, dry_run: false)
      body = { "partner" => partner, "externalId" => external_id }
      body["label"] = label unless label.nil?
      body["events"] = events unless events.nil?
      @client.request("POST", "/sites/#{enc(cbid)}/partners#{qs("dryRun" => dry_run ? "1" : nil)}", body: body)
    end

    # DELETE /v1/sites/{cbid}/partners/{link_id} — revoke; deliveries stop at once.
    def unlink_partner(cbid, link_id)
      @client.request("DELETE", "/sites/#{enc(cbid)}/partners/#{enc(link_id)}")
    end

    def get_config(cbid)
      @client.get("/sites/#{enc(cbid)}/config")
    end

    # Replace a site's config. A top-level field +config+ omits reverts to its default —
    # unless keep_unspecified: true (?keep=unspecified), which keeps its stored value.
    # A top-level field sent as nil reverts to its default.
    def put_config(cbid, config, keep_unspecified: false)
      query = keep_unspecified ? "?keep=unspecified" : ""
      @client.request("PUT", "/sites/#{enc(cbid)}/config#{query}", body: config)
    end

    # Change part of a site's config — a JSON Merge Patch (RFC 7386): omitted fields keep
    # their stored value, and a field set to nil is removed (it takes its default).
    # (put_config replaces the whole document.)
    def patch_config(cbid, config)
      @client.request("PATCH", "/sites/#{enc(cbid)}/config", body: config)
    end

    # Preview a config write without saving it (?dryRun=1): returns "config" as it
    # would be saved, "diff" (every leaf that would change) and any "warnings".
    # replace: true previews a PUT (the diff then lists what would revert to defaults).
    # keep_unspecified: true (with replace: true) previews put_config(keep_unspecified: true).
    def dry_run_config(cbid, config, replace: false, keep_unspecified: false)
      keep = replace && keep_unspecified ? "&keep=unspecified" : ""
      @client.request(replace ? "PUT" : "PATCH", "/sites/#{enc(cbid)}/config?dryRun=1#{keep}", body: config)
    end

    # Check a proposed config for consent-button parity without saving it
    # (POST /v1/sites/{cbid}/config/lint): is "Accept all" more prominent than "Reject all"
    # anywhere (colour, size, placement, copy, custom CSS)? Returns "designWarnings",
    # "score" (0-100) and "suggestedReject". It checks exactly what the write would store:
    # merged as patch_config would, or with replace: true replaced as put_config would.
    # Needs only sites:read.
    def lint_config(cbid, config, replace: false)
      @client.request("POST", "/sites/#{enc(cbid)}/config/lint#{replace ? '?replace=1' : ''}", body: config)
    end

    # Latest categorized cookie declaration (most recent scan snapshot).
    # @return [Hash] { "updatedAt", "cookies" => [...] } (CookieDeclaration).
    def cookies(cbid)
      @client.get("/sites/#{enc(cbid)}/cookies")
    end

    # Start a cookie crawl: answers at once with "scanId" and "state" => "queued".
    # wait: (seconds, at most 60) holds the request until it is done or failed.
    # @return [Hash] ScanStatus.
    def scan(cbid, wait: nil)
      @client.request("POST", "/sites/#{enc(cbid)}/scan#{qs("wait" => num(wait))}")
    end

    # The last scan: "state" (queued, scanning, done, failed), "scanId", timings,
    # "cookieCount", "pagesVisited", "error". wait: (seconds, at most 60) holds the
    # request until a running scan settles. @return [Hash] ScanStatus.
    def scan_status(cbid, wait: nil)
      @client.get("/sites/#{enc(cbid)}/scan#{qs("wait" => num(wait))}")
    end

    # Return once the site's scan is done or failed (read "state" and "error"),
    # long-polling the server; at timeout_ms it returns the still-running state. Each
    # request asks the server to hold no longer than this client's own timeout.
    # @return [Hash] ScanStatus.
    def wait_for_scan(cbid, timeout_ms: 120_000)
      clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      until_at = clock.call + (timeout_ms / 1000.0)
      loop do
        left = until_at - clock.call
        asked = [[60.0, left, @client.timeout - 5].min, 0.0].max
        started = clock.call
        r = scan_status(cbid, wait: asked)
        return r if r["status"] != "scanning" || until_at - clock.call <= 0

        # A server that answered sooner than asked is not hammered.
        early = [1.0, until_at - clock.call].min - (clock.call - started)
        sleep(early) if early.positive?
      end
    end

    # A/B experiment results. @return [Array<Hash>] each AbResult.
    def ab(cbid)
      @client.get("/sites/#{enc(cbid)}/ab")
    end

    # Which banner design the site uses: { "bannerId" => String | nil }.
    def banner(cbid)
      @client.get("/sites/#{enc(cbid)}/banner")
    end

    # Pages where the embed could not load its banner renderer — the host page's CSP or
    # Trusted Types policy refused it, so nobody there can be asked. Empty is healthy.
    # @return [Hash] { "reports" }.
    def blocked(cbid)
      @client.request("GET", "/sites/#{enc(cbid)}/blocked")
    end

    # Read a cookie declaration exported from another CMP and translate its categories
    # into ours. Nothing is applied — the result comes back for review.
    # @return [Hash] { "source", "cookies", "unmapped" }.
    def import_declaration(cbid, data)
      @client.request("POST", "/sites/#{enc(cbid)}/import", body: { "data" => data })
    end

    # Import a declaration exported from another CMP AND declare it: every row whose
    # category mapped to ours and that has a purpose is declared; the rest come back in
    # "skipped". Cookies already declared are kept unless overwrite: true.
    # @return [Hash] ImportedDeclaration plus { "applied", "skipped", "warnings" }.
    def apply_import(cbid, data, overwrite: false)
      query = qs("apply" => "1", "overwrite" => (overwrite ? "1" : nil))
      @client.request("POST", "/sites/#{enc(cbid)}/import#{query}", body: { "data" => data })
    end

    # Declare what one cookie is. Overrides scanned, observed and database classification
    # everywhere (API, preference modal, data-cc="declaration"). A name ending in "*"
    # (or pattern: true) declares a prefix wildcard. category is a standard category or
    # one of the site's custom category ids.
    # @return [Hash] { "cookie" => DeclaredCookie, "warnings" }.
    # purposes: the purpose in other languages ({ "es" => "…", "pt-BR" => "…" }); purpose is
    # the fallback. dry_run: true stores nothing and answers with "declared" and a "diff".
    # type: "localStorage", "sessionStorage" or "indexedDB" declares browser storage instead of a cookie.
    def declare_cookie(cbid, name, category, purpose, provider: nil, expiry: nil, domain: nil, pattern: nil,
                       purposes: nil, type: nil, dry_run: false)
      body = { "category" => category, "purpose" => purpose }
      body["provider"] = provider unless provider.nil?
      body["expiry"] = expiry unless expiry.nil?
      body["domain"] = domain unless domain.nil?
      body["pattern"] = pattern unless pattern.nil?
      body["purposes"] = purposes unless purposes.nil?
      body["type"] = type unless type.nil?
      @client.request("PUT", "/sites/#{enc(cbid)}/cookies/#{enc(name)}#{qs("dryRun" => dry_run ? "1" : nil)}", body: body)
    end

    # Declare many cookies at once (each { "name", "category", "purpose", "purposes"?, ... }).
    # All-or-nothing; replace: true also removes declarations the list does not name;
    # dry_run: true stores nothing and answers with what would be, plus a "diff".
    # @return [Hash] { "declared", "saved", "removed", "warnings" }.
    def declare_cookies(cbid, cookies, replace: false, dry_run: false)
      body = { "cookies" => cookies }
      body["replace"] = true if replace
      @client.request("PUT", "/sites/#{enc(cbid)}/cookies#{qs("dryRun" => dry_run ? "1" : nil)}", body: body)
    end

    # Retire a cookie the site renamed or stopped setting: it leaves the banner's cookie
    # list, data-cc="declaration" and the public feed, and stays listed for you with
    # "retired". A name ending in * retires every cookie with that prefix. If a crawl or a
    # visit sees it again afterwards it is listed again, flagged "retired_but_seen".
    # dry_run: true stores nothing. @return [Hash] { "cookie", "matched" }.
    def retire_cookie(cbid, name, renamed_to: nil, note: nil, dry_run: false)
      body = {}
      body["renamedTo"] = renamed_to unless renamed_to.nil?
      body["note"] = note unless note.nil?
      @client.request("POST", "/sites/#{enc(cbid)}/cookies/#{enc(name)}/retire#{qs("dryRun" => dry_run ? "1" : nil)}", body: body)
    end

    # Un-retire a cookie: it is listed again everywhere. With dry_run: true nothing is
    # removed and the answer is the would-be list ("retired").
    def unretire_cookie(cbid, name, dry_run: false)
      return @client.request("DELETE", "/sites/#{enc(cbid)}/cookies/#{enc(name)}/retire?dryRun=1") if dry_run

      @client.request("DELETE", "/sites/#{enc(cbid)}/cookies/#{enc(name)}/retire")
      nil
    end

    # Every declaration preset (atlas, forumulate, chatly, cookiemunch, referally): its parameters, what
    # it has declared on this site, and whether the vendor's manifest exists yet.
    # @return [Hash] { "presets" => [...] }.
    def cookie_presets(cbid)
      @client.request("GET", "/sites/#{enc(cbid)}/cookies/presets")
    end

    # Apply (or re-sync) a vendor preset: declares what that platform writes, marked
    # "vendor". Atlas takes { "frontendApiHost", "crossSubdomainCookies" }; Chatly
    # { "publicId", "dragging", "category" }; Referally { "cookieDomain", "cookieDays", "category" }. Names you declared are kept ("skipped").
    def apply_cookie_preset(cbid, preset, params = {}, dry_run: false)
      @client.request("PUT", "/sites/#{enc(cbid)}/cookies/presets/#{enc(preset)}#{qs("dryRun" => dry_run ? "1" : nil)}", body: params || {})
    end

    # Remove every declaration a vendor preset made.
    def remove_cookie_preset(cbid, preset, dry_run: false)
      @client.request("DELETE", "/sites/#{enc(cbid)}/cookies/presets/#{enc(preset)}#{qs("dryRun" => dry_run ? "1" : nil)}")
    end

    # Remove every stored (scanned or observed) row of this name; a declaration stays. With
    # dry_run: true nothing is removed and the answer says what would be.
    def delete_observed_cookie(cbid, name, dry_run: false)
      return @client.request("DELETE", "/sites/#{enc(cbid)}/observed-cookies/#{enc(name)}?dryRun=1") if dry_run

      @client.request("DELETE", "/sites/#{enc(cbid)}/observed-cookies/#{enc(name)}")
      nil
    end

    # Purge observed since T: remove every row a real visit first reported at or after
    # since (and before until) — ISO-8601 or epoch ms. Crawled rows and declarations stay.
    def purge_observed_cookies(cbid, since, until_time: nil, dry_run: false)
      body = { "since" => since }
      body["until"] = until_time unless until_time.nil?
      @client.request("POST", "/sites/#{enc(cbid)}/observed-cookies/purge#{qs("dryRun" => dry_run ? "1" : nil)}", body: body)
    end

    # Remove a declaration; the scanned classification applies again. With dry_run: true
    # nothing is removed and the answer is the would-be list ("declared") and a "diff".
    def undeclare_cookie(cbid, name, dry_run: false)
      return @client.request("DELETE", "/sites/#{enc(cbid)}/cookies/#{enc(name)}?dryRun=1") if dry_run

      @client.request("DELETE", "/sites/#{enc(cbid)}/cookies/#{enc(name)}")
      nil
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

    # Mint a short-lived signed token to preview the banner as a visitor in +region+
    # speaking +lang+ sees it (headless browsers included; nothing is recorded).
    # @return [Hash] { "cbid", "token", "expiresAt", "previewUrl", "region", "lang" }
    def preview_token(cbid, region: nil, lang: nil, url: nil, ttl_seconds: nil)
      body = {}
      body["region"] = region unless region.nil?
      body["lang"] = lang unless lang.nil?
      body["url"] = url unless url.nil?
      body["ttlSeconds"] = ttl_seconds unless ttl_seconds.nil?
      @client.request("POST", "/sites/#{enc(cbid)}/preview-token", body: body)
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
    # Verify the consent log's tamper-evident hash chain. Each record carries the hash of
    # the one before it, so an edited, reordered or removed record answers false.
    # @return [Hash] { "valid" => true|false }
    def verify(cbid)
      @client.get("/sites/#{enc(cbid)}/consent/verify")
    end

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
    # +test: true+ files a test request: off the SLA board, labelled, and deletable.
    # +note+ is internal; +message_to_subject+ is the line the subject reads in the notice.
    def create(type:, subject_email:, regulation:, note: nil, test: nil, message_to_subject: nil)
      body = { "type" => type, "subjectEmail" => subject_email, "regulation" => regulation }
      body["note"] = note unless note.nil?
      body["test"] = test unless test.nil?
      body["messageToSubject"] = message_to_subject unless message_to_subject.nil?
      @client.request("POST", "/dsar", body: body)
    end

    # One request, in the shape +list+ returns.
    def get(id)
      @client.get("/dsar/#{enc(id)}")
    end

    # Delete a TEST request with its tasks and log. Real requests are refused (409).
    def delete(id)
      @client.request("DELETE", "/dsar/#{enc(id)}")
      nil
    end

    # Mark a CLOSED request (completed or rejected) as a test, after the fact. An open one
    # is refused (409 request_not_closed). Audited; +delete+ then works on it.
    # Returns { "request" => ..., "changed" => bool }.
    def mark_test(id)
      @client.request("POST", "/dsar/#{enc(id)}/mark-test")
    end

    # @param to_status [String] received | verifying | in_progress | completed | rejected.
    # +message_to_subject+ replaces the line the subject reads in the notice.
    def advance(id, to_status, message_to_subject: nil)
      body = { "toStatus" => to_status }
      body["messageToSubject"] = message_to_subject unless message_to_subject.nil?
      @client.request("POST", "/dsar/#{enc(id)}/advance", body: body)
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

  # /v1/sites/:cbid/rights-page — the hosted rights page document.
  class RightsPage < Resource
    # "Not given" for base_updated_at (nil is a real value: no draft saved yet).
    UNSET_BASE = Object.new.freeze
    def get(cbid)
      @client.get("/sites/#{enc(cbid)}/rights-page")
    end

    # Replace the draft. Nothing is live until #publish.
    # Add "baseUpdatedAt" (the draft's updatedAt as last read; nil if it had none) to page to
    # refuse overwriting a newer save: a mismatch is a 409 draft_conflict.
    def put(cbid, page)
      @client.request("PUT", "/sites/#{enc(cbid)}/rights-page", body: page)
    end

    # Merge into the draft: hashes merge, arrays replace, nil removes.
    def patch(cbid, page)
      @client.request("PATCH", "/sites/#{enc(cbid)}/rights-page", body: page)
    end

    def dry_run(cbid, page, replace: false)
      @client.request(replace ? "PUT" : "PATCH", "/sites/#{enc(cbid)}/rights-page?dryRun=1", body: page)
    end

    def get_published(cbid)
      @client.get("/sites/#{enc(cbid)}/rights-page/published")
    end

    # Publish the draft; it goes live at once. Pass base_updated_at (the draft's updatedAt as
    # last read; nil if it had none) so only the draft you saw goes live: 409 draft_conflict otherwise.
    def publish(cbid, base_updated_at: UNSET_BASE)
      body = base_updated_at.equal?(UNSET_BASE) ? {} : { "baseUpdatedAt" => base_updated_at }
      @client.request("POST", "/sites/#{enc(cbid)}/rights-page/publish", body: body)
    end

    def versions(cbid)
      @client.get("/sites/#{enc(cbid)}/rights-page/versions")
    end

    # Publish an earlier version again; it goes live at once and REPLACES the current draft
    # (unpublished edits are lost). base_updated_at refuses with 409 draft_conflict if the draft moved.
    def rollback(cbid, version, base_updated_at: UNSET_BASE)
      body = { "version" => version }
      body["baseUpdatedAt"] = base_updated_at unless base_updated_at.equal?(UNSET_BASE)
      @client.request("POST", "/sites/#{enc(cbid)}/rights-page/rollback", body: body)
    end

    # Custom hostnames serving the rights page.
    # @return [Hash] { "domains", "limit" (nil = unlimited), "used", "target" }
    def list_domains(cbid)
      @client.get("/sites/#{enc(cbid)}/rights-page/domains")
    end

    # Add a custom hostname (e.g. privacy.example.com); "dns" holds the records to create.
    def add_domain(cbid, hostname)
      @client.request("POST", "/sites/#{enc(cbid)}/rights-page/domains", body: { "hostname" => hostname })
    end

    # Check it now: DNS while pending, the HTTPS answer once routed.
    def verify_domain(cbid, hostname)
      @client.request("POST", "/sites/#{enc(cbid)}/rights-page/domains/#{enc(hostname)}/verify")
    end

    # Remove it: it stops being served and its certificate is not renewed.
    # @return [nil]
    def remove_domain(cbid, hostname)
      @client.request("DELETE", "/sites/#{enc(cbid)}/rights-page/domains/#{enc(hostname)}")
      nil
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

  # /v1/preference-center/tokens — the hosted preference centre, opened for a visitor your server
  # has signed in.
  class PreferenceCenter < Resource
    # Mint a preference-centre token for the page to pass to CookieMunch.setSubjectToken. Give
    # exactly one of +email+ (resolved as the emailed preference link resolves it) or +subject_id+.
    # +ttl_seconds+ defaults to 3600, at most 86400. The token is a credential: never put it in a
    # shared URL or a log. Needs subscriptions:write and profile:write, plus identity:read by email.
    # @return [Hash] { "token", "expiresAt" }
    def mint_token(cbid, email: nil, subject_id: nil, ttl_seconds: nil)
      body = { "cbid" => cbid }
      body["email"] = email unless email.nil?
      body["subjectId"] = subject_id unless subject_id.nil?
      body["ttlSeconds"] = ttl_seconds unless ttl_seconds.nil?
      @client.request("POST", "/preference-center/tokens", body: body)
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
    # expires_at: epoch ms or an ISO date-time (not with expires_in_days); omit both for no expiry.
    def issue(name: nil, scopes: nil, cbids: nil, expires_in_days: nil, expires_at: nil)
      body = { "name" => name, "scopes" => scopes, "cbids" => cbids, "expiresInDays" => expires_in_days, "expiresAt" => expires_at }
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

    UNSET_EXPIRY = Object.new.freeze

    # Rename a key, replace its scopes or property lock, or set (epoch ms / ISO) or remove
    # (expires_at: nil) its expiry. Only the fields sent change.
    def update(prefix, name: nil, scopes: nil, cbids: nil, expires_at: UNSET_EXPIRY)
      body = { "name" => name, "scopes" => scopes, "cbids" => cbids }.reject { |_, v| v.nil? }
      body["expiresAt"] = expires_at unless expires_at.equal?(UNSET_EXPIRY)
      @client.request("PATCH", "/keys/#{enc(prefix)}", body: body)
    end

    # GET /v1/keys/report — keys unused for unused_days (default 90), keys with broad access,
    # and keys expiring within expiring_days (default 14), each with a reason.
    def report(unused_days: nil, expiring_days: nil)
      @client.get("/keys/report#{qs("unusedDays" => unused_days, "expiringDays" => expiring_days)}")
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

    # Systems connected to run part of a request themselves (an identity platform, say).
    def executors
      @client.get("/dsar/executors")
    end

    # Connect one. +profile+ describes that system's API — paths, the words it uses for
    # export and erase, its status vocabulary, how it signs webhooks — so connecting a new
    # platform needs no code. The secret is stored encrypted and never returned; the response
    # carries the webhook URL to configure in that system. +dry_run: true+ (?dryRun=1)
    # validates everything and returns the would-be connection and a diff, storing nothing.
    # A whsec_<base64> webhook secret verifies deliveries signed with its base64-decoded bytes
    # or with the literal string; any other only with its UTF-8 bytes.
    def connect_executor(system:, base_url:, secret_key:, profile:, webhook_secret: nil, auto: nil, dry_run: false)
      body = { "system" => system, "baseUrl" => base_url, "secretKey" => secret_key, "profile" => profile }
      body["webhookSecret"] = webhook_secret unless webhook_secret.nil?
      body["auto"] = auto unless auto.nil?
      @client.request("POST", "/dsar/executors#{dry_run ? '?dryRun=1' : ''}", body: body)
    end

    # Connect a system from a versioned preset: "atlas" (optional +atlas_id_app_id+),
    # "forumulate" (+org_id+), "cm-standard-v1" (+base_url+ and +system+) or "chatly". The
    # response carries presetVersion and presetDiff. A preset waiting on another platform's
    # API is refused (409 preset_waiting_on_platform); see +executor_presets+.
    def connect_executor_preset(preset:, secret_key:, system: nil, base_url: nil, org_id: nil, atlas_id_app_id: nil,
                                preset_version: nil, webhook_secret: nil, auto: nil, cbid: nil, dry_run: false)
      body = {
        "preset" => preset, "secretKey" => secret_key, "system" => system, "baseUrl" => base_url, "orgId" => org_id,
        "atlasIdAppId" => atlas_id_app_id, "presetVersion" => preset_version, "webhookSecret" => webhook_secret,
        "auto" => auto, "cbid" => cbid
      }.reject { |_, v| v.nil? }
      @client.request("POST", "/dsar/executors#{dry_run ? '?dryRun=1' : ''}", body: body)
    end

    # The versioned presets, whether each is usable now or waits on another platform, and
    # the organisation's canary address.
    def executor_presets
      @client.get("/dsar/executors/presets")
    end

    # Rebuild a connection from its preset's latest version (or +preset_version+), keeping its
    # id and credential; +preset:+ adopts one on a hand-written connection. Answers with a
    # diff; +dry_run: true+ (?dryRun=1) changes nothing.
    def upgrade_executor_preset(id, preset: nil, preset_version: nil, org_id: nil, atlas_id_app_id: nil, dry_run: false)
      body = { "preset" => preset, "presetVersion" => preset_version, "orgId" => org_id, "atlasIdAppId" => atlas_id_app_id }.reject { |_, v| v.nil? }
      @client.request("POST", "/dsar/executors/#{enc(id)}/upgrade-preset#{dry_run ? '?dryRun=1' : ''}", body: body)
    end

    UNSET = Object.new.freeze

    # Change a connection in place. Only what you pass changes; the credential is kept unless
    # +secret_key+ is given. +webhook_secret: nil+ removes the webhook secret. +dry_run: true+
    # (?dryRun=1) returns the would-be connection and a diff, and changes nothing.
    def update_executor(id, profile: nil, base_url: nil, secret_key: nil, webhook_secret: UNSET, auto: nil, dry_run: false)
      body = { "profile" => profile, "baseUrl" => base_url, "secretKey" => secret_key, "auto" => auto }.reject { |_, v| v.nil? }
      body["webhookSecret"] = webhook_secret unless webhook_secret.equal?(UNSET)
      @client.request("PATCH", "/dsar/executors/#{enc(id)}#{dry_run ? '?dryRun=1' : ''}", body: body)
    end

    # Would this webhook delivery verify? Runs the receiver's exact check on +headers+ and the
    # raw +body+ string (the bytes that were signed) and acts on nothing: {verified, stage, reason}.
    def test_executor_webhook(id, headers:, body:)
      @client.request("POST", "/dsar/executors/#{enc(id)}/webhook/test", body: { "headers" => headers, "body" => body })
    end

    # The last 50 deliveries to a connection's webhook, newest first, each with its reason.
    def executor_webhook_deliveries(id)
      @client.get("/dsar/executors/#{enc(id)}/webhook/deliveries")
    end

    def disconnect_executor(id)
      @client.request("DELETE", "/dsar/executors/#{enc(id)}")
      nil
    end

    # Try a connection against one email without filing a request: runs the lookup and
    # returns the raw (redacted) upstream answers. +open: true+ on an export opens and polls a
    # real export once; an erasure is never sent. +canary: true+ (instead of +email+) uses the
    # org canary address — no real person — and a canary locate updates the connection's health.
    def test_executor(id, email: nil, operation: nil, open: nil, canary: nil)
      body = { "email" => email, "canary" => canary, "operation" => operation, "open" => open }.reject { |_, v| v.nil? }
      @client.request("POST", "/dsar/executors/#{enc(id)}/test", body: body)
    end

    # One task: its status history, its upstream request log, and its system's versions.
    def task(request_id, task_id)
      @client.get("/dsar/#{enc(request_id)}/tasks/#{enc(task_id)}")
    end

    # The export bundle a connected system produced, fetched from it on demand.
    def task_export(request_id, task_id)
      @client.get("/dsar/#{enc(request_id)}/tasks/#{enc(task_id)}/export")
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

  # POST /v1/sites/{cbid}/rights-links — account-linked rights requests.
  class RightsLinks < Resource
    # Mint a signed, single-use link to the hosted rights page for a person your backend knows is
    # signed in. The page locks their email and skips the code step. Show the "url" only to that
    # person. Needs dsar:write.
    # @return [Hash] { "url", "expiresAt" }
    def create(cbid, email:, user_id: nil, rights: nil, ttl_seconds: nil)
      subject = { "email" => email }
      subject["userId"] = user_id unless user_id.nil?
      body = { "subject" => subject }
      body["rights"] = Array(rights) unless rights.nil?
      body["ttlSeconds"] = ttl_seconds unless ttl_seconds.nil?
      @client.request("POST", "/sites/#{enc(cbid)}/rights-links", body: body)
    end
  end

  # /v1/sites/{cbid}/consent-sync-secret — a site's consent-sync signing secret. Your server signs
  # consent-sync tokens with it so a signed-in visitor's consent decision follows them across
  # browsers (hosted consent sync). Reading needs sites:read; rotate and remove need sites:write
  # and consent:write.
  class ConsentSyncSecret < Resource
    # Whether it is set up: configured, secretLast4, createdAt. Never the secret.
    def get(cbid)
      @client.get("/sites/#{enc(cbid)}/consent-sync-secret")
    end

    # Mint the secret, or replace it (the old one stops at once). The answer's "secret" is shown
    # this once: keep it on your server, never in a page.
    def rotate(cbid)
      @client.request("POST", "/sites/#{enc(cbid)}/consent-sync-secret")
    end

    # Remove it: hosted consent sync stops for the site.
    def remove(cbid)
      @client.request("DELETE", "/sites/#{enc(cbid)}/consent-sync-secret")
    end
  end

  # /v1/sites/{cbid}/rights-captcha — a site's rights-page captcha: your own Turnstile, hCaptcha or
  # reCAPTCHA keys (recommended), or off. A site without its own setting uses the organisation
  # default (+org.rights_captcha+), else off. Cookie Munch's own captcha is never used on rights
  # pages. Needs sites:read / sites:write.
  class RightsCaptcha < Resource
    # The setting in force ("source": site, org or default). Never the secret.
    def get(cbid)
      @client.get("/sites/#{enc(cbid)}/rights-captcha")
    end

    # +mode: "own"+ with provider (turnstile, hcaptcha, recaptcha_v2, recaptcha_v3), site_key and
    # secret (write-only; omit to keep the stored one) — the provider must accept the secret before
    # it is saved. +min_score+ is for recaptcha_v3 (0.1-0.9). +mode: "off"+ removes spam
    # protection beyond the spam-trap field, the rate limits and the email code.
    def set(cbid, mode:, provider: nil, site_key: nil, secret: nil, min_score: nil)
      @client.request("PUT", "/sites/#{enc(cbid)}/rights-captcha", body: RightsCaptcha.body(mode, provider, site_key, secret, min_score))
    end

    # Remove the site's own setting: it inherits the organisation default again. Returns the
    # setting now in force.
    def remove(cbid)
      @client.request("DELETE", "/sites/#{enc(cbid)}/rights-captcha")
    end

    def self.body(mode, provider, site_key, secret, min_score)
      { "mode" => mode, "provider" => provider, "siteKey" => site_key, "secret" => secret, "minScore" => min_score }.reject { |_, v| v.nil? }
    end
  end

  # /v1/sites/{cbid}/rights-identity — a site's sign-in provider (Clerk, Atlas or any JWKS
  # issuer): a visitor signed in to your site is verified by their session, with no code mail. A
  # site without its own setting uses the organisation default (+org.rights_identity+). Needs
  # sites:read / sites:write.
  class RightsIdentity < Resource
    # The setting in force ("source": site, org or default).
    def get(cbid)
      @client.get("/sites/#{enc(cbid)}/rights-identity")
    end

    # +type+ is clerk, atlas or oidc_jwt; +issuer+ exactly the token's iss. +jwks_url+ is required
    # for oidc_jwt (clerk/atlas: <issuer>/.well-known/jwks.json); +authorized_parties+ (your own
    # origins) is required for clerk and atlas. The JWKS is fetched and checked before anything is
    # saved; oidc_jwt needs +audience+ or +authorized_parties+. The token must carry the email and a
    # verified-email claim set to true; +trust_email_claim+ (clerk/atlas only) accepts a token without it.
    def set(cbid, type:, issuer:, jwks_url: nil, audience: nil, authorized_parties: nil, email_claim: nil, email_verified_claim: nil, session_cookie_name: nil, trust_email_claim: nil)
      @client.request("PUT", "/sites/#{enc(cbid)}/rights-identity",
                      body: RightsIdentity.body(type, issuer, jwks_url, audience, authorized_parties, email_claim, email_verified_claim, session_cookie_name, trust_email_claim))
    end

    # Remove the site's own setting: it inherits the organisation default again.
    def remove(cbid)
      @client.request("DELETE", "/sites/#{enc(cbid)}/rights-identity")
    end

    def self.body(type, issuer, jwks_url, audience, authorized_parties, email_claim, email_verified_claim, session_cookie_name, trust_email_claim = nil)
      { "type" => type, "issuer" => issuer, "jwksUrl" => jwks_url, "audience" => audience,
        "authorizedParties" => authorized_parties, "emailClaim" => email_claim,
        "emailVerifiedClaim" => email_verified_claim, "sessionCookieName" => session_cookie_name,
        "trustEmailClaim" => trust_email_claim }.reject { |_, v| v.nil? }
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

    # Your organisation's own data-controller identity: who every rights notice names, before
    # any site config +controller+ block. +{ "set" => false }+ when there is none.
    def controller
      @client.get("/org/controller")
    end

    # Set the organisation's data-controller identity. Replaces it: a field left out is
    # removed. Needs an unscoped key or +rights:write+.
    def set_controller(legal_name:, contact_email: nil, address: nil, dpo_contact: nil)
      body = {
        "legalName" => legal_name, "contactEmail" => contact_email,
        "address" => address, "dpoContact" => dpo_contact
      }.reject { |_, v| v.nil? }
      @client.request("PUT", "/org/controller", body: body)
    end

    # Remove the identity; notices then name the site config +controller+ block.
    def remove_controller
      @client.request("DELETE", "/org/controller")
      nil
    end

    # Your own mail provider for rights-request mail. Never returns the credential, only
    # +secretLast4+; +sender+ says whether verification codes go through it now (+own+) or are
    # not mailed at all (+none+) — there is no shared sender.
    def mail_provider
      @client.get("/org/mail-provider")
    end

    # Connect your own mail provider (recommended): brevo, sendgrid, postmark, resend,
    # ses (+ses: { "region" =>, "accessKeyId" => }+) or smtp
    # (+smtp: { "host" =>, "port" =>, "security" =>, "username" => }+). Replaces the stored
    # one; it carries rights mail only after +test_mail_provider+ succeeds. +secret+ is
    # write-only; omit it to keep the stored one (same provider only).
    def set_mail_provider(provider:, from_email:, secret: nil, from_name: nil, reply_to: nil, ses: nil, smtp: nil)
      body = {
        "provider" => provider, "fromEmail" => from_email, "fromName" => from_name,
        "replyTo" => reply_to, "secret" => secret, "ses" => ses, "smtp" => smtp
      }.reject { |_, v| v.nil? }
      @client.request("PUT", "/org/mail-provider", body: body)
    end

    # Send a test through your provider. +to+ defaults to the reply-to, else the from address.
    # A refusal comes back as +ok: false+ with the provider's reason.
    def test_mail_provider(to = nil)
      @client.request("POST", "/org/mail-provider/test", body: to ? { "to" => to } : {})
    end

    # Remove your provider; no verification codes are mailed after this.
    def remove_mail_provider
      @client.request("DELETE", "/org/mail-provider")
      nil
    end

    # The default captcha for your rights pages (sites without their own). Never the secret.
    def rights_captcha
      @client.get("/org/rights-captcha")
    end

    # Set the default: own keys (recommended) or off. Same fields as +rights_captcha.set+.
    def set_rights_captcha(mode:, provider: nil, site_key: nil, secret: nil, min_score: nil)
      @client.request("PUT", "/org/rights-captcha", body: RightsCaptcha.body(mode, provider, site_key, secret, min_score))
    end

    # Remove the default: sites without their own setting have no captcha.
    def remove_rights_captcha
      @client.request("DELETE", "/org/rights-captcha")
    end

    # The default sign-in provider rights requests are verified with (sites without their own).
    def rights_identity
      @client.get("/org/rights-identity")
    end

    # Set the default. Same fields as +rights_identity.set+.
    def set_rights_identity(type:, issuer:, jwks_url: nil, audience: nil, authorized_parties: nil, email_claim: nil, email_verified_claim: nil, session_cookie_name: nil, trust_email_claim: nil)
      @client.request("PUT", "/org/rights-identity",
                      body: RightsIdentity.body(type, issuer, jwks_url, audience, authorized_parties, email_claim, email_verified_claim, session_cookie_name, trust_email_claim))
    end

    # Remove the default sign-in provider.
    def remove_rights_identity
      @client.request("DELETE", "/org/rights-identity")
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
