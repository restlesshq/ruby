# frozen_string_literal: true

require_relative "restless/version"
require_relative "restless/text"
require_relative "restless/env"
require_relative "restless/mask"
require_relative "restless/redact"
require_relative "restless/fingerprint"
require_relative "restless/stack_frames"
require_relative "restless/har"
require_relative "restless/request_id"
require_relative "restless/injection"
require_relative "restless/caches"
require_relative "restless/settings"
require_relative "restless/uploader"
require_relative "restless/capture"
require_relative "restless/client"
# Depends on nothing outside the stdlib -- a Rack middleware is just an object
# with a `call(env)` -- so it is loaded eagerly rather than hidden behind a
# lazy require.
require_relative "restless/rack"

# Capture your API traffic and send it to Restless.
#
# This SDK implements version 1.0.0 of the Restless SDK Contract at level L2.
# See CONFORMANCE.md.
#
#     client = Restless.new(ENV["RESTLESS_KEY"])
#
#     client.setup do |request|
#       {
#         api_key: client.mask(request.header("Authorization")),
#         owner: {
#           id: workspace_id_for(request),
#           enrich: ->(id) { { label: Workspace.find(id).name } },
#         },
#       }
#     end
#
#     use client.rack
module Restless
  class << self
    # Construct a client. See Restless::Client#initialize.
    def new(api_key = nil, **options)
      Client.new(api_key, **options)
    end

    # MASK-001, available without a client for scripts and tests.
    def mask(api_key)
      Mask.mask(api_key)
    end

    def new_request_id
      RequestId.new_request_id
    end
  end
end
