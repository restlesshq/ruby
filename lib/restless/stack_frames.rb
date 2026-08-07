# frozen_string_literal: true

require "rbconfig"

require_relative "fingerprint"

module Restless
  # CONTRACT.md FP-043, FP-044, FP-045. The Ruby dialect of stack parsing.
  #
  # FP-044 makes frame parsing and the skip list explicitly per-language: only
  # the OUTPUT shape is contract surface. This module is therefore the one
  # place in the SDK that knows what a Ruby backtrace looks like, and the
  # shared conformance vectors deliberately do not cover it (FP-046); see
  # `test/test_stack_frames.rb`.
  module StackFrames
    # Ruby <= 3.3: "path.rb:12:in `method'"
    # Ruby >= 3.4: "path.rb:12:in 'Klass#method'"
    FRAME_RE = /\A(.+):(\d+):in [`'](.+)'\z/.freeze
    # Some frames carry no method label at all.
    FRAME_NO_FN_RE = /\A(.+):(\d+)\z/.freeze

    # `block (3 levels) in handler` -> `block in handler`. The nesting count
    # is closer to a line number than to an identity: it moves when somebody
    # wraps the throw site in one more `each`, which FP-041 says must not
    # split a group.
    BLOCK_LEVELS_RE = /\Ablock \(\d+ levels\) in /.freeze

    # FP-044. The Ruby equivalent of `node_modules` / `node:internal` /
    # `@restlessai/sdk`.
    #
    # Everything here is matched by FILE PATH, never by module or class name.
    # A name check would also skip a customer's own `Restless`-flavoured code
    # and, worse, would not skip this gem when it is vendored under a
    # different constant. The SDK's own directory is resolved from `__dir__`,
    # so it is correct however the gem was installed.
    SDK_DIR = File.expand_path("..", __dir__).freeze

    STDLIB_DIRS = [
      RbConfig::CONFIG["rubylibdir"],
      RbConfig::CONFIG["rubyarchdir"],
      RbConfig::CONFIG["sitelibdir"],
      RbConfig::CONFIG["vendorlibdir"]
    ].compact.reject(&:empty?).map { |d| File.expand_path(d) }.freeze

    GEM_DIRS = begin
      dirs = []
      begin
        dirs.concat(Array(Gem.path)) if defined?(Gem)
        dirs << Gem.dir if defined?(Gem) && Gem.respond_to?(:dir)
      rescue StandardError
        # Gem may not be loaded at all; the "/gems/" fallback below covers it.
      end
      dirs.compact.uniq.map { |d| File.expand_path(d) }.freeze
    end

    module_function

    # FP-043. The frame NEAREST THE THROW SITE that is not vendor, runtime or
    # SDK code.
    #
    # Ruby's `Exception#backtrace` is innermost-FIRST (index 0 is where the
    # exception was raised), like a v8 `Error.stack` and unlike a Python
    # traceback, so the walk goes FORWARDS. Implementing this positionally in
    # the wrong direction returns the Rack entry point for every crash in the
    # process, which collapses every 500 into one fingerprint group and
    # defeats the strategy entirely. Verified empirically in
    # `test/test_stack_frames.rb`, not assumed.
    def top_user_frame(backtrace)
      return nil if backtrace.nil?

      Array(backtrace).each do |raw|
        frame = parse_frame(raw.to_s)
        next if frame.nil?
        next if skip_path?(frame[:file])

        return {
          file: Fingerprint.project_relative(frame[:file]),
          fn: frame[:fn]
        }
      end
      nil
    end

    def parse_frame(line)
      if (m = FRAME_RE.match(line))
        return { file: m[1], fn: normalize_fn(m[3]) }
      end
      if (m = FRAME_NO_FN_RE.match(line))
        # FP-045.
        return { file: m[1], fn: "anonymous" }
      end

      nil
    end

    def normalize_fn(name)
      cleaned = name.sub(BLOCK_LEVELS_RE, "block in ")
      cleaned.empty? ? "anonymous" : cleaned
    end

    def skip_path?(path)
      return true if path.nil? || path.empty?
      # Ruby 3.x synthesises frames like "<internal:kernel>:90:in `tap'".
      return true if path.start_with?("<internal:")
      return true if path.start_with?(SDK_DIR)
      return true if path.include?("/gems/")
      return true if STDLIB_DIRS.any? { |dir| path.start_with?(dir) }
      return true if GEM_DIRS.any? { |dir| path.start_with?(dir) }

      false
    end

    # Convenience for adapters: fingerprint-ready frame from an exception.
    def from_exception(error)
      return nil unless error.respond_to?(:backtrace)

      top_user_frame(error.backtrace)
    rescue StandardError
      nil
    end
  end
end
