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
end
