# frozen_string_literal: true

# Replays the vendored conformance vectors in-process, so a Ruby developer
# gets a contract failure without needing Node installed.
#
#     ruby -Ilib -Itest test/test_vectors.rb
#
# The cross-language harness (node-sdk/spec/harness/run-vectors.mjs) drives
# exactly the same op table through exe/restless-conformance, so the two
# cannot disagree. See CONFORMANCE.md.

require "minitest/autorun"
require "json"

require "restless/conformance"
require "restless/version"

class TestVectors < Minitest::Test
  VECTOR_DIR = File.expand_path("../spec/vectors", __dir__)
  VECTORS_VERSION_FILE = File.expand_path("../spec/VECTORS_VERSION", __dir__)

  # PRIM-035. The vector documents themselves contain a lone surrogate escape,
  # which Ruby's JSON parser refuses outright ("incomplete surrogate pair"), so
  # the FILE cannot be read as-is. Each such escape is swapped for an ASCII
  # marker before parsing and the affected cases are then reported as skipped,
  # which is the same verdict the driver gives the cross-language harness.
  MARKER = "__restless_lone_surrogate__"

  HEX4 = /\A[0-9a-fA-F]{4}\z/.freeze

  def self.sanitize_lone_surrogates(text)
    out = +""
    index = 0
    while (at = text.index("\\u", index))
      out << text[index...at]
      hex = text[at + 2, 4]
      unless hex && HEX4.match?(hex)
        out << text[at, 2]
        index = at + 2
        next
      end

      code = hex.to_i(16)
      if code >= 0xD800 && code <= 0xDBFF
        low_hex = text[at + 8, 4]
        if text[at + 6, 2] == "\\u" && low_hex && HEX4.match?(low_hex) &&
           (0xDC00..0xDFFF).cover?(low_hex.to_i(16))
          out << text[at, 12] # a well-formed pair; keep it
          index = at + 12
          next
        end
        out << MARKER
        index = at + 6
        next
      end
      if code >= 0xDC00 && code <= 0xDFFF
        out << MARKER
        index = at + 6
        next
      end

      out << text[at, 6]
      index = at + 6
    end
    out << text[index..-1].to_s
    out
  end

  def self.load_vectors
    Dir[File.join(VECTOR_DIR, "*.json")].sort.flat_map do |path|
      doc = JSON.parse(sanitize_lone_surrogates(File.read(path)), max_nesting: false)
      doc["cases"].map { |kase| [File.basename(path), doc["specVersion"], kase] }
    end
  end

  CASES = load_vectors.freeze

  def test_vectors_are_present
    refute_empty CASES, "no vectors in #{VECTOR_DIR}"
  end

  # META-001. The vendored copy must be pinned to the version this SDK claims.
  def test_vectors_version_matches_declared_spec_version
    assert_equal Restless::SPEC_VERSION, File.read(VECTORS_VERSION_FILE).strip
    CASES.map { |(_, version, _)| version }.uniq.each do |version|
      assert_equal Restless::SPEC_VERSION, version
    end
  end

  def test_all_vectors
    passed = 0
    skipped = []
    failures = []

    CASES.each do |(_file, _version, kase)|
      if JSON.generate(kase).include?(MARKER)
        skipped << "#{kase['id']} (PRIM-035: unpaired surrogate)"
        next
      end

      begin
        actual = Restless::Conformance.dispatch(kase["op"], kase["input"])
      rescue Restless::Conformance::UnsupportedDialect => e
        skipped << "#{kase['id']} (#{e.message})"
        next
      rescue Restless::Conformance::UnknownOp => e
        skipped << "#{kase['id']} (#{e.message})"
        next
      rescue StandardError => e
        failures << "#{kase['id']} [#{kase['requirement']}] raised #{e.class}: #{e.message}"
        next
      end

      if matches?(kase["compare"], actual, kase["expected"])
        passed += 1
      else
        failures << format(
          "%s [%s / %s]\n      expected: %s\n      actual:   %s",
          kase["id"], kase["requirement"], kase["op"],
          JSON.generate(kase["expected"]), JSON.generate(actual)
        )
      end
    end

    assert_empty failures, "\n  " + failures.join("\n  ")

    # A sanity floor: if a refactor ever stops loading vectors, the assertion
    # above passes vacuously. This makes that failure loud.
    assert_operator passed, :>=, 199,
                    "only #{passed} vectors passed (#{skipped.length} skipped)"
  end

  private

  # Mirrors the harness's compare modes. "json" exists for redaction outputs
  # that had to be re-serialized: both sides are JSON strings and an encoder
  # whose key order differs should not fail for that alone.
  def matches?(mode, actual, expected)
    return actual == expected unless mode == "json"
    return actual == expected unless actual.is_a?(String) && expected.is_a?(String)

    begin
      JSON.parse(actual, max_nesting: false) == JSON.parse(expected, max_nesting: false)
    rescue StandardError
      actual == expected
    end
  end
end
