# frozen_string_literal: true

require_relative "mask"
require_relative "redact"
require_relative "fingerprint"
require_relative "stack_frames"
require_relative "har"
require_relative "request_id"
require_relative "injection"

module Restless
  # The shared operation table behind the conformance driver.
  #
  # Both `exe/restless-conformance` (the stdio driver the cross-language
  # harness drives) and `test/test_vectors.rb` (the in-process replay) go
  # through this one file, so it is impossible for the vectors to describe
  # behaviour the driver does not exhibit.
  #
  # See node-sdk/spec/driver/PROTOCOL.md. Internal: never part of the public
  # API, never shipped behaviour a customer depends on.
  module Conformance
    # An input this implementation's language cannot represent or parse. The
    # harness records it as a SKIP, not a failure. See CONTRACT.md FP-046 and
    # PRIM-035.
    class UnsupportedDialect < StandardError; end

    class UnknownOp < StandardError; end

    module_function

    def dispatch(op, input)
      input ||= {}
      case op
      # --- masking (section 3) ---
      when "mask"
        Mask.mask(str_or_nil(input["apiKey"]))

      # --- redaction (section 4) ---
      when "redactValue"
        Redact.redact_value(str(input["value"]))
      when "redactHeaders"
        Redact.redact_headers(hash(input["headers"]), strs(input["extra"]))
      when "redactUrl"
        Redact.redact_url(str(input["url"]), strs(input["extra"]))
      when "redactBody"
        body = str_or_nil(input["body"])
        # An empty string is a VALUE here, distinct from an absent body, so
        # this is deliberately not collapsed to nil.
        body.nil? ? nil : Redact.redact_body(body, str_or_nil(input["contentType"]), strs(input["extra"]))
      when "truncateBody"
        body = str_or_nil(input["body"])
        body.nil? ? nil : Redact.truncate_body(body, int(input["maxBytes"]))

      # --- fingerprinting (section 5) ---
      when "fingerprint"
        fingerprint(input)
      when "normalizeRoute"
        Fingerprint.normalize_route(str_or_nil(input["route"]))
      when "normalizeMessage"
        Fingerprint.normalize_message(str(input["message"]))
      when "fallbackKey"
          # FP-047's derivation, dialect-free: every case reaching it through
          # `fingerprint` carries a v8 stack this SDK must skip (FP-046).
          Fingerprint.fallback_key(
            int(input["status"]),
            str_or_nil(input["method"]) || "GET",
            str_or_nil(input["route"]),
            input["responseBody"]
          )
        when "projectRelative"
        # FP-042 is shared across every SDK even though frame PARSING is not
        # (FP-044/FP-046), so path normalization gets its own dialect-free op.
        Fingerprint.project_relative(str(input["file"]))

      # --- request ids (section 6) ---
      when "formatRequestId"
        RequestId.format_request_id(str(input["rawId"]), str_or_nil(input["prefix"]))
      when "stripRequestIdPrefix"
        RequestId.strip_request_id_prefix(str(input["requestId"]))
      when "requestIdHeaders"
        RequestId.response_headers(
          str(input["ourId"]),
          hash(input["incomingHeaders"]),
          str_or_nil(input["prefix"]),
          input.key?("hasApiKey") ? input["hasApiKey"] == true : true
        )

      # --- injection (section 10) ---
      when "recoverySlug"
        Injection.recovery_slug(str_or_nil(input["method"]), str_or_nil(input["path"]))

      # --- HAR (section 7) ---
      when "harEntry"
        Har.to_har_entry(hash(input["captured"]))

      else
        raise UnknownOp, "unknown op: #{op}"
      end
    end

    def fingerprint(input)
      stack = stack_text(input["stackTrace"])
      if !stack.empty? && v8_dialect?(stack)
        raise UnsupportedDialect,
              "unsupported stack dialect: v8 (this SDK parses Ruby backtraces; FP-044/FP-046)"
      end

      # Parse the stack the way the Rack adapter does. This used to pass
      # nil, which made the driver structurally incapable of reaching the
      # stack strategy: the whole path was dead through the harness while
      # the SDK's own tests, which call StackFrames directly, still passed.
      # Nothing caught it, because every v8-shaped stack vector is skipped
      # under FP-046 so the harness never exercises this branch. A driver
      # that short-circuits the SDK is testing itself.
      result = Fingerprint.compute(
        status: int(input["status"]),
        method: str_or_nil(input["method"]),
        route: str_or_nil(input["route"]),
        response_headers: input["responseHeaders"].is_a?(Hash) ? input["responseHeaders"] : nil,
        response_body: input["responseBody"],
        stack_frame: stack.empty? ? nil : StackFrames.top_user_frame(stack.split("\n"))
      )
      # FP-003: `reason` is human-facing prose, explicitly not contract
      # surface, so drivers must not emit it. FP-047's `previousKey` IS
      # contract surface, and is emitted only when the stack strategy set one.
      out = { "strategy" => result.strategy, "key" => result.key }
      out["previousKey"] = result.previous_key if result.previous_key
      out
    end

    def stack_text(raw)
      case raw
      when String then raw
      when Array  then raw.map(&:to_s).join("\n")
      else ""
      end
    end

    # A v8 frame is `    at fn (/file.js:12:34)`. Ruby backtraces are
    # `/file.rb:12:in 'fn'`, so anything shaped like the former is out of
    # dialect and the driver says so rather than guessing.
    def v8_dialect?(stack)
      stack.split("\n").any? { |line| line.strip.start_with?("at ") }
    end

    # --- input coercion -----------------------------------------------------
    # The protocol represents absence as JSON null.

    def str(value)
      value.is_a?(String) ? value : ""
    end

    def str_or_nil(value)
      value.is_a?(String) ? value : nil
    end

    def strs(value)
      return [] unless value.is_a?(Array)

      value.select { |v| v.is_a?(String) }
    end

    def hash(value)
      value.is_a?(Hash) ? value : {}
    end

    def int(value)
      case value
      when Integer then value
      when Float then value.to_i
      when String then value.to_i
      else 0
      end
    end
  end
end
