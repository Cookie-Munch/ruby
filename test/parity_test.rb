# frozen_string_literal: true

require_relative "test_helper"

# Every operation the Developer API documents is reachable from this SDK.
#
# The list lives in sdks/operations.json, generated from the server's OpenAPI document
# and shared by all six server-side SDKs. This calls every public method of every
# resource through a recording transport and checks what reached the wire covers the
# list — in both directions.
#
# Ruby has no type annotations, so placeholder arguments come from parameter names:
# plurals and known collection names become arrays, known payload names become hashes.
# The path is what is under test, and ids are strings, so that is enough.
class ParityTest < Minitest::Test
  # ../../operations.json in the product repo; ../operations.json in the published SDK repo.
  OPERATIONS_PATH = [
    File.expand_path("../../operations.json", __dir__),
    File.expand_path("../operations.json", __dir__),
  ].find { |p| File.exist?(p) }
  OPERATIONS = JSON.parse(File.read(OPERATIONS_PATH))["operations"]
  PLACEHOLDER = "x1"

  ARRAYS = %w[identifiers cbids scopes topics rules systems decisions operations events sites
              jurisdictions key_scopes requests].freeze
  HASHES = %w[config purposes attributes evidence map policy input vendor entry kit patch
              json controller white_label consent har].freeze
  BOOLS = %w[ok enabled opted_in purge mint_key delegated_access include_historical gpc default].freeze
  INTS = %w[limit days expires_in_days from to].freeze

  def placeholder(name)
    name = name.to_s
    return [{ "a" => PLACEHOLDER }] if %w[identifiers decisions topics rules systems operations requests sites].include?(name)
    return [PLACEHOLDER] if ARRAYS.include?(name)
    return { "a" => PLACEHOLDER } if HASHES.include?(name)
    return true if BOOLS.include?(name)
    return 1 if INTS.include?(name)

    PLACEHOLDER
  end

  def test_every_documented_operation_is_reachable
    seen = []
    transport = lambda do |method, url, _headers, _body|
      path = url.split("?", 2).first.split("/v1", 2).last.split("/", -1)
                .map { |seg| seg == PLACEHOLDER ? "{}" : seg }.join("/")
      seen << "#{method} /v1#{path}"
      [200, { "content-type" => "application/json" }, "{}"]
    end
    client = CookieMunch::Client.new(api_key: "fck_test", base_url: "https://api.example.com", transport: transport)

    targets = [client] + client.class.public_instance_methods(false)
                               .map { |m| client.public_send(m) rescue nil if client.method(m).arity.zero? }
                               .grep(CookieMunch::Resource)
    targets.each do |target|
      target.class.public_instance_methods(false).each do |name|
        # The client's own transport primitives take a raw path, not an operation.
        next if target.is_a?(CookieMunch::Client) && %i[request get].include?(name)

        method = target.method(name)
        args = []
        kwargs = {}
        method.parameters.each do |kind, pname|
          case kind
          when :req then args << placeholder(pname)
          when :keyreq then kwargs[pname] = placeholder(pname)
          end
        end
        begin
          kwargs.empty? ? method.call(*args) : method.call(*args, **kwargs)
        rescue StandardError
          nil # only what reached the wire matters here
        end
      end
    end

    missing = OPERATIONS - seen
    assert_empty missing, "#{missing.size} documented operations are unreachable:\n  #{missing.join("\n  ")}"
    assert_empty seen.uniq - OPERATIONS, "calls the API does not document"
  end
end
