# frozen_string_literal: true

require_relative "capture"
require_relative "env"
require_relative "mask"
require_relative "request_id"
require_relative "settings"
require_relative "version"

module Restless
  # The public entry point.
  #
  #     client = Restless::Client.new(ENV["RESTLESS_KEY"])
  #     client.setup { |request| { api_key: client.mask(request.header("authorization")) } }
  #     use client.rack
  class Client
    attr_reader :engine

    # CONFIG-001..003, CONFIG-010..015.
    #
    # `redact` extends the built-in denylists; it can never shrink or replace
    # them (REDACT-014). Both the settings file and this option are additive
    # on top of the defaults (REDACT-015).
    #
    # `transport` is an internal test hook -- anything responding to
    # `call(url, headers, body) -> [status, body]` -- and is not public API.
    def initialize(api_key = nil, base_url: nil, api: nil, redact: nil,
                   transport: nil)
      resolved_key = Env.resolve_api_key(api_key)

      # CONFIG-002. Construction still succeeds and capture still runs; only
      # upload is disabled.
      if resolved_key.empty? && !Env.test_run?
        warn("[restless-sdk] no API key found -- set RESTLESS_KEY in your " \
             "environment or pass it to Restless::Client.new. Captured requests " \
             "will not be uploaded.")
      end

      # CONFIG-013/CONFIG-014 raise here, deliberately: guessing which API
      # entry to use would silently apply the wrong redaction list.
      entry = Settings.resolve_api(Settings.load, api)
      settings_redact = entry && entry[:redact]

      @engine = CaptureEngine.new(
        api_key: resolved_key,
        base_url: Env.resolve_base_url(base_url),
        request_id_prefix: entry && entry[:request_id_prefix],
        redact: merge_redact(settings_redact, redact),
        transport: transport
      )
    end

    # Register the per-request callback. Accepts a block or any callable.
    #
    #     client.setup do |request|
    #       { api_key: client.mask(request.header("authorization")),
    #         owner: { id: workspace_id, enrich: ->(id) { load_workspace(id) } } }
    #     end
    def setup(callable = nil, &block)
      @engine.callback = callable || block
      self
    end

    # MASK-001. Pass the RAW header value through; never substitute a
    # placeholder like "anonymous", whose last 4 characters would become the
    # mask tail and cluster unrelated callers together (SETUP-001).
    def mask(api_key)
      Mask.mask(api_key)
    end

    # BATCH-005.
    def flush
      @engine.flush
    end

    def new_request_id
      RequestId.new_request_id
    end

    # The Rack middleware factory. `use client.rack` in a `config.ru`, or
    # `app = client.rack.new(app)` by hand.
    def rack(**options)
      Middleware.factory(self, **options)
    end

    def spec_version
      SPEC_VERSION
    end

    def conformance_level
      CONFORMANCE_LEVEL
    end

    private

    def merge_redact(from_settings, from_options)
      settings = from_settings || {}
      options = from_options || {}
      {
        headers: list(settings["headers"]) + list(options[:headers] || options["headers"]),
        body_keys: list(settings["bodyKeys"]) + list(options[:body_keys] || options["bodyKeys"]),
        query_params: list(settings["queryParams"]) +
                      list(options[:query_params] || options["queryParams"])
      }
    end

    def list(value)
      value.is_a?(Array) ? value.map(&:to_s) : []
    end
  end
end
