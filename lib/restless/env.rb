# frozen_string_literal: true

module Restless
  # Environment probing: CONFIG-003, CONFIG-004, BATCH-003, BATCH-008.
  #
  # All of it is per-language by design (CONTRACT.md section 14); what is
  # normative is only the effect.
  module Env
    # WIRE-005.
    DEFAULT_BASE_URL = "https://ingress.restless.ai"

    module_function

    # BATCH-003's "language equivalent environment indicator". Ruby has three
    # spellings in the wild and no single winner, so all three are consulted,
    # most specific first.
    def app_env
      %w[RESTLESS_ENV RACK_ENV RAILS_ENV].each do |name|
        value = ENV[name]
        return value if value && !value.empty?
      end
      ""
    end

    def production?
      app_env == "production"
    end

    # BATCH-008. Under a test runner, captures are dropped rather than
    # uploaded, unless RESTLESS_SETUP_MODE=1. Test suites must not hammer
    # production ingest.
    #
    # The constants are checked rather than merely `defined?(Minitest)` at the
    # top level, because a library can pull minitest in without the process
    # actually being a test run.
    def test_run?
      return true if app_env == "test"
      return true if defined?(::RSpec::Core)
      return true if defined?(::Minitest::Test)
      return true if defined?(::Test::Unit::TestCase)

      false
    end

    def setup_mode?
      ENV["RESTLESS_SETUP_MODE"] == "1"
    end

    # CONFIG-004. `DEBUG` containing `restless` as a whitespace- or
    # comma-delimited token, or the literal `*`.
    def debug?
      flag = ENV["DEBUG"].to_s
      return true if flag == "*" || flag == "restless"

      flag.split(/[\s,]+/).include?("restless")
    end

    def debug_log(message)
      warn("[restless] #{message}") if debug?
    end

    # CONFIG-001. Explicit key, then RESTLESS_KEY, then README_API_KEY.
    def resolve_api_key(explicit = nil)
      [explicit, ENV["RESTLESS_KEY"], ENV["README_API_KEY"]]
        .find { |v| v && !v.empty? } || ""
    end

    # CONFIG-003.
    def resolve_base_url(explicit = nil)
      return explicit if explicit && !explicit.empty?

      from_env = ENV["RESTLESS_BASE_URL"]
      return from_env if from_env && !from_env.empty?

      DEFAULT_BASE_URL
    end

    def localhost?(base_url)
      base_url.include?("//localhost") || base_url.include?("//127.0.0.1")
    end
  end
end
