# frozen_string_literal: true

# Cookie Munch Developer API — Ruby SDK.
#
# A small, dependency-free (stdlib-only) REST client for the `/v1` surface of
# the Cookie Munch Consent Management Platform, plus a helper for the public
# consent-ingest endpoint.
#
#   require "cookiemunch"
#   cm = CookieMunch::Client.new(api_key: "fck_…")
#   cm.me
#   cm.sites.list
#
# See {CookieMunch::Client} for the full method surface.
module CookieMunch
end

require_relative "cookiemunch/version"
require_relative "cookiemunch/errors"
require_relative "cookiemunch/resources"
require_relative "cookiemunch/client"
