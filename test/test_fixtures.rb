# frozen_string_literal: true

require "test_helper"

# Drives every payload fixture in test/fixtures/payloads (see its README).
class TestFixtures < Minitest::Test
  FixtureHelper.fixture_names("valid").each do |name|
    define_method(:"test_valid_#{name}") do
      text = payload("valid", name)
      bill = SwissQr.parse(text)

      assert_empty bill.errors
      assert_fixture_match expected_json("valid", name), bill.as_json
      assert_equal text, bill.raw
      assert SwissQr.valid?(text)
      assert SwissQr.looks_like_qr_bill?(text)
      assert_equal bill, SwissQr.parse(text, strict: false)
      JSON.parse(bill.to_json) # round-trips as JSON
    end
  end

  FixtureHelper.fixture_names("invalid").each do |name|
    define_method(:"test_invalid_#{name}") do
      text = payload("invalid", name)
      fatal, fields, = reason(name)

      error = assert_raises(SwissQr::InvalidPayload) { SwissQr.parse(text) }
      assert_problem error.errors, fields
      refute SwissQr.valid?(text)

      if fatal
        assert_nil error.bill
        assert_raises(SwissQr::InvalidPayload) { SwissQr.parse(text, strict: false) }
      else
        bill = SwissQr.parse(text, strict: false)
        refute_predicate bill, :valid?
        assert_problem bill.errors, fields
        assert_equal bill.errors, error.bill.errors
      end
    end
  end

  FixtureHelper.fixture_names("swico").each do |name|
    define_method(:"test_swico_#{name}") do
      text = payload("swico", name).chomp
      info = SwissQr::BillingInformation.parse(text)

      assert_fixture_match expected_json("swico", name), info.as_json
      assert_empty info.warnings
    end
  end

  def test_fixture_sets_are_not_empty
    assert_operator fixture_names("valid").size, :>=, 40
    assert_operator fixture_names("invalid").size, :>=, 50
    assert_operator fixture_names("swico").size, :>=, 10
  end

  def test_non_spc_fatal_fixtures_are_not_qr_bills
    %w[wrong_header not_a_qr_bill_url six_ig22_field_labels empty].each do |name|
      refute SwissQr.looks_like_qr_bill?(payload("invalid", name)), name
    end
  end
end
