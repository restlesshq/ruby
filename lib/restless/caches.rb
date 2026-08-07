# frozen_string_literal: true

module Restless
  # CONTRACT.md section 11.
  #
  # Both caches are Mutex-guarded. Puma, Falcon and Unicorn-with-threads all
  # serve requests on many threads at once, so an unsynchronized Hash here is a
  # real data race rather than a theoretical one.

  # CACHE-001..007. Enriched owner metadata, keyed by owner id (or the masked
  # end-user key when there is no id).
  #
  # The point is that `enrich` runs once per key per TTL window rather than
  # once per request, AND that the enriched VALUE is stored -- not merely a
  # freshness flag. Every upload has to carry owner metadata, including the
  # ones that skipped the callback, because the ingest cannot backfill: without
  # it every request after the first lands in the dashboard as unauthenticated.
  class EnrichCache
    DEFAULT_TTL_MS = 3_600_000 # CACHE-004: 1 hour

    def initialize(ttl_ms = DEFAULT_TTL_MS)
      @ttl_ms = ttl_ms
      @entries = {}
      @mutex = Mutex.new
    end

    def get(key)
      @mutex.synchronize do
        entry = @entries[key]
        next nil if entry.nil?

        if now_ms - entry[:ts] > @ttl_ms # CACHE-015
          @entries.delete(key)
          next nil
        end
        entry[:value]
      end
    end

    def set(key, value)
      @mutex.synchronize { @entries[key] = { value: value, ts: now_ms } }
      value
    end

    # CACHE-006. Server-driven, via `needsEnrichment` on an upload response.
    def invalidate(key)
      @mutex.synchronize { @entries.delete(key) }
    end

    def clear
      @mutex.synchronize { @entries.clear }
    end

    def size
      @mutex.synchronize { @entries.size }
    end

    private

    def now_ms
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
    end
  end

  # CACHE-010..015. Agent Recovery messages keyed by error fingerprint.
  #
  # Performance is the whole point. The lookup sits on the hot path of every
  # 4xx/5xx, so it is synchronous, in-process and never does I/O. A cold miss
  # injects nothing and returns immediately; the server piggybacks the message
  # onto the next upload response, so the SECOND occurrence hits.
  #
  # "No message for this fingerprint" is itself a cacheable answer, stored as
  # nil, so a cold miss does not stay cold on every request. The negative TTL
  # is shorter so a freshly-attached dashboard message starts working within
  # minutes.
  class RecoveryCache
    DEFAULT_TTL_MS = 3_600_000 # CACHE-014: 1 hour, positive
    DEFAULT_NEGATIVE_TTL_MS = 300_000 # CACHE-014: 5 minutes, negative

    # Distinguishes "cached as absent" (nil) from "never seen" (MISS).
    MISS = Object.new.freeze

    def initialize(ttl_ms = DEFAULT_TTL_MS, negative_ttl_ms = DEFAULT_NEGATIVE_TTL_MS)
      @ttl_ms = ttl_ms
      @negative_ttl_ms = negative_ttl_ms
      @entries = {}
      @mutex = Mutex.new
    end

    # Returns a String (inject it), nil (the server confirmed there is none),
    # or MISS (never seen, or expired).
    def get(key)
      @mutex.synchronize do
        entry = @entries[key]
        next MISS if entry.nil?

        ttl = entry[:message].nil? ? @negative_ttl_ms : @ttl_ms
        if now_ms - entry[:ts] > ttl # CACHE-015
          @entries.delete(key)
          next MISS
        end
        entry[:message]
      end
    end

    # Convenience for the hot path: the message to inject, or nil.
    def lookup(key)
      value = get(key)
      value.is_a?(String) ? value : nil
    end

    def set(key, message)
      @mutex.synchronize { @entries[key] = { message: message, ts: now_ms } }
    end

    # CACHE-013. A negative entry must never overwrite a positive one.
    def set_negative_unless_present(key)
      @mutex.synchronize do
        entry = @entries[key]
        if entry
          ttl = entry[:message].nil? ? @negative_ttl_ms : @ttl_ms
          fresh = now_ms - entry[:ts] <= ttl
          next if fresh && !entry[:message].nil?
        end
        @entries[key] = { message: nil, ts: now_ms }
      end
    end

    def invalidate(key)
      @mutex.synchronize { @entries.delete(key) }
    end

    def clear
      @mutex.synchronize { @entries.clear }
    end

    def size
      @mutex.synchronize { @entries.size }
    end

    private

    def now_ms
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
    end
  end
end
