# frozen_string_literal: true

require_relative "test_helper"

class ClientTest < Minitest::Test
  def test_requires_api_key
    assert_raises(ArgumentError) { CookieMunch::Client.new(api_key: nil) }
    assert_raises(ArgumentError) { CookieMunch::Client.new(api_key: "") }
  end

  def test_default_base_url_and_trailing_slash_trim
    cm = CookieMunch::Client.new(api_key: "fck_x")
    assert_equal "https://api.cookiemunch.net", cm.base_url

    cm2 = CookieMunch::Client.new(api_key: "fck_x", base_url: "https://cmp.example.com/")
    assert_equal "https://cmp.example.com", cm2.base_url
  end

  # --- a GET returning parsed JSON, with the /v1 prefix ---------------------

  def test_get_parses_json_and_uses_v1_prefix
    t = FakeTransport.new(body: JSON.generate("orgId" => "org_1", "plan" => "pro", "keyPrefix" => "fck_ab"))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    identity = cm.me

    assert_equal "GET", t.last.method
    assert_equal "https://api.cookiemunch.net/v1/me", t.last.url
    assert_equal "org_1", identity["orgId"]
    assert_equal "pro", identity["plan"]
  end

  def test_get_list_endpoint
    t = FakeTransport.new(body: JSON.generate([{ "cbid" => "c1", "domain" => "a.com" }]))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    sites = cm.sites.list

    assert_equal "https://api.cookiemunch.net/v1/sites", t.last.url
    assert_kind_of Array, sites
    assert_equal "c1", sites.first["cbid"]
  end

  def test_query_string_and_segment_encoding
    t = FakeTransport.new(body: JSON.generate([]))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    cm.consent.log("cb id/1", from: 100, to: 200, limit: 50)

    url = t.last.url
    assert_includes url, "/v1/sites/cb%20id%2F1/consent/log"
    assert_includes url, "from=100"
    assert_includes url, "to=200"
    assert_includes url, "limit=50"
  end

  def test_receipt_signature_takes_cbid_and_stamp
    t = FakeTransport.new(body: JSON.generate("stamp" => "s1"))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    cm.consent.receipt("cbid_1", "stamp_1")

    assert_equal "https://api.cookiemunch.net/v1/sites/cbid_1/receipt/stamp_1", t.last.url
  end

  # --- auth headers on every request ---------------------------------------

  def test_sends_bearer_and_api_key_headers
    t = FakeTransport.new(body: JSON.generate({}))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    cm.me

    assert_equal "Bearer fck_secret", t.last.headers["Authorization"]
    assert_equal "fck_secret", t.last.headers["X-API-Key"]
    assert_includes t.last.headers["User-Agent"], "cookiemunch-ruby/"
  end

  # --- POST body encoding + JSON content type ------------------------------

  def test_post_sends_json_body_and_content_type
    t = FakeTransport.new(status: 201, body: JSON.generate("cbid" => "new1", "domain" => "x.com"))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    site = cm.sites.create(domain: "x.com")

    assert_equal "POST", t.last.method
    assert_equal "application/json", t.last.headers["Content-Type"]
    assert_equal({ "domain" => "x.com" }, JSON.parse(t.last.body))
    assert_equal "new1", site["cbid"]
  end

  # --- the public consent-log helper (POST /api/v1/consent) -----------------

  def test_log_consent_posts_to_public_ingest_endpoint
    t = FakeTransport.new
    t.respond(status: 204, headers: {}, body: "")
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    result = cm.log_consent(
      cbid: "cbid_1",
      choices: { statistics: true, marketing: false },
      method: "explicit",
      url: "https://x.com/page",
      region: "eu"
    )

    assert_nil result, "204 responses decode to nil"
    call = t.last
    assert_equal "POST", call.method
    assert_equal "https://api.cookiemunch.net/api/v1/consent", call.url
    assert_equal "eu", call.headers["X-CookieMunch-Region"]

    body = JSON.parse(call.body)
    assert_equal "cbid_1", body["cbid"]
    assert_equal "explicit", body["method"]
    assert_equal "https://x.com/page", body["url"]
    assert_equal 1, body["ver"]
    assert_equal({ "preferences" => false, "statistics" => true, "marketing" => false }, body["choices"])
    refute_nil body["stamp"], "stamp is auto-generated when omitted"
    assert_kind_of Integer, body["utc"]
  end

  def test_log_consent_accepts_string_keys_and_optional_fields
    t = FakeTransport.new
    t.respond(status: 204, headers: {}, body: "")
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    cm.log_consent(
      cbid: "cbid_1",
      choices: { "preferences" => true },
      stamp: "fixed-stamp",
      utc: 1_700_000_000_000,
      ver: 2,
      tc_string: "CTC",
      gpp_string: "GPP",
      purposes: { analytics: true },
      subject_policy_hash: "sha256:abc",
      variant: "B"
    )

    body = JSON.parse(t.last.body)
    assert_equal "fixed-stamp", body["stamp"]
    assert_equal 1_700_000_000_000, body["utc"]
    assert_equal 2, body["ver"]
    assert_equal true, body["choices"]["preferences"]
    assert_equal "CTC", body["tcString"]
    assert_equal "GPP", body["gppString"]
    assert_equal({ "analytics" => true }, body["purposes"])
    assert_equal "sha256:abc", body["subjectPolicyHash"]
    assert_equal "B", body["variant"]
  end

  def test_log_consent_omits_subject_id_when_absent
    t = FakeTransport.new
    t.respond(status: 204, headers: {}, body: "")
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    cm.log_consent(cbid: "cbid_1", choices: { statistics: true })

    body = JSON.parse(t.last.body)
    refute body.key?("subjectId"), "subjectId must be omitted when not supplied"
  end

  def test_log_consent_includes_subject_id_when_set
    t = FakeTransport.new
    t.respond(status: 204, headers: {}, body: "")
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    cm.log_consent(cbid: "cbid_1", choices: { statistics: true }, subject_id: "user-42")

    body = JSON.parse(t.last.body)
    assert_equal "user-42", body["subjectId"]
  end

  # --- error mapping --------------------------------------------------------

  def test_non_2xx_raises_api_error_with_status_and_body
    t = FakeTransport.new
    t.respond(status: 403, body: JSON.generate("error" => "domain not verified", "code" => "not_verified"))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    err = assert_raises(CookieMunch::ApiError) { cm.sites.get("c1") }
    assert_equal 403, err.status
    assert_equal "domain not verified", err.message
    assert_equal "not_verified", err.code
    assert_includes err.body, "domain not verified"
  end

  def test_non_json_error_body_keeps_default_message
    t = FakeTransport.new
    t.respond(status: 500, headers: { "content-type" => "text/plain" }, body: "boom")
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    err = assert_raises(CookieMunch::ApiError) { cm.me }
    assert_equal 500, err.status
    assert_equal "request failed with status 500", err.message
    assert_equal "boom", err.body
    assert_nil err.code
  end

  def test_api_error_is_a_cookiemunch_error
    assert_operator CookieMunch::ApiError, :<, CookieMunch::Error
  end

  # --- DELETE returns nil (204) --------------------------------------------

  def test_delete_returns_nil_on_204
    t = FakeTransport.new
    t.respond(status: 204, headers: {}, body: "")
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    assert_nil cm.sites.delete("c1")
    assert_equal "DELETE", t.last.method
  end

  # --- CSV export returns raw text -----------------------------------------

  def test_consent_export_returns_raw_csv
    t = FakeTransport.new
    t.respond(status: 200, headers: { "content-type" => "text/csv" }, body: "stamp,region\nabc,eu\n")
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    csv = cm.consent.export("c1")
    assert_equal "stamp,region\nabc,eu\n", csv
  end
end

# Pins method+path+body for the 13 operations added in commit 1c08ee6.
class NewOperationsTest < Minitest::Test
  def test_org_get
    t = FakeTransport.new(body: JSON.generate("id" => "org_1", "name" => "Acme", "plan" => "pro", "logoUrl" => nil))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    org = cm.org.get

    assert_equal "GET", t.last.method
    assert_equal "https://api.cookiemunch.net/v1/org", t.last.url
    assert_equal "org_1", org["id"]
  end

  def test_org_update_logo_url_nil_sends_json_null
    t = FakeTransport.new(body: JSON.generate({}))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    cm.org.update(logo_url: nil)

    assert_equal "PATCH", t.last.method
    body = JSON.parse(t.last.body)
    assert body.key?("logoUrl")
    assert_nil body["logoUrl"]
  end

  def test_org_update_omitted_logo_url_sends_no_key
    t = FakeTransport.new(body: JSON.generate({}))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    cm.org.update(name: "New Name")

    body = JSON.parse(t.last.body)
    assert_equal({ "name" => "New Name" }, body)
    refute body.key?("logoUrl")
  end

  def test_audit_query_param
    t = FakeTransport.new(body: JSON.generate("entries" => []))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    cm.audit(limit: 50)

    assert_equal "GET", t.last.method
    assert_equal "https://api.cookiemunch.net/v1/audit?limit=50", t.last.url
  end

  def test_audit_omits_limit_when_absent
    t = FakeTransport.new(body: JSON.generate("entries" => []))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    cm.audit

    assert_equal "https://api.cookiemunch.net/v1/audit", t.last.url
  end

  def test_assets_upload
    t = FakeTransport.new(body: JSON.generate("url" => "https://cdn.example.com/x.png"))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    result = cm.assets.upload(data: "Zm9v", content_type: "image/png")

    assert_equal "POST", t.last.method
    assert_equal "https://api.cookiemunch.net/v1/assets", t.last.url
    assert_equal({ "data" => "Zm9v", "contentType" => "image/png" }, JSON.parse(t.last.body))
    assert_equal "https://cdn.example.com/x.png", result["url"]
  end

  def test_keys_roll
    t = FakeTransport.new(body: JSON.generate("key" => "fck_new", "prefix" => "fck_ab"))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    cm.keys.roll("fck_ab")

    assert_equal "POST", t.last.method
    assert_equal "https://api.cookiemunch.net/v1/keys/fck_ab/roll", t.last.url
  end

  def test_keys_update_sends_only_provided_fields
    t = FakeTransport.new(body: JSON.generate("ok" => true))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    cm.keys.update("fck_ab", name: "renamed")

    assert_equal "PATCH", t.last.method
    assert_equal "https://api.cookiemunch.net/v1/keys/fck_ab", t.last.url
    assert_equal({ "name" => "renamed" }, JSON.parse(t.last.body))
  end

  def test_keys_update_scopes_and_cbids
    t = FakeTransport.new(body: JSON.generate("ok" => true))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    cm.keys.update("fck_ab", scopes: ["sites:read"], cbids: ["c1"])

    assert_equal({ "scopes" => ["sites:read"], "cbids" => ["c1"] }, JSON.parse(t.last.body))
  end

  def test_webhooks_roll_secret
    t = FakeTransport.new(body: JSON.generate("secret" => "whsec_new"))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    cm.webhooks.roll_secret("wh_1")

    assert_equal "POST", t.last.method
    assert_equal "https://api.cookiemunch.net/v1/webhooks/wh_1/roll", t.last.url
  end

  def test_webhooks_test
    t = FakeTransport.new(body: JSON.generate("ok" => true, "status" => 200))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    result = cm.webhooks.test("wh_1")

    assert_equal "POST", t.last.method
    assert_equal "https://api.cookiemunch.net/v1/webhooks/wh_1/test", t.last.url
    assert result["ok"]
  end

  def test_webhooks_dead_letters
    t = FakeTransport.new(body: JSON.generate("deadLetters" => []))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    cm.webhooks.dead_letters

    assert_equal "GET", t.last.method
    assert_equal "https://api.cookiemunch.net/v1/webhooks/dead-letters", t.last.url
  end

  def test_webhooks_replay_dead_letter
    t = FakeTransport.new(body: JSON.generate("ok" => true))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    cm.webhooks.replay_dead_letter("dl_1")

    assert_equal "POST", t.last.method
    assert_equal "https://api.cookiemunch.net/v1/webhooks/dead-letters/dl_1/replay", t.last.url
  end

  def test_preferences_get
    t = FakeTransport.new(body: JSON.generate("subjectId" => "sub_1", "purposes" => {}))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    cm.preferences.get("sub 1")

    assert_equal "GET", t.last.method
    assert_equal "https://api.cookiemunch.net/v1/preferences/sub%201", t.last.url
  end

  def test_dsar_erase
    t = FakeTransport.new(body: JSON.generate("erased" => 1, "encryptionEnabled" => true, "request" => { "id" => "d1" }))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    cm.dsar.erase("d1", "cbid1", "stamp1")

    assert_equal "POST", t.last.method
    assert_equal "https://api.cookiemunch.net/v1/dsar/d1/erase", t.last.url
    assert_equal({ "cbid" => "cbid1", "stamp" => "stamp1" }, JSON.parse(t.last.body))
  end

  def test_dsar_export
    t = FakeTransport.new(body: JSON.generate("records" => [], "count" => 0, "request" => { "id" => "d1" }))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    cm.dsar.export("d1", "cbid1", "stamp1")

    assert_equal "POST", t.last.method
    assert_equal "https://api.cookiemunch.net/v1/dsar/d1/export", t.last.url
    assert_equal({ "cbid" => "cbid1", "stamp" => "stamp1" }, JSON.parse(t.last.body))
  end
end

# Exercises the REAL default Net::HTTP transport with zero network by stubbing
# Net::HTTP.start. Proves the request is built with the auth headers and that
# the response is decoded correctly.
class NetHttpTransportTest < Minitest::Test
  # Minimal stand-in for a Net::HTTPResponse.
  class FakeResponse
    def initialize(code, body, headers)
      @code = code
      @body = body
      @headers = headers
    end

    attr_reader :body

    def code
      @code.to_s
    end

    def each_header(&block)
      @headers.each(&block)
    end
  end

  # Records the request object the client builds, then returns a canned response.
  class FakeHttp
    attr_reader :requested

    def initialize(response)
      @response = response
    end

    def request(req)
      @requested = req
      @response
    end
  end

  def test_default_transport_sends_auth_headers_and_parses_json
    response = FakeResponse.new(200, JSON.generate("orgId" => "org_9", "plan" => "free", "keyPrefix" => "fck_zz"),
                                { "content-type" => "application/json" })
    fake_http = FakeHttp.new(response)

    captured_args = nil
    start_stub = lambda do |*args, **_kwargs, &blk|
      captured_args = args
      blk.call(fake_http)
    end

    cm = CookieMunch::Client.new(api_key: "fck_live", base_url: "https://cmp.example.com")

    identity = with_stubbed_net_http_start(start_stub) { cm.me }

    # Response decoded.
    assert_equal "org_9", identity["orgId"]

    # Connected to the right host over TLS.
    assert_equal "cmp.example.com", captured_args[0]
    assert_equal 443, captured_args[1]

    # The built request carried the auth headers and hit the /v1 path.
    req = fake_http.requested
    assert_equal "Bearer fck_live", req["Authorization"]
    assert_equal "fck_live", req["X-API-Key"]
    assert_equal "/v1/me", req.path
    assert_instance_of Net::HTTP::Get, req
  end

  def test_default_transport_maps_error_status
    response = FakeResponse.new(401, JSON.generate("error" => "authentication required"),
                                { "content-type" => "application/json" })
    fake_http = FakeHttp.new(response)
    start_stub = lambda { |*_args, **_kwargs, &blk| blk.call(fake_http) }

    cm = CookieMunch::Client.new(api_key: "bad")

    err = with_stubbed_net_http_start(start_stub) do
      assert_raises(CookieMunch::ApiError) { cm.me }
    end
    assert_equal 401, err.status
    assert_equal "authentication required", err.message
  end
end
