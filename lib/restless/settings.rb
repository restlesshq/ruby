# frozen_string_literal: true

require "json"

module Restless
  # CONTRACT.md section 12. `.restless/settings.json` is created and owned by
  # the `api` CLI (`npx api setup`); the SDK consumes exactly two fields of it
  # at runtime (CONFIG-015).
  module Settings
    class ConfigError < StandardError; end

    @cache = nil
    @loaded = false
    @mutex = Mutex.new

    class << self
      # CONFIG-010, CONFIG-011. Walk up from the working directory to the
      # filesystem root, take the first hit, and read at most once per process
      # -- including the negative result.
      def load(start_dir = Dir.pwd)
        @mutex.synchronize do
          return @cache if @loaded

          @loaded = true
          @cache = read_settings(start_dir)
        end
      end

      # Test-only. Do not call from production code.
      def reset_cache!
        @mutex.synchronize do
          @loaded = false
          @cache = nil
        end
      end

      # CONFIG-013, CONFIG-014. Returns {id:, name:, request_id_prefix:,
      # redact:} or nil.
      def resolve_api(settings, name = nil)
        return nil if settings.nil?

        apis = settings["apis"]
        return nil unless apis.is_a?(Array) && !apis.empty?

        if name && !name.empty?
          match = apis.find { |a| a["name"] == name } || apis.find { |a| a["id"] == name }
          unless match
            raise ConfigError,
                  "restless-sdk: no API named #{name.inspect} in .restless/settings.json " \
                  "(found: #{apis.map { |a| a['name'] }.join(', ')})"
          end
          return entry(match)
        end

        return entry(apis[0]) if apis.length == 1

        # Guessing would silently apply the wrong redaction list.
        raise ConfigError,
              "restless-sdk: .restless/settings.json has multiple APIs " \
              "(#{apis.map { |a| a['name'] }.join(', ')}) -- pass api: \"<name>\" to " \
              "Restless::Client.new to pick one."
      end

      private

      def entry(api)
        {
          id: api["id"],
          name: api["name"],
          request_id_prefix: api["requestIdPrefix"],
          redact: api["redact"].is_a?(Hash) ? api["redact"] : nil
        }
      end

      def read_settings(start_dir)
        file = find_settings_file(start_dir)
        return nil if file.nil?

        # CONFIG-012: a missing or malformed file yields no configuration. It
        # must not raise and must not prevent construction.
        parsed = JSON.parse(File.read(file))
        parsed.is_a?(Hash) ? parsed : nil
      rescue StandardError
        nil
      end

      def find_settings_file(start_dir)
        dir = File.expand_path(start_dir)
        loop do
          candidate = File.join(dir, ".restless", "settings.json")
          return candidate if File.file?(candidate)

          parent = File.dirname(dir)
          return nil if parent == dir

          dir = parent
        end
      end
    end
  end
end
