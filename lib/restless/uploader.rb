# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

require_relative "env"
require_relative "har"
require_relative "version"

module Restless
  # CONTRACT.md sections 8 (wire format) and 9 (batching).
  #
  # Never raises to callers. Upload failures go to stderr under the debug flag
  # and are otherwise swallowed: observability must not break the request path
  # (SAFETY-004, SAFETY-008).
  class Uploader
    BATCH_SIZE = 10          # BATCH-001
    FLUSH_INTERVAL_MS = 5000 # BATCH-002
    MAX_QUEUE = 1000         # BATCH-004
    HTTP_TIMEOUT_S = 10

    attr_reader :base_url, :request_id_prefix

    # `sampling_hash` is the SAMPLE-040 hash of a non-default sampling config,
    # stamped on every upload as `x-restless-sampling` (SAMPLE-052). Nil when
    # sampling is not configured, and then no header is sent at all.
    def initialize(api_key:, base_url:, request_id_prefix: nil, on_response: nil,
                   sampling_hash: nil, transport: nil)
      @api_key = api_key.to_s
      @sampling_hash = sampling_hash
      @base_url = base_url.to_s
      @request_id_prefix = request_id_prefix
      @on_response = on_response
      # Test hook. Anything responding to
      # `call(url, headers, body) -> [status, body]`.
      @transport = transport

      @queue = []
      @mutex = Mutex.new
      @timer = nil
      @inflight = []

      warn_if_insecure
    end

    def api_key?
      !@api_key.empty?
    end

    # WIRE-006. The project key and every captured header would otherwise ship
    # in the clear with no signal anywhere.
    def warn_if_insecure
      uri = URI.parse(@base_url)
      return unless uri.scheme == "http"
      return if %w[localhost 127.0.0.1].include?(uri.host)

      warn("[restless-sdk] RESTLESS_BASE_URL=#{@base_url} is plain HTTP -- your API " \
           "key and every captured header will be transmitted unencrypted. " \
           "Use https:// or localhost.")
    rescue StandardError
      nil
    end

    def push(captured)
      # BATCH-008.
      return if Env.test_run? && !Env.setup_mode?

      batch = nil
      @mutex.synchronize do
        if @queue.length >= MAX_QUEUE
          # Drop the OLDEST. The newest entries are the ones an operator is
          # actively debugging.
          @queue.shift
          Env.debug_log("queue at #{MAX_QUEUE} -- dropping oldest captured request")
        end
        @queue << captured

        if flush_immediately? || @queue.length >= BATCH_SIZE
          batch = take_batch
        else
          start_timer
        end
      end

      upload_async(batch) if batch
      nil
    end

    # BATCH-005, BATCH-006, BATCH-007. Synchronous: resolves when the attempt
    # completes.
    def flush
      batch = @mutex.synchronize { take_batch }
      upload(batch) unless batch.nil? || batch.empty?
      join_inflight
      nil
    end

    # SAMPLE-050, SAMPLE-051. POST the sampling report on a background
    # thread, then yield (on that thread) however it went. Same gates as an
    # upload: nothing under a test runner or without a project key. Never
    # raises, never retries.
    def send_sampling_report_async(report, &on_done)
      thread = Thread.new do
        begin
          send_sampling_report(report)
        ensure
          begin
            on_done.call if on_done
          rescue StandardError => e
            Env.debug_log("sampling report callback failed: #{e.class}: #{e.message}")
          end
        end
      end
      thread.abort_on_exception = false
      track(thread)
      nil
    end

    def options
      {
        base_url: @base_url,
        request_id_prefix: @request_id_prefix,
        has_api_key: api_key?
      }
    end

    private

    # BATCH-003. Flush every push when the app is not in production, or when
    # the ingest is on localhost. Both keep the customer dev loop and
    # self-hosted setups low-latency.
    def flush_immediately?
      return true unless Env.production?
      return true if Env.localhost?(@base_url)

      false
    end

    # Caller holds @mutex.
    def take_batch
      cancel_timer
      return nil if @queue.empty?

      batch = @queue
      @queue = []
      batch
    end

    # Caller holds @mutex.
    def start_timer
      return if @timer

      @timer = Thread.new do
        sleep(FLUSH_INTERVAL_MS / 1000.0)
        begin
          batch = @mutex.synchronize do
            @timer = nil
            @queue.empty? ? nil : take_batch_unsafe
          end
          upload(batch) if batch
        rescue StandardError => e
          Env.debug_log("flush timer failed: #{e.class}: #{e.message}")
        end
      end
      @timer.abort_on_exception = false
    end

    # Like take_batch but without cancelling the timer, which the timer thread
    # has already cleared.
    def take_batch_unsafe
      batch = @queue
      @queue = []
      batch
    end

    # Caller holds @mutex.
    def cancel_timer
      timer = @timer
      @timer = nil
      timer.kill if timer && timer != Thread.current
    end

    # SAFETY-008. The capture path performs no blocking I/O; uploads are
    # asynchronous and fire-and-forget.
    def upload_async(batch)
      thread = Thread.new { upload(batch) }
      thread.abort_on_exception = false
      track(thread)
    end

    # `flush` joins these, so it also waits for an in-flight sampling report.
    def track(thread)
      @mutex.synchronize do
        @inflight.reject! { |t| !t.alive? }
        @inflight << thread
      end
    end

    def send_sampling_report(report)
      return if Env.test_run? && !Env.setup_mode?
      return unless api_key?

      url = "#{@base_url}/v1/sampling"
      headers = {
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{@api_key}",
        "X-Restless-Spec-Version" => SPEC_VERSION,
        "User-Agent" => "#{SDK_NAME}/#{VERSION}"
      }
      status, = send_request(url, headers, JSON.generate(report))
      Env.debug_log("sampling report: #{status.inspect}")
    rescue StandardError => e
      # SAFETY-004.
      Env.debug_log("sampling report error: #{e.class}: #{e.message}")
      nil
    end

    def join_inflight
      threads = @mutex.synchronize { @inflight.dup }
      threads.each { |t| t.join(HTTP_TIMEOUT_S) }
      @mutex.synchronize { @inflight.reject! { |t| !t.alive? } }
    end

    def upload(batch)
      return if batch.nil? || batch.empty?

      # BATCH-007. No key: drop the batch, never retry or accumulate.
      unless api_key?
        Env.debug_log("no API key -- dropping batch of #{batch.length}")
        return
      end

      fingerprints = distinct_fingerprints(batch)
      payload = batch.map { |captured| entry_for(captured) }
      url = "#{@base_url}/v1/request" # WIRE-001

      Env.debug_log("uploading #{batch.length} entr#{batch.length == 1 ? 'y' : 'ies'} to #{url}")

      headers = {
        "Content-Type" => "application/json",           # WIRE-002
        "Authorization" => "Bearer #{@api_key}",        # WIRE-003
        "X-Restless-Spec-Version" => SPEC_VERSION,      # META-002
        "User-Agent" => "#{SDK_NAME}/#{VERSION}"
      }
      headers["x-restless-sampling"] = @sampling_hash if @sampling_hash # SAMPLE-052

      # WIRE-004: a JSON ARRAY, even for a single capture.
      status, body = send_request(url, headers, JSON.generate(payload))

      # WIRE-024: a non-2xx is never retried and never raises. The batch is
      # dropped.
      unless status && status >= 200 && status < 300
        Env.debug_log("upload failed: #{status.inspect}")
        return
      end

      handle_response(body, fingerprints)
    rescue StandardError => e
      # SAFETY-004.
      Env.debug_log("upload error: #{e.class}: #{e.message}")
      nil
    end

    def send_request(url, headers, body)
      return @transport.call(url, headers, body) if @transport

      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = HTTP_TIMEOUT_S
      http.read_timeout = HTTP_TIMEOUT_S
      request = Net::HTTP::Post.new(uri.request_uri)
      headers.each { |k, v| request[k] = v }
      request.body = body
      response = http.request(request)
      [response.code.to_i, response.body]
    end

    # WIRE-020..023.
    def handle_response(raw_body, batch_fingerprints)
      return if @on_response.nil?

      parsed = begin
        JSON.parse(raw_body.to_s)
      rescue StandardError
        # WIRE-020: a non-JSON or unparseable body is ignored without error.
        nil
      end
      return unless parsed.is_a?(Hash)

      @on_response.call(parsed, batch_fingerprints)
    end

    # CACHE-012 feeds off this: every distinct fingerprint key in the batch.
    def distinct_fingerprints(batch)
      seen = {}
      out = []
      batch.each do |captured|
        fingerprint = captured["errorFingerprint"]
        next unless fingerprint.is_a?(Hash)

        key = fingerprint["key"]
        next if !key.is_a?(String) || key.empty? || seen[key]

        seen[key] = true
        out << key
      end
      out
    end

    # WIRE-010..019.
    def entry_for(captured)
      har = Har.to_har_entry(captured)
      user = captured["user"] || {}
      owner = user["owner"] || {}
      owner_id = owner["id"]
      masked_key = user["apiKey"]

      # WIRE-013: `emails` is always an ARRAY. A single-string `email` from
      # enrichment is wrapped; an absent one becomes [].
      raw_email = owner["email"]
      emails = if raw_email.is_a?(Array)
                 raw_email
               elsif raw_email.nil? || raw_email == ""
                 []
               else
                 [raw_email]
               end

      entry = {
        # WIRE-011: the RAW uuid, with no display prefix applied.
        "_id" => captured["requestId"]
      }
      entry["routePattern"] = captured["routePattern"] if captured["routePattern"]
      # WIRE-017: absent for successful responses.
      entry["errorFingerprint"] = captured["errorFingerprint"] if captured["errorFingerprint"]
      # WIRE-030: present, and true, only on a stub. Never `false`.
      entry["sampled"] = true if captured["sampled"]
      # WIRE-012: owner id, else the masked end-user key, else "anonymous".
      entry["group"] = {
        "id" => (owner_id && !owner_id.empty? ? owner_id : nil) || masked_key || "anonymous",
        "label" => owner["label"] || "",
        "emails" => emails
      }
      # WIRE-014: the individual caller, indexed independently of the group.
      entry["apiKey"] = masked_key if masked_key
      # WIRE-015/WIRE-019: the wire name is `projectId`, the user-facing name
      # is `owner`. The mismatch is deliberate and coupled to the ingest's
      # storage schema.
      entry["projectId"] = owner_id if owner_id

      # SETUP-005: unknown top-level fields on the setup result ride along.
      (user["extra"] || {}).each do |key, value|
        entry[key] = value unless entry.key?(key)
      end

      # WIRE-018: reserved constants.
      entry["clientIPAddress"] = "127.0.0.1"
      entry["development"] = false
      entry["request"] = {
        "log" => {
          "version" => "1.2",
          "creator" => { "name" => SDK_NAME, "version" => VERSION }, # WIRE-016
          "entries" => [har]
        }
      }
      entry
    end
  end
end
