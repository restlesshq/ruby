# frozen_string_literal: true

module Restless
  # Identity of this SDK, and the contract version it implements.
  #
  # META-001: the spec version an SDK implements must be recorded in a
  # machine-readable form alongside its conformance level.

  VERSION = "0.1.0"

  # WIRE-016: distinct per implementation, so the ingest can attribute a
  # payload to a language.
  SDK_NAME = "restless-sdk-ruby"

  # The spec/CONTRACT.md version this SDK is verified against.
  #
  # REDACT-010 requires full Unicode name folding
  # to require full Unicode lowercase. Keep this in step with
  # spec/VECTORS_VERSION.
  SPEC_VERSION = "1.0.1"

  # CONTRACT.md 1.1: L1 is the pure functions, L2 adds batching, caches,
  # injection and the safety guarantees.
  CONFORMANCE_LEVEL = "L2"
end
