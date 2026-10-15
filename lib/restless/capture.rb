# frozen_string_literal: true

require "json"

require_relative "caches"
require_relative "fingerprint"
require_relative "redact"
require_relative "sampling"
require_relative "uploader"

module Restless
  # The capture engine: redaction choke point (section 4), the two caches
  # (section 11), fingerprinting (section 5) and the hand-off to the uploader
  # (sections 8 and 9).
  #
  # Every adapter goes through here. No adapter may bypass `record`, which is
  # the single point where redaction runs.
  class CaptureEngine
    # REDACT-030.
    MAX_BODY_BYTES = Redact::MAX_BODY_BYTES

    attr_reader :uploader, :enrich_cache, :recovery_cache

    # `sampling` is a Sampling::Config, already merged and validated. Nil, or
    # the default config, means no sampling at all.
    def initialize(api_key:, base_url:, request_id_prefix: nil, redact: nil,
                   sampling: nil, transport: nil)
      @redact = redact || {}
      # Only kept for a non-default config (SAMPLE-041). Without one, `sample`
      # is a constant :full and nothing about sampling touches the wire.
      @sampling = sampling && !sampling.default? ? sampling : nil
      @sampling_hash = @sampling && Sampling.digest(@sampling)
      @sampling_report = :unsent
      @sampling_mutex = Mutex.new
      # Test hook: anything responding to `call` with a Float in [0, 1).
      @random = -> { Random.rand }
      @enrich_cache = EnrichCache.new
      @recovery_cache = RecoveryCache.new
      @portal_url = nil
      @docs_mutex = Mutex.new
      @callback = nil
      @uploader = Uploader.new(
        api_key: api_key,
        base_url: base_url,
        request_id_prefix: request_id_prefix,
        transport: transport,
        sampling_hash: @sampling_hash,
        on_response: method(:handle_server_response)
      )
    end

    attr_writer :random

    # The sampling outcome for one request (CONTRACT.md SAMPLE-030): :full,
    # :stub or :drop. The middleware calls this exactly once per request, when
    # the status is final and before any SDK header is added (SAMPLE-032),
    # and acts on the answer.
    #
    # Never raises. Anything unexpected sends the request in full
    # (SAMPLE-035): sampling may only ever remove data, never break capture.
    def sample(method, route_pattern, status)
      return :full if @sampling.nil?

      report_sampling(false)
      mode = Sampling.resolve_mode(@sampling, method, route_pattern)
      Sampling.decide(mode, status.to_i, @random.call)
    rescue StandardError => e
      Env.debug_log("sampling failed, sending in full: #{e.class}: #{e.message}")
      :full
    end

    def callback=(callback)
      @callback = callback
    end

    # INJECT-006. The latest server-resolved docs origin, or nil when no batch
    # has round-tripped yet.
    # INJECT-006. The server-published portal origin every injected URL is
    # built on. Nil before the first upload round-trip, and then nothing is
    # emitted rather than a guess.
    def portal_url
      @docs_mutex.synchronize { @portal_url }
    end

    def flush
      @uploader.flush
    end

    # WIRE-020..023, CACHE-006, CACHE-011..013.
    def handle_server_response(body, batch_fingerprints)
      # WIRE-025, SAMPLE-053.
      report_sampling(true) if body["needsSamplingConfig"] == true

      needs = body["needsEnrichment"]
      if needs.is_a?(Array)
        needs.each { |key| @enrich_cache.invalidate(key) if key.is_a?(String) }
      end

      docs = body["docsUrl"]
      if docs.is_a?(String) && !docs.empty?
        # Origin only; strip trailing slashes so the server can be lax.
        # The wire key stays `docsUrl`: every already-deployed SDK reads it,
        # so renaming would strand them all with no portal origin (WIRE-023).
        @docs_mutex.synchronize { @portal_url = docs.sub(%r{/+\z}, "") }
      end

      messages = body["recoveryMessages"].is_a?(Hash) ? body["recoveryMessages"] : {}
      batch_fingerprints.each do |key|
        value = messages[key]
        if value.is_a?(String)
          @recovery_cache.set(key, value) # CACHE-011
        elsif messages.key?(key)
          @recovery_cache.set(key, nil)
        else
          # CACHE-012 + CACHE-013: negative-cache anything the server did not
          # answer for, without clobbering an existing positive entry. This is
          # what guarantees the SECOND occurrence of any error is a cache hit.
          @recovery_cache.set_negative_unless_present(key)
        end
      end
    rescue StandardError => e
      Env.debug_log("server response handling failed: #{e.class}: #{e.message}")
    end

    # CACHE-010. Synchronous, in-process, no I/O, never blocks the response.
    def lookup_recovery(fingerprint_key)
      @recovery_cache.lookup(fingerprint_key)
    end

    # FP-002. Errors only; the ingest treats an absent fingerprint as success.
    def compute_fingerprint(captured, stack_frame = nil)
      response = captured["response"] || {}
      status = response["status"].to_i
      return nil if status < 400

      body = response["body"]
      if body.is_a?(String)
        begin
          body = JSON.parse(body, max_nesting: false)
        rescue StandardError
          # Leave it as a string; `extract_message` handles both shapes.
        end
      end

      request = captured["request"] || {}
      Fingerprint.compute(
        status: status,
        method: request["method"],
        route: captured["routePattern"],
        response_headers: response["headers"],
        response_body: body,
        stack_frame: stack_frame
      )
    rescue StandardError => e
      Env.debug_log("fingerprint failed: #{e.class}: #{e.message}")
      nil
    end

    # WIRE-017. The serialized form of a fingerprint.
    #
    # `Fingerprint::Result` is a Struct with symbol members, and the wire wants
    # string keys, so the mapping has to be written somewhere. It is written
    # once: the Rack middleware computes the fingerprint early (INJECT-009) and
    # must serialize it identically to `record` below.
    def self.wire_fingerprint(fingerprint)
      {
        "strategy" => fingerprint.strategy,
        "key" => fingerprint.key,
        "reason" => fingerprint.reason
      }
    end

    # Run the user's setup callback and resolve owner metadata.
    #
    # SAFETY-002: a callback that raises is caught and the request proceeds
    # with no user context attached.
    def resolve(request)
      return {} if @callback.nil?

      begin
        raw = @callback.call(request)
      rescue StandardError => e
        Env.debug_log("setup callback raised: #{e.class}: #{e.message}")
        return {}
      end
      return {} unless raw.is_a?(Hash)

      result = normalize_setup(raw)
      owner = result[:owner]
      return { "apiKey" => result[:api_key], "block" => result[:block],
               "extra" => result[:extra] }.compact if owner.nil?

      owner_id = owner[:id]
      enrich = owner[:enrich]
      # CACHE-002: key on owner id when present, else the masked end-user key,
      # so multiple end-users in one workspace share a slot.
      cache_key = (owner_id if owner_id && !owner_id.empty?) || result[:api_key]

      resolved_owner = { "id" => owner_id }.compact

      if enrich.respond_to?(:call) && owner_id && !owner_id.empty? && cache_key
        cached = @enrich_cache.get(cache_key)
        if cached
          # CACHE-003: the VALUE is cached, not merely a freshness flag, so
          # every upload carries owner metadata even when the callback was
          # skipped. The ingest cannot backfill.
          resolved_owner = resolved_owner.merge(cached)
        else
          enriched = begin
            enrich.call(owner_id)
          rescue StandardError => e
            # CACHE-005 / SAFETY-003: swallowed, and NOT cached, so the next
            # request retries.
            Env.debug_log("enrich raised: #{e.class}: #{e.message}")
            nil
          end
          if enriched.is_a?(Hash)
            stringified = stringify_keys(enriched)
            @enrich_cache.set(cache_key, stringified)
            resolved_owner = resolved_owner.merge(stringified)
          end
        end
      end

      # CACHE-007: when enrichment did not run or produced nothing, the upload
      # still carries the bare owner id so the dashboard can group by it.
      {
        "apiKey" => result[:api_key],
        "owner" => resolved_owner,
        "block" => result[:block],
        "extra" => result[:extra]
      }.compact
    end

    # SETUP-004.
    def self.resolve_block(block)
      return nil if block.nil? || block == false
      return { status: 403, message: "Forbidden" } if block == true
      return nil unless block.is_a?(Hash)

      status = block[:status] || block["status"] || 403
      message = block[:message] || block["message"] || "Forbidden"
      { status: status.to_i, message: message.to_s }
    end

    # The single redaction choke point. Redact, truncate, fingerprint, enqueue.
    def record(captured, stack_frame: nil)
      request = captured["request"] || {}
      response = captured["response"] || {}
      if captured["sampled"]
        # A stub ships as if no body had been captured (SAMPLE-034). Dropping
        # them here, before redaction, skips the parse work for exactly the
        # requests the customer asked to send less of.
        request = request.merge("body" => nil)
        response = response.merge("body" => nil)
      end
      request_headers = request["headers"] || {}
      response_headers = response["headers"] || {}

      sanitized = captured.dup
      sanitized["request"] = request.merge(
        "url" => Redact.redact_url(request["url"].to_s, @redact[:query_params] || []),
        "headers" => Redact.redact_headers(request_headers, @redact[:headers] || []),
        # REDACT-033: truncation runs AFTER redaction, so a secret cannot
        # survive by sitting past the byte limit.
        "body" => Redact.truncate_body(
          Redact.redact_body(request["body"], request_headers["content-type"],
                             @redact[:body_keys] || []),
          MAX_BODY_BYTES
        )
      )
      sanitized["response"] = response.merge(
        "headers" => Redact.redact_headers(response_headers, @redact[:headers] || []),
        "body" => Redact.truncate_body(
          Redact.redact_body(response["body"], response_headers["content-type"],
                             @redact[:body_keys] || []),
          MAX_BODY_BYTES
        )
      )

      if sanitized["errorFingerprint"].nil? && response["status"].to_i >= 400
        fingerprint = compute_fingerprint(sanitized, stack_frame)
        sanitized["errorFingerprint"] = self.class.wire_fingerprint(fingerprint) if fingerprint
      end

      @uploader.push(sanitized)
      nil
    rescue StandardError => e
      # SAFETY-001. Nothing in here may reach customer handler code.
      Env.debug_log("record failed: #{e.class}: #{e.message}")
      nil
    end

    private

    # Tell the ingest which config produced this process's uploads, so an
    # "off" endpoint does not read as a dead one (SAMPLE-050..053). Once per
    # process, on the first decision; again only when the server asks, and
    # never while a report is already in flight.
    def report_sampling(resend)
      return if @sampling.nil?

      send_now = @sampling_mutex.synchronize do
        if @sampling_report == :inflight || (@sampling_report == :sent && !resend)
          false
        else
          @sampling_report = :inflight
          true
        end
      end
      return unless send_now

      report = {
        "hash" => @sampling_hash,
        "default" => @sampling.default,
        "routes" => Sampling.sorted_routes(@sampling),
        "creator" => { "name" => SDK_NAME, "version" => VERSION }
      }
      # Fire and forget on a background thread, and a failure is not retried
      # (SAMPLE-051): the `x-restless-sampling` header on the next upload is
      # how the server asks again if it never got this.
      @uploader.send_sampling_report_async(report) do
        @sampling_mutex.synchronize { @sampling_report = :sent }
      end
    rescue StandardError => e
      @sampling_mutex.synchronize { @sampling_report = :sent }
      Env.debug_log("sampling report failed: #{e.class}: #{e.message}")
    end

    # Accept both `:api_key`/`"apiKey"` spellings so the callback reads
    # naturally in Ruby without losing the documented wire names (SETUP-001).
    def normalize_setup(raw)
      api_key = fetch_any(raw, :api_key, :apiKey, "api_key", "apiKey")
      owner_raw = fetch_any(raw, :owner, "owner")
      block = fetch_any(raw, :block, "block")

      known = %i[api_key apiKey owner block] + %w[api_key apiKey owner block]
      extra = {}
      raw.each do |key, value|
        next if known.include?(key)

        extra[key.to_s] = value
      end

      owner = nil
      if owner_raw.is_a?(Hash)
        owner = {
          id: fetch_any(owner_raw, :id, "id"),
          # SETUP-003: `enrich` is the ONLY channel for owner metadata.
          # Anything else inline on `owner` is dropped.
          enrich: fetch_any(owner_raw, :enrich, "enrich")
        }
      end

      { api_key: api_key, owner: owner, block: block,
        extra: extra.empty? ? nil : extra }
    end

    def fetch_any(hash, *keys)
      keys.each { |key| return hash[key] if hash.key?(key) }
      nil
    end

    def stringify_keys(hash)
      out = {}
      hash.each { |k, v| out[k.to_s] = v }
      out
    end
  end
end
