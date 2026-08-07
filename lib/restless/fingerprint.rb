# frozen_string_literal: true

require_relative "text"

module Restless
  # CONTRACT.md section 5. A stable identifier for an HTTP error response,
  # computed at capture time and shipped with the log.
  #
  # The ingest stores it, the dashboard groups by it, a customer attaches a
  # recovery message to a group, and the SDK injects that message into
  # matching responses. Nothing re-derives it, so every SDK must agree.
  module Fingerprint
    # FP-016. Checked in this order, matched EXACTLY (case-sensitively, no
    # REDACT-010 normalization).
    CODE_FIELDS = %w[code error_code errorCode type].freeze
    NESTED_PATHS = [
      %w[error code],
      %w[error type],
      %w[error error_code]
    ].freeze

    # FP-015. 1 to 64 code points, identifier-shaped. Keeps `card_declined`
    # and `AUTH_MISMATCH`, rejects `Your card was declined.` and bare UUIDs.
    #
    # `\A...\z` rather than `^...$` (PRIM-005): Ruby's `$` also matches before
    # a trailing newline, so `"boom\n"` would look like a code here and not in
    # JavaScript.
    CODE_RE = /\A[a-zA-Z][a-zA-Z0-9_.\-]*\z/.freeze

    # FP-030. A single path segment that collapses to `:id`. Each pattern is
    # fully anchored, so this is a whole-segment test rather than a scan.
    #
    # The hex ranges are written out rather than using the `i` flag: Ruby's
    # case-insensitive matching is Unicode case folding, which is a wider
    # relation than the ASCII-only canonicalization a non-`u` JavaScript regex
    # performs.
    SEG_UUID = /\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/.freeze
    SEG_NUMERIC = /\A[0-9]+\z/.freeze
    SEG_LONG_HEX = /\A[0-9a-fA-F]{16,}\z/.freeze

    # FP-042. Project-directory markers.
    PROJECT_DIRS = %w[src lib app api routes controllers handlers].freeze

    # FP-020. The classes are enumerated (PRIM-001, PRIM-002) rather than
    # spelled `\w` / `\s`, because those mean different things in different
    # engines and this key has to be byte-identical in every SDK.
    WS = Text::WS_CLASS
    WORD = Text::WORD_CLASS

    RE_URL      = Regexp.new("https?://[^#{WS}]+").freeze
    RE_EMAIL    = Regexp.new("[^#{WS}]+@[^#{WS}]+\\.[^#{WS}]+").freeze
    RE_QUOTED   = /['"`][^'"`]*['"`]/.freeze
    RE_PUNCT    = Regexp.new("[^#{WORD}#{WS}\\-]").freeze
    RE_WS_RUN   = Regexp.new("[#{WS}]+").freeze

    # FP-020 step 5, and the one regex in this file that cannot be written
    # against a UTF-8 string.
    #
    # Ruby's `\w` is ASCII-only (correct here) but its `\b` is NOT: Onigmo
    # defines the boundary against the Unicode word property, so `"eA1"` with
    # a leading accented letter has no boundary before the `A` and the whole
    # digit-word survives, where JavaScript, Go and Python-with-re.ASCII all
    # strip it. Applying the match to the UTF-8 BYTES restores JavaScript's
    # semantics exactly: every non-ASCII character becomes a run of non-word
    # bytes, which is what a non-`u` JS regex sees in UTF-16 too. The pattern
    # can only ever match ASCII bytes, so byte slicing and character slicing
    # coincide and the result is still well-formed UTF-8.
    RE_DIGIT_WORD = Regexp.new("\\b[#{WORD}\\-]*[0-9][#{WORD}\\-]*\\b").freeze

    Result = Struct.new(:strategy, :key, :reason)

    module_function

    # FP-010. Strategies are tried in this exact order; the first that yields
    # a key wins.
    #
    # `stack_frame` is the already-extracted `{file:, fn:}` for the frame
    # nearest the throw site (FP-043). Frame PARSING is per-language
    # (FP-044) and lives in `Restless::StackFrames`, so this function stays
    # dialect-free.
    def compute(status:, method: nil, route: nil, response_headers: nil,
                response_body: nil, stack_frame: nil)
      method = "GET" if method.nil? || method.empty? # FP-011

      # FP-012. 404 is intercepted BEFORE the code-based strategies: a generic
      # `not_found` code is the same on every route, so grouping 404s by code
      # is useless for recovery.
      if status == 404
        normalized = route.nil? || route.empty? ? "" : normalize_route(route)
        # FP-014: the parameter test runs on the NORMALIZED route.
        if normalized.include?(":") || normalized.include?("{")
          return Result.new(
            "resource", "404:resource",
            "404 on a parameterized route (#{method} #{normalized}); " \
            "the addressed resource was not found"
          )
        end
        reason = if normalized.empty?
                   "404 on a path that matched no route; the endpoint does not exist"
                 else
                   "404 on #{method} #{normalized}; no resource at this path"
                 end
        return Result.new("endpoint", "404:endpoint", reason)
      end

      # 1. Explicit header. Fully deterministic; the customer opted in.
      header_code = read_header_code(response_headers)
      if header_code
        return Result.new("header", "#{status}:#{header_code}",
                          %(x-restless-error-code header: "#{header_code}"))
      end

      # 2. Code-like field in the body. Stripe/AWS/Twilio-shaped APIs land here.
      body_code = read_body_code(response_body)
      if body_code
        return Result.new("body-code", "#{status}:#{body_code}",
                          %(code field in body: "#{body_code}"))
      end

      # 3. Stack trace (5xx with a thrown exception). File + function only:
      # FP-041 forbids a line number, so adding a comment above a `raise`
      # cannot split an error group.
      if status >= 500 && stack_frame
        return Result.new(
          "stack", "#{status}:#{stack_frame[:file]}:#{stack_frame[:fn]}",
          "top user frame: #{stack_frame[:fn]} in #{stack_frame[:file]}"
        )
      end

      # 4. Normalized message + templated route.
      normalized_route = normalize_route(route)
      msg = normalize_message(extract_message(response_body))
      unless msg.empty?
        return Result.new("message", "#{status}:#{method}:#{normalized_route}:#{msg}",
                          %(message normalized to "#{msg}"))
      end

      # 5. Status + route only. Coarse, but it groups all unhandled responses.
      Result.new("route-only", "#{status}:#{method}:#{normalized_route}",
                 "no usable code or message; falling back to status + route")
    end

    # FP-017. The header name is matched case-insensitively.
    def read_header_code(headers)
      return nil unless headers.is_a?(Hash)

      lower = {}
      headers.each { |k, v| lower[Text.full_lower(k.to_s)] = v }
      value = lower["x-restless-error-code"]
      looks_like_code?(value) ? value : nil
    end

    def read_body_code(body)
      return nil unless body.is_a?(Hash)

      CODE_FIELDS.each do |field|
        value = body[field]
        return value if looks_like_code?(value)
      end

      NESTED_PATHS.each do |path|
        value = body
        path.each { |segment| value = value.is_a?(Hash) ? value[segment] : nil }
        return value if looks_like_code?(value)
      end

      nil
    end

    # FP-015.
    def looks_like_code?(value)
      value.is_a?(String) &&
        !value.empty? &&
        value.length <= 64 &&
        CODE_RE.match?(value)
    end

    # FP-018. Body itself if it is a string; then `message`; then `error` if
    # it is a string; then `error.message`. Anything else yields no message.
    def extract_message(body)
      return "" if body.nil? || body == false
      return body if body.is_a?(String)
      return "" unless body.is_a?(Hash)

      message = body["message"]
      return message if message.is_a?(String)

      nested = body["error"]
      return nested if nested.is_a?(String)
      if nested.is_a?(Hash) && nested["message"].is_a?(String)
        return nested["message"]
      end

      ""
    end

    # FP-020. The 12 steps, in exactly this order.
    def normalize_message(msg)
      return "" if msg.nil? || msg.empty?

      s = Text.full_lower(msg)          # 1
      s = s.gsub(RE_URL, " ")           # 2
      s = s.gsub(RE_EMAIL, " ")         # 3
      s = s.gsub(RE_QUOTED, " ")        # 4
      s = strip_digit_words(s)          # 5
      s = s.gsub(RE_PUNCT, " ")         # 6
      s = s.gsub(RE_WS_RUN, " ")        # 7
      s = Text.ws_trim(s)               # 8
      s.split(/ /, -1)                  # 9  (never `split(" ")`: awk mode)
       .reject { |w| w.length <= 1 }    # 10
       .first(6)                        # 11
       .join("-")                       # 12
    end

    # FP-021. Whole words containing a digit are stripped, not bare digits:
    # `abc123` reduced to `abc` would still influence the key, so grouping
    # would break whenever the surrounding id changed.
    #
    # See RE_DIGIT_WORD for why this runs against the byte string.
    def strip_digit_words(str)
      str.dup
         .force_encoding(Encoding::ASCII_8BIT)
         .gsub(RE_DIGIT_WORD, " ")
         .force_encoding(Encoding::UTF_8)
    end

    # FP-030..FP-032.
    def normalize_route(route)
      return "/" if route.nil? || route.empty?

      # `split("/", -1)`: Ruby drops trailing empty fields without the
      # negative limit, so `/users/` would lose its trailing segment and stop
      # matching JavaScript.
      segments = route.split("/", -1)
      # FP-031: index 0 is the text BEFORE the first "/" and is never
      # normalized, which keeps a bare "123" route untouched.
      (1...segments.length).each do |i|
        segments[i] = ":id" if id_segment?(segments[i])
      end
      segments.join("/")
    end

    def id_segment?(segment)
      SEG_UUID.match?(segment) ||
        SEG_NUMERIC.match?(segment) ||
        SEG_LONG_HEX.match?(segment)
    end

    # FP-042. Strip the absolute path prefix down to a project-relative path,
    # so the same source file produces the same key on a laptop and in
    # production.
    #
    # Hand-rolled rather than regex because the reference is
    # `/\/(?:src|lib|app|api|routes|controllers|handlers)\/.+$/` and JavaScript's
    # `.` excludes CR, LS and PS as well as LF while Ruby's excludes only LF.
    # A path containing a stray CR would therefore take a different branch.
    # The semantics are: the FIRST `/marker/` whose remainder is non-empty and
    # free of JavaScript line terminators.
    #
    # KNOWN DEFECT, reproduced deliberately. Because the first match wins, a
    # deployment root that is itself named after a marker (Docker
    # `WORKDIR /app`, Heroku) survives into the key, so production and laptop
    # fingerprints diverge for the same file. See the note under FP-042; the
    # fix is a CHANGE-003 coordinated change and is NOT in spec 1.0.0.
    def project_relative(file)
      pos = 0
      while (idx = file.index("/", pos))
        PROJECT_DIRS.each do |marker|
          next unless file[idx + 1, marker.length] == marker
          next unless file[idx + 1 + marker.length] == "/"

          rest = file[(idx + 2 + marker.length)..-1]
          next if rest.nil? || rest.empty?
          next if rest.each_char.any? { |c| Text.js_line_terminator?(c) }

          return file[(idx + 1)..-1]
        end
        pos = idx + 1
      end

      file.split("/", -1).last(2).join("/")
    end
  end
end
