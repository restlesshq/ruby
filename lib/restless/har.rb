# frozen_string_literal: true

require_relative "text"
require_relative "redact"

module Restless
  # CONTRACT.md section 7. Captured traffic rides inside a HAR 1.2 envelope.
  module Har
    module_function

    # HAR-013. The scheme the client used, for the logged `request.url`.
    #
    # A TLS-terminating proxy (Render, Heroku, an ALB, nginx) hands the app
    # plain HTTP, so `rack.url_scheme` alone logs every request as `http://`.
    # The first hop's `Forwarded: proto=` wins, then the first
    # `X-Forwarded-Proto` value, then the transport. Only `http` and `https`
    # are accepted from a header; anything else falls through.
    #
    # Deliberately not `Rack::Request#scheme`: it also honours
    # `X-Forwarded-Scheme` and `X-Forwarded-Ssl`, and newer Rack takes the
    # LAST `X-Forwarded-Proto` value, so it disagrees with the contract.
    #
    # `split(..., -1)` throughout: without the negative limit Ruby returns an
    # empty array for "," where JavaScript returns two empty strings.
    def request_scheme(headers, encrypted)
      forwarded = header_value(headers, "forwarded")
      if forwarded
        first_hop = forwarded.split(",", -1).first.to_s
        first_hop.split(";", -1).each do |pair|
          eq = pair.index("=")
          next if eq.nil? || Text.ws_trim(pair[0...eq]).downcase != "proto"

          scheme = valid_scheme(pair[(eq + 1)..])
          return scheme if scheme
        end
      end
      xfp = header_value(headers, "x-forwarded-proto")
      scheme = xfp && valid_scheme(xfp.split(",", -1).first.to_s)
      return scheme if scheme

      encrypted ? "https" : "http"
    end

    # First non-empty value under a case-insensitive name. A repeated header
    # counts as its first occurrence.
    def header_value(headers, name)
      headers.each do |key, value|
        next unless key.to_s.downcase == name

        value = value.first if value.is_a?(Array)
        return value if value.is_a?(String) && !value.empty?
      end
      nil
    end

    def valid_scheme(raw)
      s = Text.ws_trim(raw.to_s)
      s = s[1...-1] if s.length >= 2 && s.start_with?('"') && s.end_with?('"')
      s = s.downcase
      %w[http https].include?(s) ? s : nil
    end

    # HAR-005. Parse the query into ordered name/value pairs.
    #
    # Hand-rolled rather than delegating to a URI library so it shares the
    # exact decoding rule with `redact_url`, and so a port does not have to
    # reproduce WHATWG URL parsing to agree with us. Duplicate names are
    # preserved, which a hash-based parse would lose.
    def parse_query_string(url)
      q = url.index("?")
      return [] if q.nil?

      rest = url[(q + 1)..-1] || ""
      hash = rest.index("#")
      query = hash.nil? ? rest : rest[0, hash]
      return [] if query.empty?

      out = []
      query.split("&", -1).each do |pair|
        next if pair.empty?

        eq = pair.index("=")
        if eq.nil?
          out << { "name" => Redact.percent_decode(pair), "value" => "" }
        else
          out << {
            "name" => Redact.percent_decode(pair[0, eq]),
            "value" => Redact.percent_decode(pair[(eq + 1)..-1] || "")
          }
        end
      end
      out
    end

    def headers_to_list(headers)
      headers.map { |name, value| { "name" => name, "value" => value } }
    end

    # `captured` is a hash with string keys:
    #   requestId, startedAt, duration, routePattern?,
    #   request: {method, url, headers, body?}, response: {status, headers, body?}
    #
    # A nil body means "no body captured" and is distinct from an empty one:
    # HAR-011 makes the first report -1 and the second 0.
    def to_har_entry(captured)
      request = captured["request"] || {}
      response = captured["response"] || {}
      request_headers = request["headers"] || {}
      response_headers = response["headers"] || {}

      request_body = request["body"]
      response_body = response["body"]

      req_content_type = request_headers["content-type"]
      req_content_type = "" if req_content_type.nil? || req_content_type == ""
      # HAR-007: mimeType falls back when the response has no content type.
      res_content_type = response_headers["content-type"]
      if res_content_type.nil? || res_content_type == ""
        res_content_type = "application/octet-stream"
      end

      duration = captured["duration"] || 0

      har_request = {
        "method" => request["method"],
        "url" => request["url"],
        "httpVersion" => "HTTP/1.1", # HAR-003 (reserved)
        "headers" => headers_to_list(request_headers), # HAR-004
        "queryString" => parse_query_string(request["url"].to_s)
      }
      # HAR-006: postData is present ONLY when a request body was captured.
      # The reference tests truthiness, so an empty-string body produces no
      # postData but still reports bodySize 0.
      unless request_body.nil? || request_body.empty?
        har_request["postData"] = {
          "mimeType" => req_content_type,
          "text" => request_body
        }
      end
      har_request["headersSize"] = -1 # HAR-012
      har_request["bodySize"] =
        request_body.nil? ? -1 : Text.utf8_length(request_body) # HAR-010/011

      {
        "startedDateTime" => captured["startedAt"], # HAR-001
        "time" => duration, # HAR-002
        "request" => har_request,
        "response" => {
          "status" => response["status"],
          "statusText" => "", # HAR-008 (reserved)
          "httpVersion" => "HTTP/1.1",
          "headers" => headers_to_list(response_headers),
          "content" => {
            "size" => response_body.nil? ? 0 : Text.utf8_length(response_body),
            "mimeType" => res_content_type,
            "text" => response_body.nil? ? "" : response_body
          },
          "headersSize" => -1,
          "bodySize" => response_body.nil? ? -1 : Text.utf8_length(response_body)
        },
        "timings" => { "send" => 0, "wait" => duration, "receive" => 0 }
      }
    end
  end
end
