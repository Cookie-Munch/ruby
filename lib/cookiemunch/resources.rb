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
  end

  # /v1/members/* — org membership.
  class Members < Resource
    def list
      @client.get("/members")
    end

    # @param role [String] owner | admin | member | viewer.
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
    # @return [Hash] { "key", "prefix" }.
    def issue(name: nil)
      body = {}
      body["name"] = name unless name.nil?
      @client.request("POST", "/keys", body: body)
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

    def delete(id)
      @client.request("DELETE", "/webhooks/#{enc(id)}")
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
end
