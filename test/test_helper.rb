# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "cookiemunch"

# Temporarily replace Net::HTTP.start for a block, then restore it. Lets tests
# exercise the real default transport with zero network and no external mocking
# gem (minitest 6 no longer ships minitest/mock).
def with_stubbed_net_http_start(stub)
  original = Net::HTTP.method(:start)
  Net::HTTP.define_singleton_method(:start, stub)
  yield
ensure
  Net::HTTP.define_singleton_method(:start, original)
end

# A recording, no-network transport. Captures the last request and returns a
# pre-canned [status, headers, body] response (or one queued per call).
class FakeTransport
  Call = Struct.new(:method, :url, :headers, :body)

  attr_reader :calls

  def initialize(status: 200, headers: { "content-type" => "application/json" }, body: "{}")
    @default = [status, headers, body]
    @queue = []
    @calls = []
  end

  # Queue a response for the next call. Returns self for chaining.
  def respond(status:, headers: { "content-type" => "application/json" }, body: "")
    @queue << [status, headers, body]
    self
  end

  def call(method, url, headers, body)
    @calls << Call.new(method, url, headers, body)
    @queue.empty? ? @default : @queue.shift
  end

  def last
    @calls.last
  end
end
