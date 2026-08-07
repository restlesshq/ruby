# frozen_string_literal: true

require "json"

require_relative "caches"
require_relative "fingerprint"
require_relative "redact"
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

    def initialize(api_key:, base_url:, request_id_prefix: nil, redact: nil,
                   transport: nil)
      @redact = redact || {}
      @enrich_cache = EnrichCache.new
      @recovery_cache = RecoveryCache.new
      @docs_url = nil
      @docs_mutex = Mutex.new
      @callback = nil
      @uploader = Uploader.new(
        api_key: api_key,
        base_url: base_url,
        request_id_prefix: request_id_prefix,
        transport: transport,
        on_response: method(:handle_server_response)
      )
    end

    def callback=(callback)
      @callback = callback
    end

    # INJECT-006. The latest server-resolved docs origin, or nil when no batch
    # has round-tripped yet.
    def docs_url
      @docs_mutex.synchronize { @docs_url }
    end

    def flush
      @uploader.flush
    end

    # WIRE-020..023, CACHE-006, CACHE-011..013.
    def handle_server_response(body, batch_fingerprints)
      needs = body["needsEnrichment"]
      if needs.is_a?(Array)
        needs.each { |key| @enrich_cache.invalidate(key) if key.is_a?(String) }
      end

      docs = body["docsUrl"]
      if docs.is_a?(String) && !docs.empty?
        # Origin only; strip trailing slashes so the server can be lax.
        @docs_mutex.synchronize { @docs_url = docs.sub(%r{/+\z}, "") }
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
        if fingerprint
          sanitized["errorFingerprint"] = {
            "strategy" => fingerprint.strategy,
            "key" => fingerprint.key,
            "reason" => fingerprint.reason
          }
        end
      end

      @uploader.push(sanitized)
      nil
    rescue StandardError => e
      # SAFETY-001. Nothing in here may reach customer handler code.
      Env.debug_log("record failed: #{e.class}: #{e.message}")
      nil
    end

    private

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
