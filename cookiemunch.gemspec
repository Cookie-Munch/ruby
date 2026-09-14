# frozen_string_literal: true

require_relative "lib/cookiemunch/version"

Gem::Specification.new do |spec|
  spec.name = "cookiemunch"
  spec.version = CookieMunch::VERSION
  spec.authors = ["Cookie Munch"]
  spec.summary = "Ruby client for the Cookie Munch Developer API"
  spec.description = "A small, dependency-free (stdlib-only) Ruby client for the " \
                     "Cookie Munch Consent Management Platform Developer API (/v1), " \
                     "including a helper for the public consent-ingest endpoint."
  spec.homepage = "https://cookiemunch.net"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => "https://github.com/Cookie-Munch/ruby",
    "documentation_uri" => "https://cookiemunch.net/docs",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir[
    "lib/**/*.rb",
    "README.md",
    "LICENSE",
    "cookiemunch.gemspec"
  ]
  spec.require_paths = ["lib"]

  # Runtime: stdlib only — no runtime dependencies.

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
