# frozen_string_literal: true

require "json"
require "net/http"
require "time"
require "timeout"
require "uri"

require_relative "env"
require_relative "har"
require_relative "version"

module Restless
  # CONTRACT.md sections 8 (wire format) and 9 (batching). Never raises to
  # callers; failures surface only under the debug flag (SAFETY-004, SAFETY-008).
  class Uploader
    BATCH_SIZE = 10          # BATCH-001
    FLUSH_INTERVAL_MS = 5000 # BATCH-002
    MAX_QUEUE = 1000         # BATCH-004
    MAX_IN_FLIGHT = 4        # BATCH-009
    MAX_UPLOAD_ENTRIES = 100 # BATCH-010
    HTTP_TIMEOUT_S = 10      # WIRE-028
    MAX_RETRIES = 2          # WIRE-026
    RETRY_BASE_S = 1.0
    MAX_RETRY_DELAY_S = 10.0

    # Failures where the request never reached the ingest, so a resend cannot
    # duplicate (WIRE-026). SocketError is a DNS lookup failure.
    NOT_SENT_ERRORS = [Errno::ECONNREFUSED, SocketError].freeze

    attr_reader :base_url, :request_id_prefix

    # `sampling_hash` is the SAMPLE-040 hash stamped on every upload as
    # `x-restless-sampling` (SAMPLE-052); nil sends no header at all.
    def initialize(api_key:, base_url:, request_id_prefix: nil, on_response: nil,
                   sampling_hash: nil, transport: nil, sleeper: nil)
      @api_key = api_key.to_s
      @sampling_hash = sampling_hash
      @base_url = base_url.to_s
      @request_id_prefix = request_id_prefix
      @on_response = on_response
      # Test hooks: `transport.call(url, headers, body) -> [status, body, headers]`
      # and `sleeper.call(seconds)` in place of a real retry wait.
      @transport = transport
      @sleeper = sleeper

      reset_state

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

      reset_after_fork
      batches = @mutex.synchronize do
        if @queue.length >= MAX_QUEUE
          # Drop the OLDEST: the newest are what an operator is debugging.
          @queue.shift
          Env.debug_log("queue at #{MAX_QUEUE} -- dropping oldest captured request")
        end
        @queue << captured

        if flush_immediately?
          take_batches(true)
        elsif @queue.length >= BATCH_SIZE
          take_batches(false)
        else
          start_timer
          []
        end
      end

      start_workers(batches)
      nil
    rescue StandardError => e
      Env.debug_log("push failed: #{e.class}: #{e.message}")
      nil
    end

    # BATCH-005 to BATCH-007. Uploads everything queued, at most MAX_IN_FLIGHT
    # at a time, and returns once all of it has settled, retries included.
    def flush
      reset_after_fork
      @mutex.synchronize do
        cancel_timer
        @draining += 1
        begin
          loop do
            start_workers(take_batches(true))
            break if @queue.empty? && @active.zero?

            # Timed only as a guard against a worker that vanished without
            # releasing its slot; every real release broadcasts.
            @cond.wait(@mutex, 1.0)
          end
        ensure
          @draining -= 1
        end
      end
      join_reports
      nil
    rescue StandardError => e
      Env.debug_log("flush failed: #{e.class}: #{e.message}")
      nil
    end

    # SAMPLE-050, SAMPLE-051. POST the sampling report on a background thread,
    # then yield on that thread. Same gates as an upload; never raises or retries.
    def send_sampling_report_async(report, &on_done)
      reset_after_fork
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
      @mutex.synchronize do
        @reports.reject! { |t| !t.alive? }
        @reports << thread
      end
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

    def reset_state
      @pid = Process.pid
      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @queue = []
      @active = 0   # uploads holding a BATCH-009 slot, including retry waits
      @draining = 0 # flushes in progress, which let partial batches through
      @timer = nil
      @reports = []
    end

    # Puma and Unicorn fork after the app loads: the child inherits this state
    # but none of its threads, so it starts clean rather than count dead slots.
    def reset_after_fork
      reset_state unless @pid == Process.pid
    end

    # BATCH-003. Outside production, or against a localhost ingest, every push
    # flushes, keeping the dev loop and self-hosted setups low-latency.
    def flush_immediately?
      return true unless Env.production?
      return true if Env.localhost?(@base_url)

      false
    end

    # Caller holds @mutex. Claims a slot per batch; `partial` lets a batch
    # under BATCH_SIZE go (BATCH-010).
    def take_batches(partial)
      # BATCH-007. No key: drop everything, never retry or accumulate.
      unless api_key?
        Env.debug_log("no API key -- dropping batch of #{@queue.length}") unless @queue.empty?
        @queue.clear
        cancel_timer
        return []
      end

      batches = []
      while @active < MAX_IN_FLIGHT && !@queue.empty? && (partial || @queue.length >= BATCH_SIZE)
        batches << @queue.shift(MAX_UPLOAD_ENTRIES)
        @active += 1
      end
      cancel_timer if @queue.empty?
      batches
    end

    # Caller holds @mutex. The next batch for a worker whose upload just
    # finished, or nil when it should give its slot back.
    def next_batch
      return nil if @queue.empty? || !api_key?
      return nil unless flush_immediately? || @draining.positive? || @queue.length >= BATCH_SIZE

      batch = @queue.shift(MAX_UPLOAD_ENTRIES)
      cancel_timer if @queue.empty?
      batch
    end

    # Caller holds @mutex. A remainder under BATCH_SIZE waits for the timer.
    def release_slot
      @active -= 1
      start_timer unless @queue.empty?
      @cond.broadcast
    end

    # SAFETY-008. Uploads run on background threads, never the request thread.
    def start_workers(batches)
      batches.each do |batch|
        thread = Thread.new(batch) { |b| run_worker(b) }
        thread.abort_on_exception = false
        thread.report_on_exception = false
      end
    end

    # One slot. It keeps sending while a backlog is waiting, then frees itself.
    def run_worker(batch)
      holding = true
      while holding
        send_batch(batch)
        @mutex.synchronize do
          batch = next_batch
          holding = !batch.nil?
          release_slot unless holding
        end
      end
    ensure
      @mutex.synchronize { release_slot } if holding
    end

    # Caller holds @mutex.
    def start_timer
      return if @timer

      @timer = Thread.new do
        sleep(FLUSH_INTERVAL_MS / 1000.0)
        begin
          batches = @mutex.synchronize do
            @timer = nil
            take_batches(true)
          end
          start_workers(batches)
        rescue StandardError => e
          Env.debug_log("flush timer failed: #{e.class}: #{e.message}")
        end
      end
      @timer.abort_on_exception = false
    end

    # Caller holds @mutex.
    def cancel_timer
      timer = @timer
      @timer = nil
      timer.kill if timer && timer != Thread.current
    end

    def join_reports
      threads = @mutex.synchronize { @reports.dup }
      threads.each { |t| t.join(HTTP_TIMEOUT_S) }
      @mutex.synchronize { @reports.reject! { |t| !t.alive? } }
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

    # One upload, holding its slot through any retries. Only what the ingest
    # certainly did not store is resent (WIRE-024, WIRE-026, WIRE-027).
    def send_batch(batch)
      fingerprints = distinct_fingerprints(batch)
      # WIRE-004: a JSON ARRAY, even for a single capture.
      body = JSON.generate(batch.map { |captured| entry_for(captured) })
      url = "#{@base_url}/v1/request" # WIRE-001
      headers = {
        "Content-Type" => "application/json",           # WIRE-002
        "Authorization" => "Bearer #{@api_key}",        # WIRE-003
        "X-Restless-Spec-Version" => SPEC_VERSION,      # META-002
        "User-Agent" => "#{SDK_NAME}/#{VERSION}"
      }
      headers["x-restless-sampling"] = @sampling_hash if @sampling_hash # SAMPLE-052

      attempt = 0
      loop do
        Env.debug_log("uploading #{batch.length} entr#{batch.length == 1 ? 'y' : 'ies'} to #{url}" \
                      "#{attempt.positive? ? " (retry #{attempt})" : ''}")
        begin
          status, response_body, response_headers = send_request(url, headers, body)
        rescue *NOT_SENT_ERRORS => e
          raise unless attempt < MAX_RETRIES

          Env.debug_log("upload not sent (#{e.class}); retrying")
          pause(retry_delay(nil, attempt))
          attempt += 1
          next
        end

        if status.is_a?(Integer) && status >= 200 && status < 300
          handle_response(response_body, fingerprints)
          return
        end

        if [503, 429].include?(status) && attempt < MAX_RETRIES
          wait = retry_delay(header_value(response_headers, "retry-after"), attempt)
          Env.debug_log("upload refused (#{status}); retrying in #{(wait * 1000).round}ms")
          pause(wait)
          attempt += 1
          next
        end

        Env.debug_log("upload failed: #{status.inspect}")
        return
      end
    rescue StandardError => e
      # SAFETY-004. Timeouts and resets land here and are never retried.
      Env.debug_log("upload error: #{e.class}: #{e.message}")
      nil
    end

    # WIRE-026: the server's Retry-After (seconds or an HTTP date), else
    # jittered exponential backoff; either way capped.
    def retry_delay(retry_after, attempt)
      seconds = parse_retry_after(retry_after)
      if seconds.nil? || !seconds.finite? || seconds.negative?
        seconds = RETRY_BASE_S * (2**attempt) * (0.5 + rand)
      end
      [seconds, MAX_RETRY_DELAY_S].min
    end

    def parse_retry_after(value)
      text = value.to_s.strip
      return nil if text.empty?

      begin
        Float(text)
      rescue ArgumentError
        begin
          Time.httpdate(text) - Time.now
        rescue ArgumentError
          nil
        end
      end
    end

    def header_value(headers, name)
      return nil unless headers.respond_to?(:each_pair)

      headers.each_pair do |key, value|
        next unless key.to_s.casecmp(name).zero?

        return value.is_a?(Array) ? value.first : value
      end
      nil
    end

    def pause(seconds)
      return @sleeper.call(seconds) if @sleeper

      sleep(seconds) if seconds.positive?
    end

    def send_request(url, headers, body)
      return @transport.call(url, headers, body) if @transport

      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = HTTP_TIMEOUT_S
      http.read_timeout = HTTP_TIMEOUT_S
      http.write_timeout = HTTP_TIMEOUT_S if http.respond_to?(:write_timeout=)
      # Net::HTTP never resends a POST anyway; zero keeps WIRE-027 explicit.
      http.max_retries = 0 if http.respond_to?(:max_retries=)
      request = Net::HTTP::Post.new(uri.request_uri)
      headers.each { |k, v| request[k] = v }
      request.body = body
      # The per-operation timeouts above do not bound the whole exchange.
      response = Timeout.timeout(HTTP_TIMEOUT_S) { http.request(request) }
      [response.code.to_i, response.body, response.to_hash]
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
