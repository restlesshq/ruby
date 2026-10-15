# frozen_string_literal: true

require "digest"

module Restless
  # CONTRACT.md section 12.1 (`SAMPLE`). Per-endpoint control over how much
  # of each request is sent.
  #
  # Everything here is pure. The middleware draws `u` once per request and
  # hands it to `decide`; the tests and the conformance driver pass a fixed
  # one.
  #
  # A mode is "on", "off", "errors" or a Float rate already quantized to a
  # multiple of 0.0001 (SAMPLE-002). Outcomes are :full, :stub and :drop.
  module Sampling
    # A merged, validated configuration. `routes` maps normalized keys
    # (`"GET /pets/{id}"`) to modes, in insertion order.
    Config = Struct.new(:default, :routes) do
      # SAMPLE-041. All "on" with no routes is exactly the behaviour without
      # sampling, and has nothing to report.
      def default?
        default == "on" && routes.empty?
      end
    end

    STRING_MODES = %w[on off errors].freeze

    # SAMPLE-002.
    RATE_STEPS = 10_000

    # SAMPLE-010. Printable ASCII only, so every SDK sorts and hashes keys
    # byte for byte the same. `\A...\z`, never `^...$` (PRIM-005).
    PATH_RE = %r{\A/[\x21-\x7e]*\z}.freeze
    METHOD_RE = /\A(?:[A-Za-z]+|\*)\z/.freeze
    # SAMPLE-011. WORD is ASCII (PRIM-001), so no `\w`.
    PARAM_RE = /:([A-Za-z0-9_]+)/.freeze

    module_function

    # SAMPLE-001..003. The normalized mode, or nil when `value` is not a
    # valid one (the caller decides what invalid falls back to).
    #
    # Symbols (`:off`) are accepted as the Ruby spelling of the string modes.
    # They can only come from code: JSON has no symbols.
    def normalize_mode(value)
      value = value.to_s if value.is_a?(Symbol)
      return value if value.is_a?(String) && STRING_MODES.include?(value)
      # `true` is not Numeric in Ruby, unlike in some languages. Complex is
      # Numeric but not real.
      return nil unless value.is_a?(Numeric) && value.real?

      rate = value.to_f
      return nil unless rate.finite? && rate >= 0 && rate <= 1

      steps = quantize(rate)
      # A rate that rounds to 1 IS "on"; one spelling, so the dashboard and
      # the hash never see two.
      steps >= RATE_STEPS ? "on" : steps / RATE_STEPS.to_f
    end

    # SAMPLE-002. floor(r * 10000 + 0.5) in double precision. Not `round`,
    # which would make the rounding mode a per-language question.
    def quantize(rate)
      (rate.to_f * RATE_STEPS + 0.5).floor
    end

    # SAMPLE-011. The normalized path, or nil when it is not a valid one.
    def normalize_path(path)
      normalized = path.to_s.gsub(PARAM_RE, '{\1}')
      normalized = normalized[0..-2] while normalized.length > 1 && normalized.end_with?("/")
      PATH_RE.match?(normalized) ? normalized : nil
    end

    # SAMPLE-010. `"get  /pets/:id/"` becomes `"GET /pets/{id}"`. Nil when
    # the key is not valid.
    def normalize_route_key(key)
      # Only U+0020 is trimmed: a tab is not a separator (SAMPLE-010).
      trimmed = key.to_s.sub(/\A +/, "").sub(/ +\z/, "")
      space = trimmed.index(" ")
      return nil if space.nil?

      method = trimmed[0, space]
      path = normalize_path(trimmed[space..-1].sub(/\A +/, ""))
      return nil if path.nil? || !METHOD_RE.match?(method)

      "#{method.upcase(:ascii)} #{path}"
    end

    # SAMPLE-013, SAMPLE-014. Merge the settings-file and code configs and
    # validate every value. Never raises: a bad mode degrades to "on", a bad
    # key is ignored, and either is reported in `warnings` for the debug log.
    #
    # Returns `[Config, warnings]`.
    def normalize(settings = nil, code = nil)
      warnings = []
      config = Config.new("on", {})

      [["settings", settings], ["code", code]].each do |source, raw|
        next if raw.nil?
        unless raw.is_a?(Hash)
          warnings << "sampling (#{source}): expected a Hash, ignored"
          next
        end

        if member?(raw, "default")
          value = member(raw, "default")
          mode = normalize_mode(value)
          warnings << "sampling default (#{source}): invalid mode #{value.inspect}, using \"on\"" if mode.nil?
          config.default = mode || "on"
        end

        routes = member(raw, "routes")
        next if routes.nil?
        unless routes.is_a?(Hash)
          warnings << "sampling routes (#{source}): expected a Hash, ignored"
          next
        end

        routes.each do |raw_key, raw_mode|
          key = raw_key.is_a?(String) || raw_key.is_a?(Symbol) ? normalize_route_key(raw_key.to_s) : nil
          if key.nil?
            warnings << "sampling routes (#{source}): invalid route key #{raw_key.inspect}, ignored"
            next
          end

          mode = normalize_mode(raw_mode)
          if mode.nil?
            warnings << "sampling routes[#{raw_key.inspect}] (#{source}): invalid mode " \
                        "#{raw_mode.inspect}, using \"on\""
          end
          # Re-insert so a later duplicate takes the later position as well as
          # the value. Nothing contract-visible depends on the position (the
          # hash and the report sort), but insertion order stays honest.
          config.routes.delete(key)
          config.routes[key] = mode || "on"
        end
      end

      [config, warnings]
    end

    # SAMPLE-020..022. The mode for one request. `route` is the matched
    # pattern, nil when the framework reported none.
    def resolve_mode(config, method, route)
      if route.is_a?(String) && !route.empty?
        path = normalize_path(route)
        if path
          exact = config.routes["#{method.to_s.upcase(:ascii)} #{path}"]
          return exact unless exact.nil?

          any = config.routes["* #{path}"]
          return any unless any.nil?
        end
      end
      config.default
    end

    # SAMPLE-030, SAMPLE-031. `u` is uniform in [0, 1), drawn once per
    # request.
    def decide(mode, status, u)
      return :drop if mode == "off"

      error = status >= 400
      return(error ? :full : :drop) if mode == "errors"
      return :full if !mode.is_a?(Numeric) || error

      u < mode ? :full : :stub
    end

    # SAMPLE-040. The canonical text the hash is computed over, or nil for
    # the default configuration (SAMPLE-041).
    def canonical(config)
      return nil if config.default?

      # Keys are printable ASCII (SAMPLE-010) and String#<=> compares bytes,
      # so this is the byte order the contract asks for.
      out = +"default\t#{token(config.default)}\n"
      config.routes.keys.sort.each do |key|
        out << "#{key}\t#{token(config.routes[key])}\n"
      end
      out
    end

    # SAMPLE-040. Lowercase hex SHA-256 of the canonical form, or nil.
    def digest(config)
      text = canonical(config)
      text && Digest::SHA256.hexdigest(text)
    end

    # SAMPLE-050. The routes in sorted key order, as the report carries them.
    def sorted_routes(config)
      out = {}
      config.routes.keys.sort.each { |key| out[key] = config.routes[key] }
      out
    end

    # `0.1` -> "0.1000", built from the integer step count, never from float
    # formatting.
    def token(mode)
      return mode unless mode.is_a?(Numeric)

      format("0.%04d", quantize(mode))
    end

    # `default:` and `routes:` read naturally as symbols in Ruby code, and
    # arrive as strings from the settings file.
    def member?(hash, name)
      hash.key?(name.to_sym) || hash.key?(name)
    end

    def member(hash, name)
      hash.key?(name.to_sym) ? hash[name.to_sym] : hash[name]
    end
  end
end
