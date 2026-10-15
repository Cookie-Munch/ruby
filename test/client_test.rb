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

  def test_rights_links_create_sends_the_subject_and_options
    t = FakeTransport.new(body: JSON.generate("url" => "https://cookiemunch.net/r/s1?t=a.b", "expiresAt" => 1))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)
    out = cm.rights_links.create("s1", email: "p@x.com", user_id: "u-1", rights: ["access"], ttl_seconds: 600)
    assert_equal "https://cookiemunch.net/r/s1?t=a.b", out["url"]
    assert_equal "POST", t.last.method
    assert_equal "https://api.cookiemunch.net/v1/sites/s1/rights-links", t.last.url
    assert_equal({ "subject" => { "email" => "p@x.com", "userId" => "u-1" }, "rights" => ["access"], "ttlSeconds" => 600 }, JSON.parse(t.last.body))
    cm.rights_links.create("s1", email: "p@x.com")
    assert_equal({ "subject" => { "email" => "p@x.com" } }, JSON.parse(t.last.body))
  end
end

class OrgMailProviderTest < Minitest::Test
  def test_get_set_test_remove
    t = FakeTransport.new(body: JSON.generate({}))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    cm.org.mail_provider
    assert_equal ["GET", "https://api.cookiemunch.net/v1/org/mail-provider"], [t.last.method, t.last.url]

    cm.org.set_mail_provider(provider: "postmark", from_email: "p@acme.com", secret: "tok", reply_to: "dpo@acme.com")
    assert_equal ["PUT", "https://api.cookiemunch.net/v1/org/mail-provider"], [t.last.method, t.last.url]
    assert_equal({ "provider" => "postmark", "fromEmail" => "p@acme.com", "replyTo" => "dpo@acme.com", "secret" => "tok" }, JSON.parse(t.last.body))

    cm.org.test_mail_provider("me@acme.com")
    assert_equal ["POST", "https://api.cookiemunch.net/v1/org/mail-provider/test"], [t.last.method, t.last.url]
    assert_equal({ "to" => "me@acme.com" }, JSON.parse(t.last.body))
    cm.org.test_mail_provider
    assert_equal({}, JSON.parse(t.last.body))

    cm.org.remove_mail_provider
    assert_equal ["DELETE", "https://api.cookiemunch.net/v1/org/mail-provider"], [t.last.method, t.last.url]
  end
end

class RightsPageSdkTest < Minitest::Test
  def test_rights_page_dry_run_and_rollback
    t = FakeTransport.new(body: JSON.generate({}))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    cm.rights_page.dry_run("s1", { "seo" => { "title" => "x" } })
    assert_equal "PATCH", t.last.method
    assert_equal "https://api.cookiemunch.net/v1/sites/s1/rights-page?dryRun=1", t.last.url
    cm.rights_page.dry_run("s1", { "v" => 1 }, replace: true)
    assert_equal "PUT", t.last.method
    cm.rights_page.rollback("s1", 2)
    assert_equal "https://api.cookiemunch.net/v1/sites/s1/rights-page/rollback", t.last.url
    assert_equal({ "version" => 2 }, JSON.parse(t.last.body))
  end

  def test_publish_and_rollback_send_base_updated_at
    t = FakeTransport.new(body: JSON.generate({}))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)
    cm.rights_page.publish("s1", base_updated_at: 7)
    assert_equal({ "baseUpdatedAt" => 7 }, JSON.parse(t.last.body))
    cm.rights_page.publish("s1", base_updated_at: nil)
    assert_equal({ "baseUpdatedAt" => nil }, JSON.parse(t.last.body))
    cm.rights_page.publish("s1")
    assert_equal({}, JSON.parse(t.last.body))
    cm.rights_page.rollback("s1", 2, base_updated_at: 9)
    assert_equal({ "version" => 2, "baseUpdatedAt" => 9 }, JSON.parse(t.last.body))
    cm.rights_page.rollback("s1", 2, base_updated_at: nil)
    assert_equal({ "version" => 2, "baseUpdatedAt" => nil }, JSON.parse(t.last.body))
  end
end

class RightsIdentitySdkTest < Minitest::Test
  def test_site_and_org_default
    t = FakeTransport.new(body: JSON.generate({}))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    cm.rights_identity.get("s 1")
    assert_equal ["GET", "https://api.cookiemunch.net/v1/sites/s%201/rights-identity"], [t.last.method, t.last.url]
    cm.rights_identity.set("s1", type: "clerk", issuer: "https://clerk.acme.example", authorized_parties: ["https://www.acme.example"], trust_email_claim: true)
    assert_equal ["PUT", "https://api.cookiemunch.net/v1/sites/s1/rights-identity"], [t.last.method, t.last.url]
    assert_equal({ "type" => "clerk", "issuer" => "https://clerk.acme.example", "authorizedParties" => ["https://www.acme.example"], "trustEmailClaim" => true }, JSON.parse(t.last.body))
    cm.rights_identity.remove("s1")
    assert_equal ["DELETE", "https://api.cookiemunch.net/v1/sites/s1/rights-identity"], [t.last.method, t.last.url]

    cm.org.rights_identity
    assert_equal ["GET", "https://api.cookiemunch.net/v1/org/rights-identity"], [t.last.method, t.last.url]
    cm.org.set_rights_identity(type: "oidc_jwt", issuer: "https://id.acme.example", jwks_url: "https://id.acme.example/keys", audience: "acme-rights", session_cookie_name: "sid")
    assert_equal({ "type" => "oidc_jwt", "issuer" => "https://id.acme.example", "jwksUrl" => "https://id.acme.example/keys", "audience" => "acme-rights", "sessionCookieName" => "sid" }, JSON.parse(t.last.body))
    cm.org.remove_rights_identity
    assert_equal ["DELETE", "https://api.cookiemunch.net/v1/org/rights-identity"], [t.last.method, t.last.url]
  end
end

class RightsCaptchaSdkTest < Minitest::Test
  def test_site_and_org_default
    t = FakeTransport.new(body: JSON.generate({}))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)

    cm.rights_captcha.get("s 1")
    assert_equal ["GET", "https://api.cookiemunch.net/v1/sites/s%201/rights-captcha"], [t.last.method, t.last.url]
    cm.rights_captcha.set("s1", mode: "own", provider: "hcaptcha", site_key: "k-12345678", secret: "sec")
    assert_equal ["PUT", "https://api.cookiemunch.net/v1/sites/s1/rights-captcha"], [t.last.method, t.last.url]
    assert_equal({ "mode" => "own", "provider" => "hcaptcha", "siteKey" => "k-12345678", "secret" => "sec" }, JSON.parse(t.last.body))
    cm.rights_captcha.remove("s1")
    assert_equal ["DELETE", "https://api.cookiemunch.net/v1/sites/s1/rights-captcha"], [t.last.method, t.last.url]

    cm.org.rights_captcha
    assert_equal ["GET", "https://api.cookiemunch.net/v1/org/rights-captcha"], [t.last.method, t.last.url]
    cm.org.set_rights_captcha(mode: "off")
    assert_equal({ "mode" => "off" }, JSON.parse(t.last.body))
    cm.org.remove_rights_captcha
    assert_equal ["DELETE", "https://api.cookiemunch.net/v1/org/rights-captcha"], [t.last.method, t.last.url]
  end
end

class LintConfigSdkTest < Minitest::Test
  def test_lint_config_posts_and_replace_adds_the_flag
    t = FakeTransport.new(body: JSON.generate({ "designWarnings" => [], "score" => 100 }))
    cm = CookieMunch::Client.new(api_key: "fck_secret", transport: t)
    cm.sites.lint_config("s1", { "banner" => { "type" => "accept-only" } })
    assert_equal ["POST", "https://api.cookiemunch.net/v1/sites/s1/config/lint"], [t.last.method, t.last.url]
    assert_equal({ "banner" => { "type" => "accept-only" } }, JSON.parse(t.last.body))
    cm.sites.lint_config("s1", { "v" => 2 }, replace: true)
    assert_equal "https://api.cookiemunch.net/v1/sites/s1/config/lint?replace=1", t.last.url
  end
end
