# frozen_string_literal: true

require "json"
require "set"

require_relative "text"

module Restless
  # CONTRACT.md section 4. Redaction for sensitive values in captured
  # requests. Runs at the single choke point before anything enters the
  # upload queue; no adapter may bypass it.
  #
  # Format: `<REDACTED:<length>[:<last4>]>`
  module Redact
    TAIL_MIN_LENGTH = 8
    TAIL_CHARS = 4

    # REDACT-011. Matched after REDACT-010 normalization.
    DEFAULT_HEADER_DENYLIST = %w[
      authorization
      cookie
      set-cookie
      proxy-authorization
      x-api-key
      x-auth-token
    ].freeze

    # REDACT-012.
    DEFAULT_BODY_KEY_DENYLIST = %w[
      password
      pass
      pwd
      token
      secret
      apikey
      accesstoken
      refreshtoken
      idtoken
      sessionid
      ssn
      creditcard
      ccnumber
      cvv
      cvc
    ].freeze

    # REDACT-013. Query params use the same list as body keys.
    DEFAULT_QUERY_PARAM_DENYLIST = DEFAULT_BODY_KEY_DENYLIST

    # REDACT-016. Headers that carry an HTTP auth-scheme prefix. For these the
    # scheme word survives, so a debugger reading the dashboard can see at a
    # glance whether the caller used Bearer, Basic or something custom.
    SCHEME_PREFIX_HEADERS = Set.new(%w[authorization proxyauthorization]).freeze

    # REDACT-030. 256 KiB, measured in UTF-8 bytes.
    MAX_BODY_BYTES = 262_144

    # PRIM-006. Hex digits are validated explicitly rather than handed to
    # `String#to_i(16)`, which silently returns 0 for garbage.
    HEX_PAIR_RE = /\A[0-9a-fA-F]{2}\z/.freeze

    # REDACT-028. The RFC 3986 unreserved set, spelled out. No two languages'
    # builtins agree: `encodeURIComponent` also leaves `!'()*` alone, Ruby's
    # `CGI.escape` turns a space into `+` and escapes `~`, and Go's differs
    # from both.
    UNRESERVED_BYTES = begin
      set = Array.new(256, false)
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        .each_byte { |b| set[b] = true }
      set.freeze
    end

    module_function

    # REDACT-001, REDACT-002. Length and tail are counted in CODE POINTS.
    #
    # An emoji is 1 code point, 2 UTF-16 code units and 4 UTF-8 bytes; a
    # sentinel built from any other unit disagrees with every other SDK for
    # the same secret, and a byte-wise tail slice produces an ill-formed
    # string.
    def redact_value(value)
      points = value.chars
      len = points.length
      return "<REDACTED:#{len}>" if len < TAIL_MIN_LENGTH

      "<REDACTED:#{len}:#{points.last(TAIL_CHARS).join}>"
    end

    # REDACT-010. Lowercase (PRIM-020, FULL Unicode) and drop every `-` and
    # `_`, so `api_key`, `apiKey`, `API-KEY` and `APIKEY` all match `apikey`.
    #
    # Full Unicode, and that is a SECURITY requirement rather than a cosmetic
    # one. This function is what decides whether a value gets redacted, so the
    # safe direction is to fold MORE aggressively, never less. A header named
    # `x-api-Key` or a body key `toKen` whose `K` is U+212A KELVIN SIGN
    # full-lowercases to `x-api-key` / `token` -- both denylisted -- and the
    # reference redacts them.
    #
    # An ASCII-only fold leaves the KELVIN spelling unmatched and ships the
    # plaintext secret to the dashboard. Do not reintroduce it, and do not
    # substitute `casefold`-style folding either (PRIM-020).
    def normalize_name(name)
      Text.full_lower(name).delete("-_")
    end

    def build_deny_set(defaults, extra)
      # REDACT-014: defaults are ALWAYS applied. Configuration extends the
      # lists; it can never shrink or replace them.
      Set.new((defaults + Array(extra)).map { |n| normalize_name(n.to_s) })
    end

    # REDACT-016. Split `Bearer <credential>` into its three parts, or nil
    # when there is no scheme prefix to preserve.
    #
    # An explicit scan over CODE POINTS, never a regex. The obvious pattern
    # `^(\S+)(\s+)(\S.*)$` is unportable and fails silently: JavaScript's `.`
    # excludes CR/LS/PS so a credential containing a stray CR falls through to
    # whole-value redaction, while a Ruby or Python `.` with DOTALL matches
    # and preserves the scheme. Same header, same input, two captured values.
    def split_auth_scheme(value)
      chars = value.chars
      i = 0
      i += 1 while i < chars.length && !Text.ws?(chars[i])
      # No whitespace at all, or the value starts with it: nothing to keep.
      return nil if i.zero? || i >= chars.length

      j = i
      j += 1 while j < chars.length && Text.ws?(chars[j])
      return nil if j >= chars.length # whitespace but no credential after it

      {
        scheme: chars[0, i].join,
        gap: chars[i, j - i].join,
        credential: chars[j..-1].join
      }
    end

    # REDACT-018, REDACT-019. Returns a NEW hash; never mutates the caller's.
    def redact_headers(headers, extra = [])
      deny = build_deny_set(DEFAULT_HEADER_DENYLIST, extra)
      out = {}
      headers.each do |key, value|
        norm = normalize_name(key.to_s)
        unless deny.include?(norm)
          out[key] = value
          next
        end

        if SCHEME_PREFIX_HEADERS.include?(norm)
          split = split_auth_scheme(value.to_s)
          if split
            out[key] = "#{split[:scheme]}#{split[:gap]}" \
                       "#{redact_value(split[:credential])}"
            next
          end
        end

        out[key] = redact_value(value.to_s)
      end
      out
    end

    # REDACT-028.
    def percent_encode(value)
      out = +""
      Text.to_utf8(value).each_byte do |b|
        out << (UNRESERVED_BYTES[b] ? b.chr : format("%%%02X", b))
      end
      out
    end

    # REDACT-029. `+` is a space, `%XX` is a byte, a `%` not followed by two
    # hex digits is literal, and invalid UTF-8 in the decoded bytes becomes
    # U+FFFD instead of raising.
    #
    # Iterates CODE POINTS. Node's original indexed UTF-16 code units, walked
    # into the middle of an astral character and handed each surrogate half to
    # the encoder separately, turning one emoji into two U+FFFD -- so the
    # sentinel reported the wrong length.
    def percent_decode(value)
      bytes = []
      chars = value.chars
      i = 0
      len = chars.length
      while i < len
        ch = chars[i]
        if ch == "+"
          bytes << 0x20
          i += 1
          next
        end
        if ch == "%"
          pair = chars[i + 1, 2]
          if pair && pair.length == 2
            hex = pair.join
            if HEX_PAIR_RE.match?(hex)
              bytes << hex.to_i(16)
              i += 3
              next
            end
          end
        end
        Text.to_utf8(ch).each_byte { |b| bytes << b }
        i += 1
      end
      Text.bytes_to_utf8(bytes)
    end

    # REDACT-025..027. Rewrite denylisted query values IN PLACE.
    #
    # Scheme, host, port, path, parameter order, separators and fragment come
    # through byte for byte; only the matched values change. Parsing and
    # re-serializing through a URL library is wrong twice over: it loses
    # repeated parameters (`?token=a&token=b` collapses to one) and it applies
    # WHATWG normalization no other language reproduces.
    def redact_url(url, extra = [])
      deny = build_deny_set(DEFAULT_QUERY_PARAM_DENYLIST, extra)

      q = url.index("?")
      return url if q.nil?

      head = url[0, q + 1]
      rest = url[(q + 1)..-1] || ""

      hash = rest.index("#")
      query = hash.nil? ? rest : rest[0, hash]
      tail  = hash.nil? ? "" : rest[hash..-1]
      return url if query.empty?

      # `split("&", -1)`: without the negative limit Ruby drops trailing empty
      # fields, so `?a=1&` would come back as `?a=1`.
      parts = query.split("&", -1).map do |pair|
        eq = pair.index("=")
        next pair if eq.nil?

        raw_key = pair[0, eq]
        raw_val = pair[(eq + 1)..-1] || ""
        next pair unless deny.include?(normalize_name(percent_decode(raw_key)))

        "#{raw_key}=#{percent_encode(redact_value(percent_decode(raw_val)))}"
      end

      head + parts.join("&") + tail
    end

    # REDACT-022. Recursively redact denylisted keys in a parsed JSON value.
    def redact_json_value(val, deny)
      return val if val.nil?
      return val.map { |v| redact_json_value(v, deny) } if val.is_a?(Array)

      if val.is_a?(Hash)
        out = {}
        val.each do |k, v|
          if deny.include?(normalize_name(k.to_s))
            # REDACT-004: a non-string value becomes the bare `<REDACTED>`;
            # null is left alone (there is nothing to leak, and nulling it out
            # would lose schema information).
            out[k] = if v.nil?
                       nil
                     elsif v.is_a?(String)
                       redact_value(v)
                     else
                       "<REDACTED>"
                     end
          else
            out[k] = redact_json_value(v, deny)
          end
        end
        return out
      end

      val
    end

    # REDACT-021. Walk the PARSED value rather than pattern-matching the raw
    # text, so every SDK reaches the same verdict with its own JSON parser and
    # there is no regex dialect or escape decoding to get wrong.
    def contains_denied_key?(val, deny)
      return false if val.nil?
      return val.any? { |v| contains_denied_key?(v, deny) } if val.is_a?(Array)

      if val.is_a?(Hash)
        val.each do |k, v|
          return true if deny.include?(normalize_name(k.to_s))
          return true if contains_denied_key?(v, deny)
        end
      end

      false
    end

    # REDACT-020..024.
    #
    # When the body contains NOTHING to redact, the caller's original string
    # is returned BYTE FOR BYTE rather than a re-serialized copy. That is a
    # fidelity requirement, not an optimization: a parse/serialize round trip
    # is lossy in every language, differently, and re-serialization is exactly
    # where SDKs disagree.
    def redact_body(body, content_type, extra = [])
      return body if body.nil? || body.empty?
      # REDACT-023: case-insensitive substring match on the content type.
      return body unless Text.full_lower(content_type.to_s).include?("application/json")

      begin
        # max_nesting: false because the reference parser has no depth limit;
        # a 200-deep body must not silently take a different branch here.
        parsed = JSON.parse(body, max_nesting: false)
      rescue StandardError
        # REDACT-024: a body that does not parse passes through unchanged.
        return body
      end

      deny = build_deny_set(DEFAULT_BODY_KEY_DENYLIST, extra)
      return body unless contains_denied_key?(parsed, deny)

      # PRIM-030 (compact), PRIM-031 (insertion order), PRIM-032 (literal
      # UTF-8). Ruby's JSON encoder does all three by default.
      JSON.generate(redact_json_value(parsed, deny))
    rescue StandardError
      body
    end

    # REDACT-030..032. The cut is made at the byte limit and then backed off
    # to the nearest character boundary, so the kept prefix is always a
    # complete sequence of Unicode scalar values.
    def truncate_body(body, max_bytes)
      return body if body.nil? || body.empty?

      buf = Text.to_utf8(body).dup.force_encoding(Encoding::ASCII_8BIT)
      total = buf.bytesize
      return body if total <= max_bytes

      cut = max_bytes
      cut = 0 if cut.negative?
      # Walk back off any UTF-8 continuation byte (0b10xxxxxx).
      cut -= 1 while cut.positive? && (buf.getbyte(cut) & 0xC0) == 0x80

      kept = buf.byteslice(0, cut).force_encoding(Encoding::UTF_8)
      "#{kept}\n[...TRUNCATED: original #{total} bytes]"
    end
  end
end
