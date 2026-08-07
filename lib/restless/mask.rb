# frozen_string_literal: true

require "digest"
require "base64"

require_relative "text"

module Restless
  # CONTRACT.md section 3. The masked end-user API key.
  #
  #     sha512-<base64(sha512(utf8(key)))>?<last4>
  #
  # This is the lookup key the ingest and the dashboard index on, so it has to
  # be byte-identical across every SDK and the server. Server-side reference:
  # `logs/src/clickhouse/models/request.ts`.
  module Mask
    # MASK-011. Setup-time placeholders the CLI (or a copy-pasted doc) leaves
    # in curl examples. Hashing them would cluster unrelated requests under an
    # arbitrary tail. Compared case-sensitively and exactly.
    PLACEHOLDER_KEYS = %w[
      API_KEY_HERE
      YOUR_API_KEY
      YOUR_KEY
      REPLACE_ME
    ].freeze

    # MASK-013. Redaction may run before masking in some call paths; hashing a
    # sentinel produces a meaningless key.
    #
    # `\A...\z` rather than `^...$`: PRIM-005. Ruby's `$` also matches before a
    # trailing newline, so `"<REDACTED:5>\n"` would pass through unmasked here
    # and be hashed in JavaScript.
    REDACTED_RE = /\A<REDACTED:[0-9]+(?::[^>]*)?>\z/.freeze

    module_function

    # MASK-001. Returns nil for "no key" (MASK-010).
    def mask(api_key)
      return nil if api_key.nil? || api_key == ""
      return nil if PLACEHOLDER_KEYS.include?(api_key)

      # MASK-012. Idempotent for its own output.
      return api_key if api_key.start_with?("sha512-")
      return api_key if REDACTED_RE.match?(api_key)

      # MASK-004: hash the UTF-8 encoding. MASK-002: SHA-512.
      # MASK-003: STANDARD base64 with padding, not base64url.
      digest = Base64.strict_encode64(Digest::SHA512.digest(Text.to_utf8(api_key)))

      # MASK-006: last 4 CODE POINTS of the plaintext, never a byte or
      # UTF-16 code-unit slice. Keys shorter than 4 contribute all of theirs.
      last4 = api_key.chars.last(4).join

      "sha512-#{digest}?#{last4}"
    end
  end
end
