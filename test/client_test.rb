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
