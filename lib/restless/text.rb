# frozen_string_literal: true

module Restless
  # Shared text primitives: CONTRACT.md section 2.
  #
  # Everything in here exists because the obvious Ruby spelling silently
  # disagrees with the reference implementation. Read the comments before
  # replacing any of it with a one-liner.
  module Text
    # PRIM-002. The whitespace set, enumerated.
    #
    # Written as code points rather than literal characters because most of
    # them are invisible and several are indistinguishable from a plain space
    # in an editor. This is the JavaScript `\s` set. Ruby's `\s` is ASCII-only
    # and NARROWER (no NBSP, no Zs category, no LS/PS/ZWNBSP), so using it
    # would split an auth-scheme header at a different place and collapse a
    # different set of runs in `normalize_message`.
    WS_CODEPOINTS = [
      0x0009, # TAB
      0x000A, # LF
      0x000B, # VT
      0x000C, # FF
      0x000D, # CR
      0x0020, # SPACE
      0x00A0, # NBSP
      0x1680, # OGHAM SPACE MARK
      0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005,
      0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
      0x2028, # LINE SEPARATOR
      0x2029, # PARAGRAPH SEPARATOR
      0x202F, # NARROW NO-BREAK SPACE
      0x205F, # MEDIUM MATHEMATICAL SPACE
      0x3000, # IDEOGRAPHIC SPACE
      0xFEFF  # ZERO WIDTH NO-BREAK SPACE
      # Deliberately NOT U+180E, which left the Zs category in Unicode 6.3.
    ].freeze

    WS_CHARS = WS_CODEPOINTS.map { |cp| [cp].pack("U") }.freeze
    WS_SET = WS_CHARS.each_with_object({}) { |c, h| h[c] = true }.freeze

    # The same set as a regex character-class body, for interpolation.
    WS_CLASS = "\\u0009\\u000A\\u000B\\u000C\\u000D\\u0020" \
               "\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029" \
               "\\u202F\\u205F\\u3000\\uFEFF"

    # PRIM-001. WORD is exactly [A-Za-z0-9_]. Never `\w`: ASCII-only in Ruby
    # today, which happens to be right, but spelling it out is what keeps it
    # right.
    WORD_CLASS = "A-Za-z0-9_"

    REPLACEMENT_CHAR = [0xFFFD].pack("U")

    module_function

    # PRIM-010. Code points, not UTF-16 code units and not bytes.
    def code_points(str)
      str.chars
    end

    # PRIM-011. UTF-8 bytes.
    def utf8_length(str)
      to_utf8(str).bytesize
    end

    # PRIM-013 / SAFETY-001. Get a valid UTF-8 String out of anything,
    # without raising.
    #
    # Ruby cannot represent an unpaired surrogate at all (see PRIM-035 and
    # CONFORMANCE.md), so the surrogate substitution the contract describes is
    # structurally impossible here. What IS possible is a String tagged UTF-8
    # that holds invalid bytes -- Rack hands those out routinely -- so scrub.
    #
    # BINARY is DECODED, never transcoded. `IO#read(n)` always returns
    # ASCII-8BIT and the Rack spec requires `rack.input` to be opened in binary
    # mode, so every captured request body arrives here tagged BINARY. Ruby
    # transcodes BINARY to UTF-8 byte by byte and has no mapping for anything
    # above 0x7F, so `encode` turns each byte of a multi-byte character into a
    # separate U+FFFD: a body of `{"toKen":...}` with a U+212A KELVIN SIGN came
    # out as `{"to���en":...}`. That destroys every non-ASCII
    # body the SDK captures, and it is a redaction bypass on top of the fold
    # bug in Redact.normalize_name, because a mangled key no longer matches the
    # denylist. Bytes tagged BINARY are UTF-8 bytes; decode them like
    # `bytes_to_utf8` does, which is Node's `Buffer#toString("utf8")`.
    #
    # A String tagged with a REAL other encoding (ISO-8859-1 and friends) is
    # still transcoded, because there the tag is information rather than the
    # absence of one.
    def to_utf8(str)
      return "" if str.nil?

      s = str.is_a?(String) ? str : str.to_s
      if s.encoding == Encoding::UTF_8
        s.valid_encoding? ? s : s.scrub(REPLACEMENT_CHAR)
      elsif s.encoding == Encoding::ASCII_8BIT
        s.dup.force_encoding(Encoding::UTF_8).scrub(REPLACEMENT_CHAR)
      else
        s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace,
                                  replace: REPLACEMENT_CHAR)
      end
    rescue StandardError
      ""
    end

    # Decode raw bytes as UTF-8, replacing anything ill-formed with U+FFFD.
    #
    # Byte-for-byte identical to Node's `Buffer.from(bytes).toString("utf8")`,
    # including the maximal-subpart rule (a truncated 3-byte sequence yields
    # ONE U+FFFD, an overlong pair yields two). Verified differentially.
    def bytes_to_utf8(bytes)
      bytes.pack("C*").force_encoding(Encoding::UTF_8).scrub(REPLACEMENT_CHAR)
    end

    # PRIM-020. Unicode FULL, locale-independent lowercase mapping.
    #
    # `String#downcase` is exactly that, and the two traps the contract calls
    # out both come out right: U+0130 becomes `i` + U+0307 (two code points,
    # matching JavaScript and Python, unlike Go's SIMPLE mapping), and U+212A
    # KELVIN SIGN becomes a plain `k`. It is not `casefold`, and it applies no
    # locale tailoring unless one is asked for, so no Turkish dotless-i.
    #
    # This is the ONLY lowercase in the SDK. Section 4 name normalization used
    # to have its own ASCII-only fold for names; that fold was
    # a redaction bypass (see Redact.normalize_name) and is gone.
    #
    # What `String#downcase` does not do is the Final_Sigma contextual rule
    # that `String.prototype.toLowerCase` applies: a word-final capital sigma
    # lowercases to U+03C2 in the reference and to U+03C3 here. PRIM-021
    # records that as a real difference between the languages and explicitly
    # does NOT require it, because nothing in this contract can observe it.
    # Greek is outside WORD, so FP-020 step 6 replaces both sigma forms with a
    # space before either can reach a token (`"ΑΣ failed"` and `"ΑΣΑ failed"`
    # both normalize to `failed` either way), and the REDACT-010 denylists are
    # ASCII. A hand-rolled \p{Cased} / \p{Case_Ignorable} implementation used
    # to live here; it was removed rather than carried as code no vector,
    # fuzzer or caller can distinguish from this one-liner.
    def full_lower(str)
      str.downcase
    end

    def ws?(char)
      WS_SET.key?(char)
    end

    # `String.prototype.trim` semantics: strip exactly the PRIM-002 set.
    #
    # Ruby's `String#strip` removes ASCII whitespace plus NUL and leaves NBSP
    # and friends in place, which is a different set in both directions.
    def ws_trim(str)
      chars = str.chars
      first = 0
      first += 1 while first < chars.length && ws?(chars[first])
      last = chars.length - 1
      last -= 1 while last >= first && ws?(chars[last])
      return "" if last < first

      chars[first..last].join
    end

    # PRIM-040. `YYYY-MM-DDTHH:MM:SS.sssZ`, exactly three fractional digits
    # and a literal Z.
    #
    # Hand-built: `Time#iso8601` needs `require "time"` plus an explicit digit
    # count, and emits `+00:00` rather than `Z` unless the receiver is already
    # UTC. The ingest parses this field permissively and silently falls back to
    # server time when it cannot, so a wrong format loses real request timing
    # with no error anywhere in the system.
    def iso8601_millis(time)
      time.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
    end
  end
end
