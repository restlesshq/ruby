# frozen_string_literal: true

require "json"

require_relative "text"
require_relative "request_id"

module Restless
  # CONTRACT.md section 10. What the SDK adds to the customer's own responses.
  module Injection
    module_function

    # INJECT-005. Legible URL slug for the recovery dig-in path, derived from
    # method + route pattern: `GET /car/{id}` becomes `get-car-id`.
    #
    # The server resolves it back to an OpenAPI operation by matching the same
    # scheme, so this MUST stay in sync with the app's `recoverySlug`
    # (INJECT-007).
    def recovery_slug(method = nil, path = nil)
      m = Text.full_lower(method.to_s)
      # JavaScript's `trim` strips the PRIM-002 set; Ruby's `strip` strips a
      # different one in both directions.
      p = Text.ws_trim(path.to_s)
      return "unknown" if m.empty? || p.empty?

      flat = p.gsub(%r{[/{}:]+}, "-")
              .gsub(/[^a-zA-Z0-9\-]/, "")
              .gsub(/-+/, "-")
      # `\A` / `\z`, not `^` / `$`: Ruby's are line anchors (PRIM-005).
      flat = flat.sub(/\A-/, "").sub(/-\z/, "")
      flat.empty? ? m : "#{m}-#{flat}"
    end

    # INJECT-002. The debug response headers, which ship on every status.
    #
    # `x-log-url` is omitted with no portal origin; `x-debug` carries no URL,
    # so it always ships.
    def headers(request_id:, prefix: nil, portal_url: nil)
      display = RequestId.format_request_id(request_id, prefix)
      out = { "x-debug" => "npx api debug #{display}" }
      out["x-log-url"] = "#{portal_url}/logs/#{request_id}" unless portal_url.nil? || portal_url.empty?
      out
    end

    # INJECT-001..004, INJECT-006. Returns the headers to set plus the `debug`
    # object to merge into a JSON body (nil when there is nothing to merge).
    #
    # `portal_url` is the project's public portal origin, published by the
    # server. It is NOT the ingest base URL, which serves `/v1/*` and would
    # 404 both paths, and there is deliberately no fallback to it: with no
    # portal origin we emit `x-debug` alone. A caller cannot tell a broken URL
    # from a missing one, and one fetched 404 teaches an agent to stop
    # following the link.
    def build(status:, request_id:, prefix: nil, recovery: nil,
              method: nil, path: nil, portal_url: nil)
      hdrs = headers(request_id: request_id, prefix: prefix, portal_url: portal_url)

      # INJECT-001. The body object is 4xx/5xx only: a successful body is the
      # caller's data, not ours to reshape. With no portal origin there is no
      # URL to put in one either (INJECT-006).
      return { headers: hdrs, debug: nil } if status < 400 || portal_url.nil? || portal_url.empty?

      log_url = hdrs["x-log-url"]
      debug_cmd = hdrs["x-debug"]

      # Per-request "dig-in" URL the calling agent (often an AI) can fetch for
      # concrete next steps. Deliberately LEGIBLE: it ends in `<slug>.md` so it
      # reads as documentation rather than a tracking blob. The first segment
      # is the same public request id already in `debug.log`, so the dashboard
      # can correlate the follow-up without any new tracking token.
      slug = recovery_slug(method, path)
      dig_in = "For the accepted parameters and next steps, " \
               "fetch #{portal_url}/p/#{request_id}/#{slug}.md"
      # INJECT-004: a cached recovery message precedes the dig-in line,
      # separated by a blank line.
      recovery_text =
        if recovery.nil? || recovery.empty?
          dig_in
        else
          "#{recovery}\n\n#{dig_in}"
        end

      {
        headers: hdrs,
        debug: {
          "log" => log_url,
          "cli" => debug_cmd,
          "recovery" => recovery_text
        }
      }
    end

    # INJECT-003. Merge `debug` into the response body ONLY when the body is a
    # JSON OBJECT (not an array, not a scalar) and the content type says JSON.
    #
    # Returns the original body untouched on any parse failure: SAFETY-001
    # outranks everything here.
    def apply_body(body, content_type, debug)
      return body if body.nil? || body.empty? || debug.nil?
      return body unless Text.full_lower(content_type.to_s).include?("application/json")

      begin
        parsed = JSON.parse(body, max_nesting: false)
      rescue StandardError
        return body
      end
      return body unless parsed.is_a?(Hash)

      JSON.generate(parsed.merge("debug" => debug))
    rescue StandardError
      body
    end
  end
end
