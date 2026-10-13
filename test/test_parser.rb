# frozen_string_literal: true

require "test_helper"

class TestParser < Minitest::Test
  def test_basic_fields
    bill = SwissQr.parse(build_payload)

    assert_equal "0200", bill.version
    assert_equal "1", bill.coding_type
    assert_equal "CH4431999123000889012", bill.account
    assert_predicate bill, :qr_iban?
    assert_equal :structured, bill.creditor.type
    assert_equal "Max Muster & Söhne", bill.creditor.name
    assert_equal "123", bill.creditor.building_number
    assert_nil bill.ultimate_creditor
    assert_equal BigDecimal("1949.75"), bill.amount
    assert_kind_of BigDecimal, bill.amount
    assert_equal "CHF", bill.currency
    assert_equal "Simon Muster", bill.debtor.name
    assert_equal :qrr, bill.reference_type
    assert_equal "210000000003139471430009017", bill.reference
    assert_equal "Order from 15.10.2020", bill.unstructured_message
    assert_equal "EPD", bill.trailer
    assert_nil bill.bill_information
    assert_nil bill.swico
    assert_empty bill.alternative_procedures
    assert_empty bill.errors
    assert_empty bill.warnings
  end

  # --- line endings -------------------------------------------------------

  def test_lf_and_crlf_give_the_same_bill
    lf = SwissQr.parse(build_payload)
    crlf = SwissQr.parse(build_payload({}, separator: "\r\n"))

    assert_equal lf.to_h.except(:raw), crlf.to_h.except(:raw)
  end

  def test_trailing_separators_and_empty_lines_are_tolerated
    ["\n", "\n\n\n", "\n  \n"].each do |tail|
      bill = SwissQr.parse(build_payload + tail)

      assert_predicate bill, :valid?, tail.inspect
      assert_empty bill.warnings, tail.inspect
    end
    assert_predicate SwissQr.parse("#{build_payload({}, separator: "\r\n")}\r\n\r\n"), :valid?
  end

  def test_trailing_empty_lines_after_alternative_procedures
    bill = SwissQr.parse(build_payload({}, extra: ["", "eBill/B/peter@sample.ch", "", ""]))

    assert_nil bill.bill_information
    assert_equal ["eBill/B/peter@sample.ch"], bill.alternative_procedures
  end

  def test_empty_billing_information_line_keeps_alternative_procedure_position
    bill = SwissQr.parse(build_payload({}, extra: ["", "AP1", "AP2"]))

    assert_nil bill.bill_information
    assert_equal %w[AP1 AP2], bill.alternative_procedures
  end

  def test_mixed_line_endings_are_an_error
    text = build_payload({}, separator: "\r\n").sub("\r\nCHF\r\n", "\nCHF\n")
    bill = SwissQr.parse(text, strict: false)

    assert_problem bill.errors, :payload
    assert_equal "CHF", bill.currency
  end

  def test_lone_cr_is_an_error
    text = build_payload.sub("Order from", "Order\rfrom")
    bill = SwissQr.parse(text, strict: false)

    assert_problem bill.errors, :payload
    assert_problem bill.errors, :unstructured_message
  end

  # --- strict / lenient ---------------------------------------------------

  def test_strict_raises_with_all_errors_and_partial_bill
    text = build_payload(4 => "CH4431999123000889013", 19 => "50", 20 => "USD")
    error = assert_raises(SwissQr::InvalidPayload) { SwissQr.parse(text) }

    assert_equal %i[account amount currency], error.errors.map(&:field)
    assert(error.errors.all?(SwissQr::Problem))
    assert_match(/\Ainvalid QR-bill payload: account: /, error.message)
    assert_kind_of SwissQr::Bill, error.bill
    assert_equal error.errors, error.bill.errors
    assert_kind_of SwissQr::Error, error
  end

  def test_lenient_returns_bill_with_errors
    bill = SwissQr.parse(build_payload(19 => "50", 28 => "SCOR"), strict: false)

    refute_predicate bill, :valid?
    assert_equal BigDecimal(50), bill.amount, "amount still parsed"
    assert_equal :scor, bill.reference_type
    assert_problem bill.errors, :amount
    assert_problem bill.errors, :reference_type
    assert_problem bill.errors, :reference
  end

  def test_lenient_still_raises_for_non_qr_bills
    ["", "https://example.com", "SPX\n0200", "SPC\n0200\n1\n"].each do |text|
      assert_raises(SwissQr::InvalidPayload, text.inspect) { SwissQr.parse(text, strict: false) }
    end
  end

  def test_lenient_unparseable_amount_is_nil
    bill = SwissQr.parse(build_payload(19 => "1'000.00"), strict: false)

    assert_nil bill.amount
    assert_problem bill.errors, :amount
  end

  def test_message_lists_more_errors
    text = build_payload(2 => "0100", 3 => "2", 4 => "", 20 => "", 31 => "EOD")
    error = assert_raises(SwissQr::InvalidPayload) { SwissQr.parse(text) }

    assert_match(/2 more\z/, error.message)
  end

  def test_type_error_for_non_strings
    assert_raises(TypeError) { SwissQr.parse(nil) }
    assert_raises(TypeError) { SwissQr.parse(42) }
    refute SwissQr.valid?(nil)
  end

  # --- predicates ---------------------------------------------------------

  def test_valid
    assert SwissQr.valid?(build_payload)
    refute SwissQr.valid?(build_payload(19 => "50"))
    refute SwissQr.valid?("hello")
    assert SwissQr.valid?(build_payload(5 => "K", 7 => "Musterstrasse 123", 8 => "8000 Seldwyla", 9 => "", 10 => "")),
           "K addresses only warn"
  end

  def test_qr_bill
    assert SwissQr.qr_bill?(build_payload)
    assert SwissQr.qr_bill?(build_payload({}, separator: "\r\n"))
    assert SwissQr.qr_bill?("#{SwissQr::Parser::BOM}#{build_payload}")
    assert SwissQr.qr_bill?(build_payload.b), "binary strings"
    assert SwissQr.qr_bill?("SPC\n0200\n1"), "cheap check only"
    refute SwissQr.qr_bill?("SPC")
    refute SwissQr.qr_bill?("SPC\nabcd\n")
    refute SwissQr.qr_bill?("https://example.com")
    refute SwissQr.qr_bill?(nil)
    refute SwissQr.qr_bill?(:SPC)
  end

  # --- encoding and character set -----------------------------------------

  def test_binary_input_is_read_as_utf8
    bill = SwissQr.parse(build_payload.b)

    assert_equal "Max Muster & Söhne", bill.creditor.name
    assert_equal Encoding::UTF_8, bill.creditor.name.encoding
  end

  def test_other_encodings_are_transcoded
    bill = SwissQr.parse(build_payload.encode(Encoding::ISO_8859_1))

    assert_equal "Max Muster & Söhne", bill.creditor.name
  end

  def test_invalid_utf8_is_an_error
    bill = SwissQr.parse(build_payload.b.sub("S\xC3\xB6hne".b, "S\xF6hne".b), strict: false)

    assert_problem bill.errors, :payload
  end

  def test_bom_is_stripped_with_warning
    bill = SwissQr.parse("#{SwissQr::Parser::BOM}#{build_payload}")

    assert_predicate bill, :valid?
    assert_problem bill.warnings, :payload
  end

  def test_extended_character_set
    %w[Ștefan Țară Łódź Œuvre €uro Straße].each do |name|
      assert SwissQr.valid?(build_payload(22 => name)), name
    end
    assert SwissQr.valid?(build_payload(22 => "Non breaking"))
  end

  def test_characters_outside_the_set
    {
      "Ж" => "Cyrillic", "̈" => "combining diaeresis", "\u0085" => "C1 control",
      "–" => "en dash", "\t" => "tab", "ƀ" => "Latin Extended-B"
    }.each do |char, label|
      bill = SwissQr.parse(build_payload(22 => "Simon#{char}Muster"), strict: false)

      assert_problem bill.errors, :"debtor.name", label
    end
  end

  def test_invalid_characters_in_status_a_lines_only_warn
    bill = SwissQr.parse(build_payload({}, extra: ["//S1/10/Ж", "AP – 1"]))

    assert_predicate bill, :valid?
    assert_problem bill.warnings, :bill_information
    assert_problem bill.warnings, :alternative_procedures
  end

  def test_whitespace_is_stripped_with_warning
    bill = SwissQr.parse(build_payload(23 => " Musterstrasse ", 30 => ""))

    assert_equal "Musterstrasse", bill.debtor.street
    assert_problem bill.warnings, :"debtor.street"
    assert_nil bill.unstructured_message
  end

  # --- account and references ---------------------------------------------

  def test_account_normalization
    bill = SwissQr.parse(build_payload(4 => "ch4431999123000889012"))

    assert_equal "CH4431999123000889012", bill.account
    assert_problem bill.warnings, :account

    bill = SwissQr.parse(build_payload(4 => "CH44 3199 9123 0008 8901 2"), strict: false)

    assert_equal "CH4431999123000889012", bill.account
    assert_problem bill.errors, :account
  end

  def test_account_problems
    {
      "DE89370400440532013000" => /only CH and LI/,
      "CH443199912300088901" => /21 characters/,
      "CH44319991230008890-2" => /letters and digits/,
      "CHAB31999123000889012" => /malformed/,
      "CH4431999123000889013" => /check digits/
    }.each do |account, message|
      bill = SwissQr.parse(build_payload(4 => account), strict: false)

      assert(bill.errors.any? { |p| p.field == :account && p.message.match?(message) }, account)
    end
  end

  def test_ordinary_iban_with_scor_and_non
    scor = SwissQr.parse(build_payload(4 => "CH5800791123000889012", 28 => "SCOR", 29 => "RF18539007547034"))

    refute_predicate scor, :qr_iban?
    assert_equal :scor, scor.reference_type
    assert_equal "RF18 5390 0754 7034", scor.formatted_reference

    non = SwissQr.parse(build_payload(4 => "CH5800791123000889012", 28 => "NON", 29 => ""))

    assert_equal :non, non.reference_type
    assert_nil non.reference
    assert_nil non.formatted_reference
  end

  def test_reference_problems
    {
      "21000000000313947143000 9017" => /spaces/,
      "2100000000031394714300090171" => /27 digits/,
      "21000000000313947143000901A" => /numeric/
    }.each do |reference, message|
      bill = SwissQr.parse(build_payload(29 => reference), strict: false)

      assert(bill.errors.any? { |p| p.field == :reference && p.message.match?(message) }, reference)
    end
    base = { 4 => "CH5800791123000889012", 28 => "SCOR" }
    {
      "" => /requires/, "RF18 5390 0754 7034" => /spaces/, "RF18-539007547034" => /letters and digits/,
      "RF18" => /5 to 25/, "XX18539007547034" => /start with/, "RF19539007547034" => /check digits/
    }.each do |reference, message|
      bill = SwissQr.parse(build_payload(base.merge(29 => reference)), strict: false)

      assert(bill.errors.any? { |p| p.field == :reference && p.message.match?(message) }, reference)
    end
  end

  def test_missing_reference_type
    bill = SwissQr.parse(build_payload(28 => ""), strict: false)

    assert_nil bill.reference_type
    assert_problem bill.errors, :reference_type
  end

  def test_qrr_in_eur_warns_about_the_coming_chf_only_rule
    bill = SwissQr.parse(build_payload(20 => "EUR"))

    assert_predicate bill, :valid?
    assert_problem bill.warnings, :currency
  end

  # --- amount -------------------------------------------------------------

  def test_amounts
    assert_equal BigDecimal("0.01"), SwissQr.parse(build_payload(19 => "0.01")).amount
    assert_equal BigDecimal("999999999.99"), SwissQr.parse(build_payload(19 => "999999999.99")).amount
    %w[50 50.0 050.00 50,00 -1.00 1'000.00 1000000000.00 .50 1e3].each do |amount|
      refute SwissQr.valid?(build_payload(19 => amount)), amount
    end
  end

  def test_open_amount
    bill = SwissQr.parse(build_payload(19 => ""))

    assert_nil bill.amount
    assert_predicate bill, :open_amount?
    assert_nil bill.formatted_amount
  end

  def test_notification
    bill = SwissQr.parse(build_payload(19 => "0.00", 30 => "DO NOT USE FOR PAYMENT"))

    assert_predicate bill, :notification?
    assert_empty bill.warnings

    bill = SwissQr.parse(build_payload(19 => "0.00"))

    assert_predicate bill, :notification?
    assert_problem bill.warnings, :amount
  end

  # --- addresses ----------------------------------------------------------

  def test_combined_address_is_parsed_with_warning
    bill = SwissQr.parse(build_payload(21 => "K", 23 => "Musterstrasse 1", 24 => "8000 Seldwyla", 25 => "", 26 => ""))
    debtor = bill.debtor

    assert_predicate debtor, :combined?
    assert_equal "Musterstrasse 1", debtor.address_line1
    assert_equal "8000 Seldwyla", debtor.address_line2
    assert_nil debtor.street
    assert_nil debtor.postal_code
    assert_equal ["Simon Muster", "Musterstrasse 1", "8000 Seldwyla"], debtor.lines
    assert_problem bill.warnings, :"debtor.type"
  end

  def test_combined_address_line2_may_be_70_characters
    bill = SwissQr.parse(build_payload(21 => "K", 23 => "Street 1", 24 => "x" * 70, 25 => "", 26 => ""))

    assert_predicate bill, :valid?
  end

  def test_structured_address_helpers
    address = SwissQr.parse(build_payload(27 => "DE")).debtor

    assert_predicate address, :structured?
    assert_equal ["Simon Muster", "Musterstrasse 1", "8000 Seldwyla", "DE"], address.lines
    assert_equal "Simon Muster\nMusterstrasse 1\n8000 Seldwyla\nDE", address.to_s
  end

  def test_house_number_in_street_is_tolerated
    assert SwissQr.valid?(build_payload(7 => "Musterstrasse 123", 8 => ""))
  end

  def test_debtor_is_optional_but_complete_when_given
    bill = SwissQr.parse(build_payload(21 => "", 22 => "", 23 => "", 24 => "", 25 => "", 26 => "", 27 => ""))

    assert_nil bill.debtor

    bill = SwissQr.parse(build_payload(21 => "", 22 => "", 23 => "", 24 => "", 25 => "", 26 => "", 27 => "CH"),
                         strict: false)

    assert_equal %i[debtor.type debtor.name debtor.postal_code debtor.town], bill.errors.map(&:field)
  end

  def test_address_field_rules
    {
      { 11 => "ch" } => %i[warnings creditor.country],
      { 9 => "CH-8000" } => %i[warnings creditor.postal_code],
      { 6 => "x" * 71 } => %i[errors creditor.name],
      { 7 => "x" * 71 } => %i[errors creditor.street],
      { 9 => "1" * 17 } => %i[errors creditor.postal_code],
      { 10 => "" } => %i[errors creditor.town],
      { 11 => "" } => %i[errors creditor.country],
      { 5 => "" } => %i[errors creditor.type],
      { 21 => "X" } => %i[errors debtor.type],
      { 5 => "K", 7 => "Street 1", 8 => "", 9 => "", 10 => "" } => %i[errors creditor.address_line2],
      { 5 => "K", 7 => "Street 1", 8 => "8000 Bern", 9 => "", 10 => "Bern" } => %i[errors creditor.town]
    }.each do |overrides, (kind, field)|
      bill = SwissQr.parse(build_payload(overrides), strict: false)

      assert_problem bill.public_send(kind), field, "#{overrides} should give #{kind} on #{field}"
    end
  end

  def test_ultimate_creditor_is_parsed_but_an_error
    bill = SwissQr.parse(build_payload(12 => "S", 13 => "Ultimate AG", 16 => "8000", 17 => "Zürich", 18 => "CH"),
                         strict: false)

    assert_equal "Ultimate AG", bill.ultimate_creditor.name
    assert_equal [:ultimate_creditor], bill.errors.map(&:field)
  end

  # --- message, billing information, alternative procedures -------------

  def test_message_and_billing_information_share_140_characters
    assert SwissQr.valid?(build_payload({ 30 => "m" * 100 }, extra: ["//S1/10/#{"1" * 32}"]))
    refute SwissQr.valid?(build_payload({ 30 => "m" * 100 }, extra: ["//S1/10/#{"1" * 33}"]))
    refute SwissQr.valid?(build_payload({ 30 => "" }, extra: ["//S1/10/#{"1" * 133}"]))
  end

  def test_alternative_procedures
    bill = SwissQr.parse(build_payload({}, extra: ["", "eBill/B/a@b.ch", "x" * 101]))

    assert_predicate bill, :valid?
    assert_equal 2, bill.alternative_procedures.size
    assert_problem bill.warnings, :alternative_procedures

    bill = SwissQr.parse(build_payload({}, extra: ["", "", "AP2"]))

    assert_equal ["AP2"], bill.alternative_procedures
    assert_problem bill.warnings, :alternative_procedures
  end

  def test_more_than_34_lines
    bill = SwissQr.parse(build_payload({}, extra: ["", "AP1", "AP2", "AP3"]), strict: false)

    assert_equal %w[AP1 AP2], bill.alternative_procedures
    assert_equal [:payload], bill.errors.map(&:field)
  end

  def test_payload_size_limit
    # The field limits cap a valid payload at about 870 characters, so only
    # an over-long field can push it beyond 997.
    longest = build_payload({ 6 => "n" * 70, 7 => "s" * 70, 22 => "n" * 70, 23 => "s" * 70, 30 => "m" * 140 },
                            extra: ["", "a" * 100, "b" * 100])

    assert SwissQr.valid?(longest)
    assert_problem SwissQr.parse(build_payload(30 => "m" * 900), strict: false).errors, :payload
    refute_problem_on_payload SwissQr.parse(build_payload(30 => "m" * 141), strict: false)
  end

  def refute_problem_on_payload(bill)
    refute(bill.errors.any? { |p| p.field == :payload }, bill.errors.map(&:to_s).inspect)
  end

  def test_wrong_trailer_shifted_lines
    text = build_payload.sub("Musterstrasse\n123", "Musterstrasse\nextra\n123")
    bill = SwissQr.parse(text, strict: false)

    assert_problem bill.errors, :trailer
  end

  # --- value objects ------------------------------------------------------

  def test_bill_is_immutable
    bill = SwissQr.parse(build_payload({}, extra: ["", "AP1"]))

    assert_predicate bill, :frozen?
    assert_predicate bill.alternative_procedures, :frozen?
    assert_predicate bill.errors, :frozen?
    assert_predicate bill.raw, :frozen?
    refute_respond_to bill, :amount=
    assert_raises(FrozenError) { bill.alternative_procedures << "x" }
    changed = bill.with(currency: "EUR")

    assert_equal "EUR", changed.currency
    assert_equal "CHF", bill.currency
  end

  def test_to_h_keeps_ruby_types
    hash = SwissQr.parse(build_payload({}, extra: ["//S1/11/200101"])).to_h

    assert_equal BigDecimal("1949.75"), hash[:amount]
    assert_equal :qrr, hash[:reference_type]
    assert_equal :structured, hash[:creditor][:type]
    assert_equal Date.new(2020, 1, 1), hash[:swico][:invoice_date]
    assert_equal %i[version coding_type account qr_iban creditor ultimate_creditor amount currency debtor
                    reference_type reference unstructured_message trailer bill_information swico
                    alternative_procedures errors warnings raw], hash.keys
  end

  def test_as_json_and_to_json
    bill = SwissQr.parse(build_payload(19 => "50.00", 21 => "K", 23 => "Musterstrasse 1", 24 => "8000 Seldwyla",
                                       25 => "", 26 => ""))
    json = bill.as_json

    assert_equal "50.00", json["amount"]
    assert_equal "qrr", json["reference_type"]
    assert_equal "combined", json["debtor"]["type"]
    assert_equal [{ "field" => "debtor.type", "message" => bill.warnings.first.message }], json["warnings"]
    assert_equal json, JSON.parse(bill.to_json)
    assert_equal json, JSON.parse(JSON.generate(json))
  end

  def test_display_helpers
    bill = SwissQr.parse(build_payload(19 => "1949.70"))

    assert_equal "CH44 3199 9123 0008 8901 2", bill.formatted_account
    assert_equal "21 00000 00003 13947 14300 09017", bill.formatted_reference
    assert_equal "1949.70", bill.formatted_amount
    assert_equal "999999999.99", SwissQr::Bill.amount_string(BigDecimal("999999999.99"))
    assert_equal "0.00", SwissQr::Bill.amount_string(BigDecimal(0))
  end

  def test_problem
    problem = SwissQr::Problem.new(field: "creditor.name", message: "name is mandatory")

    assert_equal :"creditor.name", problem.field
    assert_equal "creditor.name: name is mandatory", problem.to_s
    assert problem.about?(:creditor)
    assert problem.about?("creditor.name")
    refute problem.about?(:cred)
    refute problem.about?(:debtor)
  end
end
