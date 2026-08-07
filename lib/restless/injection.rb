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

    # INJECT-001..004, INJECT-006. Returns the headers to set plus the `debug`
    # object to merge into a JSON body, or nil when nothing should be injected.
    def build(status:, request_id:, base_url:, prefix: nil, recovery: nil,
              method: nil, path: nil, docs_url: nil)
      return nil if status < 400 # INJECT-001

      display = RequestId.format_request_id(request_id, prefix)
      # INJECT-006: the server-supplied docsUrl when one has been learned,
      # else the configured base URL. One batch of staleness after a
      # docs-domain change is accepted.
      log_host = docs_url.nil? || docs_url.empty? ? base_url : docs_url
      log_url = "#{log_host}/logs/#{request_id}"
      debug_cmd = "npx api debug #{display}"

      # Per-request "dig-in" URL the calling agent (often an AI) can fetch for
      # concrete next steps. Deliberately LEGIBLE: it ends in `<slug>.md` so it
      # reads as documentation rather than a tracking blob. The first segment
      # is the same public request id already in `debug.log`, so the dashboard
      # can correlate the follow-up without any new tracking token.
      slug = recovery_slug(method, path)
      dig_in = "For the accepted parameters and next steps, " \
               "fetch #{log_host}/p/#{request_id}/#{slug}.md"
      # INJECT-004: a cached recovery message precedes the dig-in line,
      # separated by a blank line.
      recovery_text =
        if recovery.nil? || recovery.empty?
          dig_in
        else
          "#{recovery}\n\n#{dig_in}"
        end

      {
        headers: {
          "x-log-url" => log_url, # INJECT-002
          "x-debug" => debug_cmd
        },
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
