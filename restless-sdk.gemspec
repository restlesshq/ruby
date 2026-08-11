# frozen_string_literal: true

require_relative "lib/restless/version"

Gem::Specification.new do |spec|
  spec.name = "restless-sdk"
  spec.version = Restless::VERSION
  spec.authors = ["Restless"]
  spec.summary = "Capture your API traffic and send it to Restless."
  spec.description = <<~TEXT
    Rack middleware that captures API traffic, redacts secrets before anything
    leaves the process, fingerprints error responses so they can be grouped and
    recovered from, and uploads the result to Restless. Works with Rails,
    Sinatra, Hanami, Grape, Roda and anything else that speaks Rack.

    Implements version #{Restless::SPEC_VERSION} of the Restless SDK Contract at
    level #{Restless::CONFORMANCE_LEVEL}.
  TEXT
  spec.homepage = "https://restless.ai"
  spec.license = "ISC"

  spec.metadata = {
    "source_code_uri" => "https://github.com/restlesshq/ruby",
    "bug_tracker_uri" => "https://github.com/restlesshq/ruby/issues",
    "restless_spec_version" => Restless::SPEC_VERSION,
    "restless_conformance_level" => Restless::CONFORMANCE_LEVEL
  }

  # 2.7 is the floor, matching what CI actually exercises and what README.md
  # and install.md both promise. The declaration used to say 2.6 - the macOS
  # system Ruby - which meant the gem installed onto a version nothing tests
  # and every other statement in the repo excluded. 2.6 has been end-of-life
  # since 2022; raising the floor removes a support claim rather than a
  # capability.
  spec.required_ruby_version = ">= 2.7"

  spec.files = Dir[
    "lib/**/*.rb",
    "exe/*",
    "spec/VECTORS_VERSION",
    "spec/vectors/*.json",
    "README.md",
    "CONFORMANCE.md",
    # Ships in the gem, not just the repo. The `api` CLI points installing
    # agents at `bundle show restless-sdk` for the full reference, and a file
    # left out of spec.files leaves that pointer resolving to nothing.
    "install.md"
  ]
  spec.require_paths = ["lib"]
  # exe/restless-conformance is a dev-only harness, deliberately NOT declared
  # as an executable: no customer should ever get `restless-conformance` on
  # their PATH.
  spec.executables = []

  # No runtime dependencies. Everything comes from the stdlib: json, net/http,
  # securerandom, digest, base64.
end
