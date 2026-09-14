# frozen_string_literal: true

module CookieMunch
  # Base class for every error raised by the SDK.
  class Error < StandardError; end

  # Raised for any non-2xx HTTP response from the Cookie Munch Developer API.
  #
  # `message` is the server's `error` field when the body is JSON with one;
  # otherwise a generic "request failed with status <n>" message is used.
  # The raw response is always available via {#status} and {#body}, and the
  # server's machine-readable `code` (when present) via {#code}.
  class ApiError < Error
    # @return [Integer] the HTTP status code
    attr_reader :status
    # @return [String] the raw (undecoded) response body
    attr_reader :body
    # @return [String, nil] the server's `code` field, when present
    attr_reader :code

    def initialize(status, message, body: "", code: nil)
      @status = status
      @body = body
      @code = code
      super(message)
    end
  end
end
