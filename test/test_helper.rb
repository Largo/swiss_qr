# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "swiss_qr"
require "json"

require "minitest/autorun"

# Fixture access and comparison helpers shared by the tests.
module FixtureHelper
  FIXTURES = File.expand_path("fixtures/payloads", __dir__)
  # Keys whose values are decimals, compared numerically.
  DECIMAL_KEYS = %w[amount rate discount].freeze

  module_function

  def fixture_names(kind)
    Dir[File.join(FIXTURES, kind, "*.txt")].map { |path| File.basename(path, ".txt") }.sort
  end

  # Payload files are byte-exact UTF-8 (line endings matter).
  def payload(kind, name)
    File.binread(File.join(FIXTURES, kind, "#{name}.txt")).force_encoding(Encoding::UTF_8)
  end

  def expected_json(kind, name)
    JSON.parse(File.read(File.join(FIXTURES, kind, "#{name}.json"), encoding: "UTF-8"))
  end

  # "[fatal] field|field: text" => [fatal?, ["field", ...], "text"]
  def reason(name)
    line = File.read(File.join(FIXTURES, "invalid", "#{name}.reason"), encoding: "UTF-8").strip
    fatal = line.start_with?("[fatal] ")
    fields, text = line.delete_prefix("[fatal] ").split(": ", 2)
    [fatal, fields.split("|"), text]
  end

  # Builds a 31-line LF payload from the SIX IG example 1 with some lines
  # (1-based line number => value) replaced.
  # Integer keys may also be given without braces (they arrive in +more+).
  def build_payload(overrides = {}, separator: "\n", extra: [], **more)
    lines = [
      "SPC", "0200", "1", "CH4431999123000889012",
      "S", "Max Muster & Söhne", "Musterstrasse", "123", "8000", "Seldwyla", "CH",
      "", "", "", "", "", "", "",
      "1949.75", "CHF",
      "S", "Simon Muster", "Musterstrasse", "1", "8000", "Seldwyla", "CH",
      "QRR", "210000000003139471430009017", "Order from 15.10.2020", "EPD"
    ]
    overrides.merge(more).each { |number, value| lines[number - 1] = value }
    (lines + extra).join(separator)
  end
end

module Minitest
  class Test
    include FixtureHelper

    # Asserts that +actual+ (Bill#as_json) contains everything in +expected+
    # (fixture JSON): keys starting with "_" are comments, decimals compare
    # numerically, expected warnings must be present (by field) while extra
    # warnings are allowed.
    def assert_fixture_match(expected, actual, path = "bill")
      case expected
      when Hash
        assert_kind_of Hash, actual, "#{path} should be a hash"
        expected.each do |key, value|
          next if key.start_with?("_")

          assert actual.key?(key), "#{path}.#{key} missing"
          assert_fixture_value(key, value, actual[key], "#{path}.#{key}")
        end
      when Array
        assert_kind_of Array, actual, "#{path} should be an array"
        assert_equal expected.size, actual.size, "#{path} size"
        expected.zip(actual).each_with_index { |(e, a), i| assert_fixture_match(e, a, "#{path}[#{i}]") }
      else
        expected.nil? ? assert_nil(actual, path) : assert_equal(expected, actual, path)
      end
    end

    def assert_fixture_value(key, expected, actual, path)
      if key == "warnings"
        missing = expected.map { |w| w["field"] } - actual.map { |w| w["field"] }
        assert_empty missing, "#{path}: expected warnings missing (got #{actual.inspect})"
      elsif DECIMAL_KEYS.include?(key) && expected.is_a?(String)
        refute_nil actual, path
        assert_equal BigDecimal(expected), BigDecimal(actual), path
      else
        assert_fixture_match(expected, actual, path)
      end
    end

    def assert_problem(problems, fields, message = nil)
      fields = Array(fields)
      assert problems.any? { |problem| fields.any? { |field| problem.about?(field) } },
             message || "expected a problem on #{fields.join(" or ")}, got #{problems.map(&:to_s).inspect}"
    end
  end
end
