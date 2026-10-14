# frozen_string_literal: true

require "test_helper"

class TestBillingInformation < Minitest::Test
  BillingInformation = SwissQr::BillingInformation

  def parse(text) = BillingInformation.parse(text)

  def test_full_example
    info = parse("//S1/10/10201409/11/190512/20/1400.000-53/30/106017086/31/180508/32/7.7/40/2:10;0:30")

    assert_equal "10201409", info.invoice_number
    assert_equal Date.new(2019, 5, 12), info.invoice_date
    assert_equal "1400.000-53", info.customer_reference
    assert_equal "106017086", info.vat_number
    assert_equal [Date.new(2018, 5, 8)], info.vat_dates
    assert_equal [BillingInformation::VatRate.new(rate: BigDecimal("7.7"), amount: nil)], info.vat_details
    assert_nil info.vat_import_taxes
    assert_equal [BigDecimal(2), BigDecimal(0)], info.payment_conditions.map(&:discount)
    assert_equal [10, 30], info.payment_conditions.map(&:days)
    assert_empty info.unknown_tags
    assert_empty info.warnings
  end

  def test_rate_lists_and_vat_period
    info = parse("//S1/10/10104/11/180228/30/395856455/31/180226180227/32/3.7:400.19;7.7:553.39;0:14/33/2.5:14.85/40/0:30")

    assert_equal [Date.new(2018, 2, 26), Date.new(2018, 2, 27)], info.vat_dates
    assert_equal([[BigDecimal("3.7"), BigDecimal("400.19")], [BigDecimal("7.7"), BigDecimal("553.39")],
                  [BigDecimal(0), BigDecimal(14)]], info.vat_details.map { |v| [v.rate, v.amount] })
    assert_equal [[BigDecimal("2.5"), BigDecimal("14.85")]], info.vat_import_taxes.map(&:deconstruct)
  end

  def test_escaping
    info = parse('//S1/10/X.66711\/8824/20/a\\\\b\/c')

    assert_equal "X.66711/8824", info.invoice_number
    assert_equal 'a\\b/c', info.customer_reference
    assert_empty info.warnings
  end

  def test_escaped_backslash_before_separator
    info = parse('//S1/10/abc\\\\/20/x')

    assert_equal "abc\\", info.invoice_number
    assert_equal "x", info.customer_reference
  end

  def test_unknown_backslash_sequence_is_kept
    assert_equal 'a\\xb', parse('//S1/10/a\\xb').invoice_number
  end

  def test_empty_tag_equals_omitted
    info = parse("//S1/10//11/200101")

    assert_nil info.invoice_number
    assert_equal Date.new(2020, 1, 1), info.invoice_date
    assert_empty info.warnings
  end

  def test_unknown_tag_is_kept_with_warning
    info = parse("//S1/10/1/50/future")

    assert_equal({ "50" => "future" }, info.unknown_tags)
    assert_problem info.warnings, :billing_information
  end

  def test_order_and_duplicate_warnings
    info = parse("//S1/20/b/10/a/10/again")

    assert_equal "a", info.invoice_number
    assert_equal "b", info.customer_reference
    messages = info.warnings.map(&:message)

    assert(messages.any? { |m| m.include?("ascending") })
    assert(messages.any? { |m| m.include?("more than once") })
  end

  def test_invalid_values_become_warnings_and_nil
    info = parse("//S1/11/201399/30/CHE-123.456.789/31/2001/32/x:y/33/1/40/2:ten")

    assert_nil info.invoice_date
    assert_equal "CHE-123.456.789", info.vat_number, "kept but warned"
    assert_nil info.vat_dates
    assert_nil info.vat_details
    assert_nil info.vat_import_taxes
    assert_nil info.payment_conditions
    assert_equal 6, info.warnings.size
    assert(info.warnings.all? { |w| w.field == :billing_information })
  end

  def test_non_tag_token_warns
    info = parse("//S1/abc/1")

    assert_problem info.warnings, :billing_information
  end

  def test_prefix_required
    assert_raises(ArgumentError) { parse("//XY/whatever") }
    assert BillingInformation.s1?("//S1/10/1")
    refute BillingInformation.s1?("//S2/10/1")
    refute BillingInformation.s1?(nil)
  end

  def test_value_object
    info = parse("//S1/10/1/11/200101/32/8.1:100/40/2:10")

    assert_predicate info, :frozen?
    assert_predicate info.vat_details, :frozen?
    refute_respond_to info, :invoice_number=

    hash = info.to_h

    assert_equal Date.new(2020, 1, 1), hash[:invoice_date]
    assert_equal({ rate: BigDecimal("8.1"), amount: BigDecimal(100) }, hash[:vat_details].first)
    assert_equal({ discount: BigDecimal(2), days: 10 }, hash[:payment_conditions].first)

    json = info.as_json

    assert_equal "2020-01-01", json["invoice_date"]
    assert_equal [{ "rate" => "8.1", "amount" => "100" }], json["vat_details"]
    assert_equal [{ "discount" => "2", "days" => 10 }], json["payment_conditions"]
    assert_equal "//S1/10/1/11/200101/32/8.1:100/40/2:10", json["raw"]
  end

  def test_bill_with_bad_swico_stays_valid
    text = build_payload({}, extra: ["//S1/11/999999/40/oops"])
    bill = SwissQr.parse(text)

    assert_predicate bill, :valid?
    assert_problem bill.warnings, :billing_information
    assert_nil bill.billing_information.invoice_date
  end

  def test_bill_with_non_s1_billing_information
    bill = SwissQr.parse(build_payload({}, extra: ["//XY/V1/order=4711"]))

    assert_equal "//XY/V1/order=4711", bill.raw_billing_information
    assert_nil bill.billing_information
    assert_empty bill.warnings

    bill = SwissQr.parse(build_payload({}, extra: ["free text"]))

    assert_problem bill.warnings, :billing_information
  end
end
