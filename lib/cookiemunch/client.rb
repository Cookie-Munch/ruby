# frozen_string_literal: true

require "json"
require "net/http"
require "securerandom"
require "uri"

require_relative "version"
require_relative "errors"
require_relative "resources"

module CookieMunch
  # A small, dependency-free REST client for the Cookie Munch Developer API
  # (the `/v1` surface). Construct it with an API key; the org is derived
  # server-side from the key, so callers never pass an orgId.
  #
  #   cm = CookieMunch::Client.new(api_key: "fck_…")
  #   cm.sites.list
  #   cm.consent.receipt("cbid_123", "stamp_abc")
  #   cm.log_consent(cbid: "cbid_123", choices: { statistics: true })
  #
  # Responses are returned as parsed JSON (Hash / Array of Hash) with string
  # keys, exactly as the API sends them. CSV exports are returned as a String.
  #
  # A custom +transport+ (any object responding to
  # +call(method, url, headers, body)+ and returning
  # +[status_integer, headers_hash, body_string]+) can be injected for tests
  # or non-standard runtimes; by default a stdlib +Net::HTTP+ transport is used.
  class Client
    # The default API origin. The `/v1` prefix is appended automatically.
    DEFAULT_BASE_URL = "https://api.cookiemunch.net"

    # @return [String] the configured API origin (no trailing slash)
    attr_reader :base_url

    # @param api_key [String] the API key (e.g. "fck_…"). Sent both as
    #   +Authorization: Bearer <key>+ and, for compatibility, +X-API-Key+.
    # @param base_url [String] API origin; the `/v1` prefix is appended.
    # @param transport [#call, nil] optional injectable HTTP transport.
    # @param timeout [Numeric] per-request open/read timeout in seconds
    #   (applies to the default transport only).
    def initialize(api_key:, base_url: DEFAULT_BASE_URL, transport: nil, timeout: 30)
      raise ArgumentError, "api_key is required" if api_key.nil? || api_key.to_s.empty?

      @api_key = api_key
      @base_url = base_url.to_s.sub(%r{/+\z}, "")
      @timeout = timeout
      @transport = transport || method(:default_transport)

      @sites = Sites.new(self)
      @consent = Consent.new(self)
      @dsar = Dsar.new(self)
      @vendors = Vendors.new(self)
      @ropa = Ropa.new(self)
      @brand_kits = BrandKits.new(self)
      @preferences = Preferences.new(self)
      @members = Members.new(self)
      @keys = Keys.new(self)
      @webhooks = Webhooks.new(self)
      @banners = Banners.new(self)
      @identity = Identity.new(self)
      @vault = Vault.new(self)
      @profile = Profile.new(self)
      @subscriptions = Subscriptions.new(self)
      @assessments = Assessments.new(self)
      @discovery = Discovery.new(self)
      @ai = Ai.new(self)
      @fulfillment = Fulfillment.new(self)
      @regulatory = Regulatory.new(self)
      @reseller = Reseller.new(self)
      @subjects = Subjects.new(self)
      @org = Org.new(self)
      @assets = Assets.new(self)
    end

    # Resource groups mirroring the reference TypeScript SDK surface.
    attr_reader :sites, :consent, :dsar, :vendors, :ropa, :brand_kits,
                :preferences, :members, :keys, :webhooks, :banners,
                :identity, :vault, :profile, :subscriptions, :assessments,
                :discovery, :ai, :fulfillment, :regulatory, :reseller, :subjects,
                :org, :assets

    # GET /v1/me — identity / echo for SDK bootstrapping.
    # @return [Hash] { "orgId", "plan", "keyPrefix" }
    def me
      get("/me")
    end

    # GET /v1/usage — current resource usage for the org.
    # @return [Hash] { "domains", "seats", "monthlyEvents" }
    def usage
      get("/usage")
    end

    # GET /v1/audit — the org's audit log, newest first. API actions appear as
    # "apikey:<prefix>". Requires an unscoped key that is not property-locked.
    # @return [Hash] { "entries" => [...] }.
    def audit(limit: nil)
      query = limit.nil? ? "" : "?#{URI.encode_www_form("limit" => limit)}"
      get("/audit#{query}")
    end

    # Record a consent decision via the PUBLIC ingest endpoint
    # +POST /api/v1/consent+ (no `/v1` prefix, no auth required — though the
    # API key is still sent, harmlessly). This is what server-side / app
    # integrations use to log consent captured outside the browser embed.
    #
    # +stamp+ and +utc+ are auto-generated when omitted.
    #
    # @param cbid [String] the site identifier (required).
    # @param choices [Hash] category decisions; any of +preferences+,
    #   +statistics+, +marketing+ (symbol or string keys). Missing keys
    #   default to +false+.
    # @param method [String] "explicit" or "implied".
    # @param url [String] the page URL the consent was captured on.
    # @param stamp [String, nil] unique receipt id; auto-generated when omitted.
    # @param ver [Integer] consent schema version (default 1).
    # @param utc [Integer, nil] epoch-ms of the decision; defaults to now.
    # @param tc_string [String, nil] optional IAB TCF string.
    # @param gpp_string [String, nil] optional IAB GPP string.
    # @param purposes [Hash, nil] optional named-purpose => bool map.
    # @param subject_policy_hash [String, nil] opaque digest of the notice text shown.
    # @param variant [String, nil] optional A/B variant id.
    # @param subject_id [String, nil] optional stable cross-surface subject id (e.g. a
    #   logged-in account id); lets an org correlate one subject's consent across all its
    #   sites/surfaces. Opaque; stored and hashed server-side, never interpreted.
    # @param region [String, nil] optional region; sent via +X-CookieMunch-Region+.
    # @return [nil] the endpoint returns 204 No Content on success.
    def log_consent(cbid:, choices:, method: "explicit", url: "", stamp: nil,
                    ver: 1, utc: nil, tc_string: nil, gpp_string: nil,
                    purposes: nil, subject_policy_hash: nil, variant: nil,
                    subject_id: nil, region: nil)
      payload = {
        "cbid" => cbid,
        "stamp" => stamp || SecureRandom.uuid,
        "choices" => {
          "preferences" => truthy(choices, :preferences),
          "statistics" => truthy(choices, :statistics),
          "marketing" => truthy(choices, :marketing)
        },
        "method" => method,
        "ver" => ver,
        "utc" => utc || (Time.now.to_f * 1000).to_i,
        "url" => url
      }
      payload["tcString"] = tc_string unless tc_string.nil?
      payload["gppString"] = gpp_string unless gpp_string.nil?
      payload["purposes"] = stringify(purposes) unless purposes.nil?
      payload["subjectPolicyHash"] = subject_policy_hash unless subject_policy_hash.nil?
      payload["variant"] = variant unless variant.nil?
      payload["subjectId"] = subject_id unless subject_id.nil?

      extra = region ? { "X-CookieMunch-Region" => region } : nil
      request("POST", "/consent", body: payload, prefix: "/api/v1", headers: extra)
    end

    # Perform an HTTP request against the API and decode the response.
    #
    # Returns +nil+ for 204, the raw text when +raw: true+, parsed JSON for
    # +application/json+ responses, and the raw text otherwise. Raises
    # {CookieMunch::ApiError} on any non-2xx status.
    #
    # @api private (used by the resource groups; also usable directly).
    def request(http_method, path, body: nil, raw: false, prefix: "/v1", headers: nil)
      url = "#{@base_url}#{prefix}#{path}"
      hdrs = base_headers
      hdrs.merge!(stringify_headers(headers)) if headers

      encoded = nil
      unless body.nil?
        hdrs["Content-Type"] = "application/json"
        encoded = JSON.generate(body)
      end

      status, res_headers, res_body = @transport.call(http_method.to_s.upcase, url, hdrs, encoded)
      res_body ||= ""

      unless status.between?(200, 299)
        raise_api_error(status, res_body)
      end

      return nil if status == 204 || res_body.empty?
      return res_body if raw

      content_type = header_value(res_headers, "content-type") || ""
      if content_type.include?("application/json")
        res_body.empty? ? nil : JSON.parse(res_body)
      else
        res_body
      end
    end

    # GET helper.
    # @api private
    def get(path)
      request("GET", path)
    end

    private

    def base_headers
      {
        "Authorization" => "Bearer #{@api_key}",
        "X-API-Key" => @api_key.to_s,
        "Accept" => "application/json",
        "User-Agent" => "cookiemunch-ruby/#{CookieMunch::VERSION}"
      }
    end

    def stringify_headers(headers)
      headers.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v.to_s }
    end

    def truthy(hash, key)
      return false if hash.nil?

      !!(hash[key] || hash[key.to_s])
    end

    def stringify(hash)
      hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v }
    end

    def header_value(headers, name)
      return nil if headers.nil?

      target = name.downcase
      headers.each do |k, v|
        return v if k.to_s.downcase == target
      end
      nil
    end

    def raise_api_error(status, body_text)
      message = "request failed with status #{status}"
      code = nil
      unless body_text.nil? || body_text.empty?
        begin
          parsed = JSON.parse(body_text)
          if parsed.is_a?(Hash)
            message = parsed["error"] if parsed["error"].is_a?(String)
            code = parsed["code"] if parsed["code"].is_a?(String)
          end
        rescue JSON::ParserError
          # non-JSON error body — keep the default message
        end
      end
      raise ApiError.new(status, message, body: body_text.to_s, code: code)
    end

    # Default transport: stdlib Net::HTTP. Returns [status, headers, body].
    def default_transport(http_method, url, headers, body)
      uri = URI.parse(url)
      klass = {
        "GET" => Net::HTTP::Get,
        "POST" => Net::HTTP::Post,
        "PUT" => Net::HTTP::Put,
        "PATCH" => Net::HTTP::Patch,
        "DELETE" => Net::HTTP::Delete
      }.fetch(http_method) { raise ArgumentError, "unsupported HTTP method: #{http_method}" }

      req = klass.new(uri)
      headers.each { |k, v| req[k] = v }
      req.body = body unless body.nil?

      res = Net::HTTP.start(
        uri.hostname,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: @timeout,
        read_timeout: @timeout
      ) { |http| http.request(req) }

      [res.code.to_i, res.each_header.to_h, res.body]
    end
  end
end
