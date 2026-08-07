# frozen_string_literal: true

require "securerandom"

module Restless
  # CONTRACT.md section 6.
  module RequestId
    UUID_RE = /\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/.freeze

    # REQID-005. `/m` so `.` behaves like a JavaScript `.` cannot -- it is a
    # superset, and the UUID test below is strict enough that the extra
    # matches are all rejected anyway, which makes the two engines agree.
    PREFIXED_RE = /\A[A-Za-z0-9]{1,7}-(.+)\z/m.freeze

    module_function

    # REQID-001, REQID-002. An RFC 4122 v4 UUID from a CSPRNG, lowercase and
    # hyphenated. Explicitly NOT time-ordered: request ids appear in
    # user-visible URLs and logs and must not leak ordering or timing.
    def new_request_id
      SecureRandom.uuid
    end

    # REQID-004. A configured prefix is for DISPLAY only; the raw UUID is what
    # goes on the wire as `_id` (WIRE-011).
    def format_request_id(raw_id, prefix = nil)
      return raw_id if prefix.nil? || prefix.empty?

      "#{prefix}-#{raw_id}"
    end

    # REQID-005. Returns group 1 only when it is itself a valid UUID;
    # otherwise the input comes back untouched.
    def strip_request_id_prefix(request_id)
      match = PREFIXED_RE.match(request_id)
      return request_id unless match
      return match[1] if UUID_RE.match?(match[1])

      request_id
    end

    def valid_request_id?(raw)
      UUID_RE.match?(strip_request_id_prefix(raw))
    end

    # REQID-010, REQID-011. Exactly one id header per response.
    #
    # Emit `x-request-id` -- the header everyone knows -- carrying our freshly
    # minted id. If the incoming request already carried one (a client, a
    # reverse proxy, upstream middleware), fall back to `x-restless-id` so an
    # existing chain is never clobbered.
    #
    # The literal `missing-key` is the setup CLI's signal that the server is
    # running but the key never loaded, as opposed to the request silently
    # dropping before upload.
    def response_headers(our_id, incoming_headers, prefix = nil, has_api_key = true)
      value = has_api_key ? format_request_id(our_id, prefix) : "missing-key"
      incoming = incoming_headers["x-request-id"]
      name = incoming.nil? || incoming == "" || incoming == false ? "x-request-id" : "x-restless-id"
      { name => value }
    end
  end
end
