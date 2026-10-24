# frozen_string_literal: true

require_relative "test_helper"

# The shapes that matter on the platform surface: what is sent, and what comes back.
class PlatformTest < Minitest::Test
  def client(transport)
    CookieMunch::Client.new(api_key: "fck_test", base_url: "https://api.example.com", transport: transport)
  end

  def body_of(call)
    call.body ? JSON.parse(call.body) : nil
  end

  # Numestri F-01: per-language purposes, and dry_run on every declaration write.
  def test_declared_cookies_purposes_and_dry_run
    t = FakeTransport.new
    c = client(t)
    c.sites.declare_cookie("cb", "sid", "necessary", "Signed in.", purposes: { "es" => "Sesión." })
    c.sites.declare_cookie("cb", "sid", "necessary", "Signed in.", dry_run: true)
    c.sites.declare_cookies("cb", [{ "name" => "a", "category" => "necessary", "purpose" => "A" }], replace: true, dry_run: true)
    out = c.sites.undeclare_cookie("cb", "sid", dry_run: true)
    assert_equal "https://api.example.com/v1/sites/cb/cookies/sid", t.calls[0].url
    assert_equal({ "category" => "necessary", "purpose" => "Signed in.", "purposes" => { "es" => "Sesión." } }, body_of(t.calls[0]))
    assert_equal "https://api.example.com/v1/sites/cb/cookies/sid?dryRun=1", t.calls[1].url
    assert_equal "https://api.example.com/v1/sites/cb/cookies?dryRun=1", t.calls[2].url
    assert_equal true, body_of(t.calls[2])["replace"]
    assert_equal ["DELETE", "https://api.example.com/v1/sites/cb/cookies/sid?dryRun=1"], [t.calls[3].method, t.calls[3].url]
    assert_equal({}, out)
  end

  def test_undeclare_without_dry_run_returns_nil
    t = FakeTransport.new(status: 204, body: "")
    assert_nil client(t).sites.undeclare_cookie("cb", "sid")
  end

  def test_deprovision_suspends_by_default_and_purges_only_when_asked
    t = FakeTransport.new(status: 204, body: "")
    c = client(t)
    c.reseller.deprovision("c1")
    c.reseller.deprovision("c1", purge: true)
    assert_equal "https://api.example.com/v1/reseller/customers/c1", t.calls[0].url
    assert_equal "https://api.example.com/v1/reseller/customers/c1?purge=true", t.calls[1].url
  end

  def test_update_distinguishes_clearing_routing_from_leaving_it
    t = FakeTransport.new
    c = client(t)
    c.reseller.update("c1", status: "suspended")
    c.reseller.update("c1", dsar_routing: nil)
    assert_equal({ "status" => "suspended" }, body_of(t.calls[0]))
    assert_equal({ "dsarRouting" => nil }, body_of(t.calls[1]))
  end

  def test_issue_sends_least_privilege_fields
    t = FakeTransport.new
    client(t).keys.issue(name: "agency", scopes: ["consent:read"], cbids: ["cb_shop"], expires_in_days: 30)
    assert_equal({ "name" => "agency", "scopes" => ["consent:read"], "cbids" => ["cb_shop"], "expiresInDays" => 30 },
                 body_of(t.calls[0]))
  end

  def test_policy_is_markdown_with_options_in_the_query
    t = FakeTransport.new(headers: { "content-type" => "text/markdown" }, body: "# Privacy policy")
    md = client(t).sites.policy("s1", contact_email: "dpo@x.com", jurisdictions: %w[gdpr ccpa])
    assert_equal "# Privacy policy", md
    assert_equal "https://api.example.com/v1/sites/s1/policy?contactEmail=dpo%40x.com&jurisdictions=gdpr%2Cccpa",
                 t.calls[0].url
  end

  def test_ropa_export_and_dsar_notice_are_text
    assert_equal "a,b\n", client(FakeTransport.new(headers: { "content-type" => "text/csv" }, body: "a,b\n")).ropa.export_csv
    assert_equal "Dear subject",
                 client(FakeTransport.new(headers: { "content-type" => "text/plain" }, body: "Dear subject")).dsar.response("d1")
  end

  def test_identifiers_travel_in_the_body_never_the_url
    t = FakeTransport.new
    ids = [{ "space" => "email_sha256", "value" => "abc" }]
    c = client(t)
    c.identity.resolve(ids)
    c.vault.current(ids)
    c.profile.activate(ids, "marketing")
    t.calls.each do |call|
      assert_equal "POST", call.method
      refute_includes call.url, "abc"
      assert_equal ids, body_of(call)["identifiers"]
    end
  end

  def test_rights_page_domains
    t = FakeTransport.new
    c = client(t)
    c.rights_page.list_domains("s 1")
    c.rights_page.add_domain("s", "privacy.acme.com")
    c.rights_page.verify_domain("s", "privacy.acme.com")
    c.rights_page.remove_domain("s", "privacy.acme.com")
    base = "https://api.example.com/v1/sites"
    assert_equal %w[GET POST POST DELETE], t.calls.map(&:method)
    assert_equal "#{base}/s%201/rights-page/domains", t.calls[0].url
    assert_equal({ "hostname" => "privacy.acme.com" }, body_of(t.calls[1]))
    assert_equal "#{base}/s/rights-page/domains/privacy.acme.com/verify", t.calls[2].url
    assert_equal "#{base}/s/rights-page/domains/privacy.acme.com", t.calls[3].url
  end

  def test_executor_presets_canary_and_upgrade
    t = FakeTransport.new
    c = client(t)
    c.fulfillment.executor_presets
    c.fulfillment.connect_executor_preset(preset: "forumulate", secret_key: "fck_12345678", org_id: "org-1")
    c.fulfillment.test_executor("ex 1", canary: true)
    c.fulfillment.upgrade_executor_preset("ex 1", atlas_id_app_id: "app_1", dry_run: true)
    c.fulfillment.executor("ex 1")
    assert_equal [
      ["GET", "https://api.example.com/v1/dsar/executors/presets"],
      ["POST", "https://api.example.com/v1/dsar/executors"],
      ["POST", "https://api.example.com/v1/dsar/executors/ex%201/test"],
      ["POST", "https://api.example.com/v1/dsar/executors/ex%201/upgrade-preset?dryRun=1"],
      ["GET", "https://api.example.com/v1/dsar/executors/ex%201"]
    ], t.calls.map { |x| [x.method, x.url] }
    assert_equal({ "preset" => "forumulate", "secretKey" => "fck_12345678", "orgId" => "org-1" }, body_of(t.calls[1]))
    assert_equal({ "canary" => true }, body_of(t.calls[2]))
    assert_equal({ "atlasIdAppId" => "app_1" }, body_of(t.calls[3]))
  end

  def test_executor_webhook_check_deliveries_and_dry_runs
    t = FakeTransport.new
    c = client(t)
    c.fulfillment.test_executor_webhook("ex 1", headers: { "x-sig" => "v1,abc" }, body: '{"a":1}')
    c.fulfillment.executor_webhook_deliveries("ex 1")
    c.fulfillment.connect_executor(system: "crm", base_url: "https://crm.example", secret_key: "sk_12345678", profile: {}, dry_run: true)
    c.fulfillment.update_executor("ex 1", auto: false, dry_run: true)
    c.fulfillment.update_executor("ex 1", auto: false)
    assert_equal [
      "POST https://api.example.com/v1/dsar/executors/ex%201/webhook/test",
      "GET https://api.example.com/v1/dsar/executors/ex%201/webhook/deliveries",
      "POST https://api.example.com/v1/dsar/executors?dryRun=1",
      "PATCH https://api.example.com/v1/dsar/executors/ex%201?dryRun=1",
      "PATCH https://api.example.com/v1/dsar/executors/ex%201"
    ], t.calls.map { |x| "#{x.method} #{x.url}" }
    assert_equal({ "headers" => { "x-sig" => "v1,abc" }, "body" => '{"a":1}' }, body_of(t.calls[0]))
  end

  def test_retire_and_unretire
    t = FakeTransport.new
    c = client(t)
    c.sites.retire_cookie("cb", "old", renamed_to: "new", note: "v2")
    c.sites.retire_cookie("cb", "atlas_*", dry_run: true)
    out = c.sites.unretire_cookie("cb", "old", dry_run: true)
    assert_equal ["POST", "https://api.example.com/v1/sites/cb/cookies/old/retire"], [t.calls[0].method, t.calls[0].url]
    assert_equal({ "renamedTo" => "new", "note" => "v2" }, body_of(t.calls[0]))
    assert_equal "https://api.example.com/v1/sites/cb/cookies/atlas_*/retire?dryRun=1", t.calls[1].url
    assert_equal({}, body_of(t.calls[1]))
    assert_equal ["DELETE", "https://api.example.com/v1/sites/cb/cookies/old/retire?dryRun=1"], [t.calls[2].method, t.calls[2].url]
    assert_equal({}, out)
    assert_nil client(FakeTransport.new(status: 204, body: "")).sites.unretire_cookie("cb", "old")
  end

  def test_scan_wait_and_wait_for_scan
    t = FakeTransport.new
    c = client(t)
    c.sites.scan("cb", wait: 30)
    c.sites.scan_status("cb", wait: 5)
    assert_equal "https://api.example.com/v1/sites/cb/scan?wait=30", t.calls[0].url
    assert_equal "https://api.example.com/v1/sites/cb/scan?wait=5", t.calls[1].url

    t2 = FakeTransport.new(body: JSON.generate("status" => "idle", "state" => "done", "cookieCount" => 3))
    t2.respond(status: 200, body: JSON.generate("status" => "scanning", "state" => "scanning"))
    r = client(t2).sites.wait_for_scan("cb", timeout_ms: 120_000)
    assert_equal "done", r["state"]
    assert_equal 2, t2.calls.length
    # The default client timeout is 30 s, so it never asks the server to hold longer than that.
    assert_equal "https://api.example.com/v1/sites/cb/scan?wait=25", t2.calls[0].url
  end
end
