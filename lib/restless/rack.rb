# frozen_string_literal: true

require "json"

require_relative "capture"
require_relative "injection"
require_relative "request_id"
require_relative "stack_frames"
require_relative "text"

module Restless
  # Rack middleware. One interface covers Rails, Sinatra, Hanami, Grape,
  # Roda and anything else that speaks Rack.
  #
  # CONTRACT.md section 14 is explicit that adapters are per-language and not
  # standardised, so this does NOT reproduce the Node SDK's duck-typed
  # universal middleware or its framework list. Rack is the one interface
  # worth having in Ruby.
  #
  # SAFETY-001 governs everything below: no code path here may propagate an
  # exception into the customer's app or response lifecycle. The only
  # exception deliberately re-raised is the customer's own.
  class Middleware
    # SAFETY-007. Bodies over this are recorded WITHOUT a body; headers are
    # still stamped. Capture must never buffer unboundedly.
    MAX_CAPTURE_BYTES = 1024 * 1024

    # SAFETY-007. Streaming responses are passed straight through, never
    # buffered.
    STREAMING_TYPES = %w[text/event-stream].freeze

    # SAFETY-006. A serialized parse of multipart is meaningless.
    SKIPPED_REQUEST_TYPES = %w[multipart/form-data].freeze

    # Framework hooks that carry the matched route template, most specific
    # first. Override wholesale with the `route:` lambda.
    ROUTE_ENV_KEYS = %w[
      restless.route
      sinatra.route
      action_dispatch.route_uri_pattern
      grape.routing_args
    ].freeze

    # Frameworks that catch the exception themselves still leave it in the
    # env, which is the only way to reach the `stack` fingerprint strategy
    # for a handled 500.
    EXCEPTION_ENV_KEYS = %w[
      restless.exception
      sinatra.error
      action_dispatch.exception
      rack.exception
    ].freeze

    # `use client.rack` hands Rack::Builder something that responds to
    # `new(app)`; this is that something.
    class Factory
      def initialize(client, options)
        @client = client
        @options = options
      end

      def new(app)
        Middleware.new(app, @client, @options)
      end
    end

    def self.factory(client, **options)
      Factory.new(client, options)
    end

    # Read-only view of the request, handed to the setup callback.
    class RequestInfo
      attr_reader :env

      def initialize(env)
        @env = env
      end

      # Case-insensitive, accepts either `Authorization` or `authorization`.
      def header(name)
        key = "HTTP_#{name.to_s.upcase.tr('-', '_')}"
        return @env[key] if @env.key?(key)
        return @env["CONTENT_TYPE"] if key == "HTTP_CONTENT_TYPE"
        return @env["CONTENT_LENGTH"] if key == "HTTP_CONTENT_LENGTH"

        nil
      end
      alias [] header

      def request_method
        @env["REQUEST_METHOD"]
      end

      def path
        "#{@env['SCRIPT_NAME']}#{@env['PATH_INFO']}"
      end

      def query_string
        @env["QUERY_STRING"].to_s
      end

      def url
        Middleware.full_url(@env)
      end
    end

    def initialize(app, client, options = {})
      @app = app
      @client = client
      @engine = client.engine
      @route_resolver = options[:route]
      @capture_request_body =
        options.key?(:capture_request_body) ? options[:capture_request_body] : true
    end

    def call(env)
      started_at = Time.now
      clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      request = RequestInfo.new(env)

      setup = safely({}) { @engine.resolve(request) }
      our_id = RequestId.new_request_id

      block = safely(nil) { CaptureEngine.resolve_block(setup["block"]) }
      if block
        # SETUP-004: reject before the handler runs.
        return finish(env, setup, our_id, started_at, clock, block_response(block),
                      request_body: capture_request_body(env), stack_frame: nil)
      end

      request_body = capture_request_body(env)

      begin
        status, headers, body = @app.call(env)
      rescue Exception => e # rubocop:disable Lint/RescueException
        # The customer's exception. Capture it with the stack so the
        # fingerprint keys on the RAISING method (FP-043), then re-raise so
        # their own error handling is completely unaffected.
        frame = safely(nil) { StackFrames.from_exception(e) }
        safely(nil) do
          finish(env, setup, our_id, started_at, clock,
                 [500, { "content-type" => "application/json" },
                  [JSON.generate({ "error" => "Internal Server Error" })]],
                 request_body: request_body, stack_frame: frame, inject: false)
        end
        raise
      end

      # A framework that handled the exception itself still left it here.
      frame = nil
      if status.to_i >= 500
        error = EXCEPTION_ENV_KEYS.map { |k| env[k] }.find { |v| v.respond_to?(:backtrace) }
        frame = safely(nil) { StackFrames.from_exception(error) } if error
      end

      finish(env, setup, our_id, started_at, clock, [status, headers, body],
             request_body: request_body, stack_frame: frame)
    end

    def self.full_url(env)
      scheme = env["rack.url_scheme"] || "http"
      host = env["HTTP_HOST"] || "#{env['SERVER_NAME']}:#{env['SERVER_PORT']}"
      url = +"#{scheme}://#{host}#{env['SCRIPT_NAME']}#{env['PATH_INFO']}"
      query = env["QUERY_STRING"].to_s
      url << "?" << query unless query.empty?
      url
    end

    # `GET /pets/:id` (Sinatra) and `/pets/:id(.:format)` (Rails) both become
    # `/pets/{id}`, which is what every other Restless SDK reports for the
    # same endpoint. Without that the same API produces two different
    # `routePattern` values depending on the language it was written in.
    def self.normalize_route_pattern(pattern)
      route = Text.ws_trim(pattern.to_s)
      return nil if route.empty?

      route = route.sub(/\A[A-Z]+[ \t]+/, "")     # strip the leading method
      route = route.sub(/\(\.:format\)\z/, "")    # Rails' optional format
      route = route.gsub(/:([A-Za-z_][A-Za-z0-9_]*)/, '{\1}')
      route.empty? ? nil : route
    end

    private

    def route_pattern(env)
      if @route_resolver
        resolved = safely(nil) { @route_resolver.call(env) }
        return Middleware.normalize_route_pattern(resolved) if resolved
      end

      ROUTE_ENV_KEYS.each do |key|
        value = env[key]
        next unless value.is_a?(String) && !value.empty?

        normalized = Middleware.normalize_route_pattern(value)
        return normalized if normalized
      end
      nil
    end

    def block_response(block)
      body = JSON.generate({ "error" => block[:message] })
      [block[:status],
       { "content-type" => "application/json",
         "content-length" => body.bytesize.to_s },
       [body]]
    end

    # Assemble the capture, inject, record, and hand the response back.
    def finish(env, setup, our_id, started_at, clock, response,
               request_body:, stack_frame:, inject: true)
      status, headers, body = response
      headers = normalize_headers(headers)

      body_text, body = read_response_body(body, headers)
      duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - clock) * 1000).round

      captured = {
        "requestId" => our_id,
        "startedAt" => Text.iso8601_millis(started_at),
        "duration" => duration,
        "routePattern" => route_pattern(env),
        "request" => {
          "method" => env["REQUEST_METHOD"],
          "url" => Middleware.full_url(env),
          "headers" => request_headers(env),
          "body" => request_body
        },
        "response" => {
          "status" => status.to_i,
          "headers" => headers,
          "body" => body_text
        },
        "user" => setup
      }
      captured.delete("routePattern") if captured["routePattern"].nil?

      options = @engine.uploader.options
      # REQID-010, REQID-011.
      headers.merge!(RequestId.response_headers(
                       our_id, request_headers(env),
                       options[:request_id_prefix], options[:has_api_key]
                     ))

      if inject && status.to_i >= 400
        # INJECT-009: the fingerprint is computed against the customer's RAW
        # response, snapshotted before any injected header or body field.
        fingerprint = @engine.compute_fingerprint(captured, stack_frame)
        if fingerprint
          captured["errorFingerprint"] = CaptureEngine.wire_fingerprint(fingerprint)
          # INJECT-010: computed once and reused for both the recovery lookup
          # and the upload payload.
          #
          # FP-047: the fingerprint-aware lookup, not the key-only one, so a
          # message still attached to the pre-stack-strategy key keeps being
          # injected while the group migrates.
          recovery = @engine.lookup_recovery_for(fingerprint)
        end

        injection = safely(nil) do
          Injection.build(
            status: status.to_i,
            request_id: our_id,
            base_url: options[:base_url],
            prefix: options[:request_id_prefix],
            recovery: recovery,
            method: env["REQUEST_METHOD"],
            path: captured["routePattern"],
            docs_url: @engine.docs_url
          )
        end

        if injection
          headers.merge!(injection[:headers]) # INJECT-002
          rewritten = Injection.apply_body(body_text, headers["content-type"],
                                           injection[:debug]) # INJECT-003
          if rewritten && !rewritten.equal?(body_text) && rewritten != body_text
            body = [rewritten]
            # INJECT-008: recompute Content-Length or the client truncates
            # mid-JSON.
            headers["content-length"] = rewritten.bytesize.to_s if headers.key?("content-length")
          end
        end
      end

      safely(nil) { @engine.record(captured, stack_frame: stack_frame) }

      [status, headers, body]
    rescue StandardError => e
      Env.debug_log("middleware finish failed: #{e.class}: #{e.message}")
      response
    end

    # Rack 2 hands out `Content-Type`, Rack 3 requires `content-type`.
    # Downcasing is safe in both directions: header names are
    # case-insensitive on the wire, and every lookup below assumes lowercase.
    def normalize_headers(headers)
      out = {}
      (headers || {}).each do |name, value|
        out[name.to_s.downcase] = value.is_a?(Array) ? value.join(", ") : value.to_s
      end
      out
    end

    def request_headers(env)
      out = {}
      env.each do |key, value|
        next unless key.is_a?(String)

        if key.start_with?("HTTP_") && key != "HTTP_VERSION"
          # HAR-004: duplicate values arrive already joined by the server.
          out[key[5..-1].downcase.tr("_", "-")] = value.to_s
        elsif key == "CONTENT_TYPE" || key == "CONTENT_LENGTH"
          out[key.downcase.tr("_", "-")] = value.to_s
        end
      end
      out
    end

    def capture_request_body(env)
      return nil unless @capture_request_body

      content_type = env["CONTENT_TYPE"].to_s.downcase
      # SAFETY-006.
      return nil if SKIPPED_REQUEST_TYPES.any? { |t| content_type.include?(t) }

      input = env["rack.input"]
      return nil if input.nil?
      # Reading a non-rewindable input would consume the customer's body.
      # Rack 3 does not guarantee rewindability, so skip rather than break
      # the app -- SAFETY-001 outranks capture completeness.
      return nil unless input.respond_to?(:rewind) && input.respond_to?(:read)

      raw = input.read(MAX_CAPTURE_BYTES + 1)
      input.rewind
      return nil if raw.nil? || raw.empty?
      return nil if raw.bytesize > MAX_CAPTURE_BYTES

      Text.to_utf8(raw)
    rescue StandardError => e
      Env.debug_log("request body capture failed: #{e.class}: #{e.message}")
      nil
    end

    # Returns [captured_text_or_nil, body_to_return].
    def read_response_body(body, headers)
      content_type = headers["content-type"].to_s.downcase
      # SAFETY-007: never buffer a stream.
      return [nil, body] if STREAMING_TYPES.any? { |t| content_type.include?(t) }
      # Rack 3 streaming bodies respond to `call`, not `each`.
      return [nil, body] unless body.respond_to?(:each)

      chunks = []
      size = 0
      body.each do |chunk|
        chunks << chunk
        size += chunk.to_s.bytesize
      end
      body.close if body.respond_to?(:close)

      return [nil, chunks] if size > MAX_CAPTURE_BYTES

      joined = chunks.join
      [joined.empty? ? nil : Text.to_utf8(joined), chunks]
    rescue StandardError => e
      Env.debug_log("response body capture failed: #{e.class}: #{e.message}")
      [nil, body]
    end

    # SAFETY-001.
    def safely(fallback)
      yield
    rescue StandardError => e
      Env.debug_log("swallowed: #{e.class}: #{e.message}")
      fallback
    end
  end
end
