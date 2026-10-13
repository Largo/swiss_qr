# frozen_string_literal: true

# Data-table style script: long verbatim payload lines and long builder
# methods are deliberate here.
# rubocop:disable Metrics, Layout/LineLength, Style/FormatStringToken, Style/StringConcatenation, Style/FormatString

# Dev-only generator for the swiss_qr test fixtures. It is NOT part of the gem
# (test/ is excluded from spec.files) and is never loaded by the test suite.
#
# Usage, from the repository root:
#
#   bundle exec ruby test/fixtures/generate.rb            # payloads + images
#   bundle exec ruby test/fixtures/generate.rb --no-images
#
# What it writes (everything below test/fixtures/ is regenerated, so edit this
# file rather than the fixtures):
#
#   payloads/valid/NAME.txt     raw QR payload, written byte for byte
#   payloads/valid/NAME.json    expected parse result (see README.md)
#   payloads/invalid/NAME.txt   raw payload that must not validate
#   payloads/invalid/NAME.reason  one line: "[fatal] field[|field]: explanation"
#   payloads/swico/NAME.txt     a "Billing information" line (Swico/SIX S1)
#   payloads/swico/NAME.json    expected SwissQr::BillInformation#to_h
#   images/*.png, images/*.pdf  QR codes rendered with rqrcode (ECC level M),
#                               each verified by decoding it with QrReader
#   images/expected.json        image file => payload fixture names it contains
#
# Check digits (IBAN mod 97-10, QR reference mod 10 recursive, ISO 11649
# creditor reference) are computed here; every valid fixture is re-verified
# before it is written, and every "official" fixture is rebuilt from its field
# list and compared byte for byte with the payload decoded from SIX's own
# sample QR codes (see images/SOURCES.md).

require "json"
require "fileutils"
require "zlib"

module FixtureGen
  ROOT = __dir__
  CRLF = "\r\n"
  LF = "\n"

  # --- check digits ---------------------------------------------------------

  module CheckDigits
    module_function

    def numeric(str) = str.upcase.chars.map { |c| c.match?(/\d/) ? c : (c.ord - 55).to_s }.join

    def mod97(str) = numeric(str).to_i % 97

    def iban(country, bban) = format("%<c>s%<d>02d%<b>s", c: country, d: 98 - mod97(bban + country + "00"), b: bban)

    def iban_valid?(iban) = iban.match?(/\A[A-Z]{2}\d{2}[A-Z0-9]{1,30}\z/) && mod97(iban[4..] + iban[0, 4]) == 1

    def qr_iban?(iban) = %w[CH LI].include?(iban[0, 2]) && (30_000..31_999).cover?(iban[4, 5].to_i)

    MOD10 = [0, 9, 4, 6, 8, 2, 7, 1, 3, 5].freeze

    def mod10_recursive(digits) = (10 - digits.each_char.reduce(0) { |carry, d| MOD10[(carry + d.to_i) % 10] }) % 10

    def qrr(body26)
      raise ArgumentError, "QRR body must be 26 digits: #{body26}" unless body26.match?(/\A\d{26}\z/)

      body26 + mod10_recursive(body26).to_s
    end

    def qrr_valid?(ref) = ref.match?(/\A\d{27}\z/) && mod10_recursive(ref[0, 26]) == ref[26].to_i

    def scor(body) = format("RF%<d>02d%<b>s", d: 98 - mod97(body + "RF00"), b: body)

    def scor_valid?(ref)
      ref = ref.upcase # IG 4.2.2: references are case-insensitive
      ref.match?(/\ARF\d{2}[A-Z0-9]{1,21}\z/) && mod97(ref[4..] + ref[0, 4]) == 1
    end
  end
  CD = CheckDigits

  # --- shared sample data ---------------------------------------------------

  # Bank account numbers below are fictitious; the IIDs only steer the
  # QR-IBAN detection (QR-IID range 30000-31999).
  IBAN_CH = CD.iban("CH", "00762" + "011623852957")          # ordinary IBAN
  IBAN_CH2 = CD.iban("CH", "08390" + "0350A1234567")         # ordinary IBAN, alphanumeric account
  QRIBAN_CH = CD.iban("CH", "30808" + "001234567890")        # QR-IBAN
  QRIBAN_CH2 = CD.iban("CH", "31999" + "000000004711")       # QR-IBAN, upper end of the QR-IID range
  IBAN_LI = "LI21088100002324013AA"                           # ECBS/SWIFT registry example IBAN
  QRIBAN_LI = CD.iban("LI", "30123" + "0000ABCD1234")         # LI QR-IBAN
  IBAN_LV = "LV80BANK0000435195001"                           # valid 21-char IBAN, but not CH/LI

  QRR1 = CD.qrr("11041990000000000000202610")
  QRR2 = CD.qrr("00000000000000000000004711")
  QRR3 = CD.qrr("30000000000000123456789012")
  SCOR1 = CD.scor("INV2026101401")
  SCOR2 = CD.scor("A1")
  SCOR_MIN = CD.scor("7")                                     # 5 characters, the minimum
  SCOR_MAX = CD.scor("ABCDEFGHIJKLMNOPQRS12")                 # 25 characters, the maximum

  def self.s_addr(name, street, number, postal_code, town, country)
    { type: "S", name: name, street: street, building_number: number,
      postal_code: postal_code, town: town, country: country }
  end

  def self.k_addr(name, line1, line2, country)
    { type: "K", name: name, address_line1: line1, address_line2: line2, country: country }
  end

  MUSTER_SOEHNE = s_addr("Max Muster & Söhne", "Musterstrasse", "123", "8000", "Seldwyla", "CH")
  SIMON_MUSTER = s_addr("Simon Muster", "Musterstrasse", "1", "8000", "Seldwyla", "CH")
  # The style guide / introduction script QR codes carry a trailing blank here.
  SIMON_MUSTER_SP = s_addr("Simon Muster", "Musterstrasse ", "1", "8000", "Seldwyla", "CH")
  SARAH_BEISPIEL = s_addr("Sarah Beispiel", "Musterstrasse", "1", "8000", "Seldwyla", "CH")
  ELEKTRO = s_addr("Elektro Muster AG", "Bahnhofstrasse", "17", "8001", "Zürich", "CH")
  RUTSCHMANN = s_addr("Pia-Maria Rutschmann-Schnyder", "Grosse Marktgasse", "28", "9400", "Rorschach", "CH")
  VERLAG = s_addr("Verlag Beispiel GmbH", "Steinentorstrasse", "8", "4051", "Basel", "CH")
  LOERRACH = s_addr("Anna Schmid", "Hauptstrasse", "42", "79539", "Lörrach", "DE")
  VADUZ = s_addr("Treuhand Muster Anstalt", "Städtle", "5", "9490", "Vaduz", "LI")
  VEREIN = s_addr("Turnverein Seldwyla", "Postfach", nil, "8000", "Seldwyla", "CH")

  # --- Swico / SIX S1 billing information -----------------------------------

  def self.swico(**fields)
    { invoice_number: nil, invoice_date: nil, customer_reference: nil, vat_number: nil,
      vat_dates: nil, vat_details: nil, vat_import_taxes: nil, payment_conditions: nil }.merge(fields)
  end

  def self.rates(*pairs) = pairs.map { |rate, amount| { rate: rate, amount: amount } }
  def self.conditions(*pairs) = pairs.map { |discount, days| { discount: discount, days: days } }

  SWICO = {
    # SIX IG v2.4, Annex A example 2 (also the QR code on that page)
    ig_example2: ["//S1/10/1234/11/201021/30/102673386/32/7.7/40/0:30",
                  swico(invoice_number: "1234", invoice_date: "2020-10-21", vat_number: "102673386",
                        vat_details: rates(["7.7", nil]), payment_conditions: conditions(["0", 30]))],
    # SIX style guide / introduction script sample QR codes
    style_guide: ["//S1/10/10201409/11/170309/20/14000000/30/106017086",
                  swico(invoice_number: "10201409", invoice_date: "2017-03-09",
                        customer_reference: "14000000", vat_number: "106017086")],
    # SIX IG v2.4 figure 1 (p. 11): every S1 tag except /33/ list form
    ig_figure1: ["//S1/10/10201409/11/200701/20/140.000-53/30/102673831/31/200615/32/7.7/33/7.7:139.40/40/0:30",
                 swico(invoice_number: "10201409", invoice_date: "2020-07-01", customer_reference: "140.000-53",
                       vat_number: "102673831", vat_dates: ["2020-06-15"], vat_details: rates(["7.7", nil]),
                       vat_import_taxes: rates(%w[7.7 139.40]), payment_conditions: conditions(["0", 30]))],
    style_guide_vat_date: ["//S1/10/10201409/11/170309/20/14000000/30/106017086/31/210122",
                           swico(invoice_number: "10201409", invoice_date: "2017-03-09",
                                 customer_reference: "14000000", vat_number: "106017086",
                                 vat_dates: ["2021-01-22"])],
    # SIX IG v2.4, Annex D, table 31, examples 1-4 (verbatim)
    annex_d_example1: ["//S1/10/10201409/11/190512/20/1400.000-53/30/106017086/31/180508/32/7.7/40/2:10;0:30",
                       swico(invoice_number: "10201409", invoice_date: "2019-05-12",
                             customer_reference: "1400.000-53", vat_number: "106017086",
                             vat_dates: ["2018-05-08"], vat_details: rates(["7.7", nil]),
                             payment_conditions: conditions(["2", 10], ["0", 30]))],
    annex_d_example2: ["//S1/10/10104/11/180228/30/395856455/31/180226180227/32/3.7:400.19;7.7:553.39;0:14/40/0:30",
                       swico(invoice_number: "10104", invoice_date: "2018-02-28", vat_number: "395856455",
                             vat_dates: %w[2018-02-26 2018-02-27],
                             vat_details: rates(%w[3.7 400.19], %w[7.7 553.39], %w[0 14]),
                             payment_conditions: conditions(["0", 30]))],
    annex_d_example3: ["//S1/10/4031202511/11/180107/20/61257233.4/30/105493567/32/8:49.82/33/2.5:14.85/40/0:30",
                       swico(invoice_number: "4031202511", invoice_date: "2018-01-07",
                             customer_reference: "61257233.4", vat_number: "105493567",
                             vat_details: rates(%w[8 49.82]), vat_import_taxes: rates(%w[2.5 14.85]),
                             payment_conditions: conditions(["0", 30]))],
    annex_d_example4: ["//S1/10/X.66711\\/8824/11/200712/20/MW-2020-04/30/107978798/32/2.5:117.22/40/3:5;1.5:20;1:40;0:60",
                       swico(invoice_number: "X.66711/8824", invoice_date: "2020-07-12",
                             customer_reference: "MW-2020-04", vat_number: "107978798",
                             vat_details: rates(%w[2.5 117.22]),
                             payment_conditions: conditions(["3", 5], ["1.5", 20], ["1", 40], ["0", 60]))],
    # hand-built: every tag, escaped backslash and slash, current Swiss VAT rates
    all_tags_escaped: ["//S1/10/R\\\\2026\\/77/11/261014/20/Kd. 4711/30/123456789/31/260101261231" \
                       "/32/8.1:100;2.6:50/33/8.1:12.50/40/2:10;0:30",
                       swico(invoice_number: "R\\2026/77", invoice_date: "2026-10-14",
                             customer_reference: "Kd. 4711", vat_number: "123456789",
                             vat_dates: %w[2026-01-01 2026-12-31],
                             vat_details: rates(%w[8.1 100], %w[2.6 50]),
                             vat_import_taxes: rates(%w[8.1 12.50]),
                             payment_conditions: conditions(["2", 10], ["0", 30]))],
    # hand-built: only invoice number and payment terms
    minimal: ["//S1/10/2026-0815/40/0:30",
              swico(invoice_number: "2026-0815", payment_conditions: conditions(["0", 30]))]
  }.freeze

  # --- payload builder ------------------------------------------------------

  ADDRESS_KEYS_S = %i[name street building_number postal_code town].freeze

  def self.address_lines(addr)
    return Array.new(7, "") if addr.nil?
    return addr if addr.is_a?(Array) # raw lines for invalid fixtures

    if addr[:type] == "K"
      [addr[:type], addr[:name], addr[:address_line1], addr[:address_line2], "", "", addr[:country]].map(&:to_s)
    else
      [addr[:type], *ADDRESS_KEYS_S.map { |k| addr[k] }, addr[:country]].map(&:to_s)
    end
  end

  # spec keys: account, creditor, ultimate_creditor, amount, currency, debtor,
  # reference_type, reference, message, bill_information,
  # alternative_procedures, eol, final_eol, trailing_blank_lines,
  # qr_type, version, coding_type, trailer, mutate (lambda on the line array)
  def self.lines(spec)
    lines = [spec.fetch(:qr_type, "SPC"), spec.fetch(:version, "0200"), spec.fetch(:coding_type, "1"),
             spec.fetch(:account),
             *address_lines(spec.fetch(:creditor)),
             *address_lines(spec[:ultimate_creditor]),
             spec[:amount].to_s, spec.fetch(:currency, "CHF"),
             *address_lines(spec[:debtor]),
             spec.fetch(:reference_type), spec[:reference].to_s, spec[:message].to_s,
             spec.fetch(:trailer, "EPD")]
    avs = spec.fetch(:alternative_procedures, [])
    if avs.any? || spec.key?(:bill_information)
      lines << spec[:bill_information].to_s
      lines.concat(avs)
    end
    spec[:mutate] ? spec[:mutate].call(lines) : lines
  end

  def self.build(spec)
    eol = spec.fetch(:eol, CRLF)
    out = lines(spec).join(eol)
    out += eol if spec[:final_eol] || spec[:trailing_blank_lines].to_i.positive?
    out += eol * spec[:trailing_blank_lines].to_i
    out
  end

  # --- expected result ------------------------------------------------------

  def self.blank_to_nil(value)
    return nil if value.nil?

    stripped = value.strip
    stripped.empty? ? nil : stripped
  end

  def self.address_json(addr)
    return nil if addr.nil?

    combined = addr[:type] == "K"
    {
      "type" => combined ? "combined" : "structured",
      "name" => blank_to_nil(addr[:name]),
      "street" => combined ? nil : blank_to_nil(addr[:street]),
      "building_number" => combined ? nil : blank_to_nil(addr[:building_number]),
      "postal_code" => combined ? nil : blank_to_nil(addr[:postal_code]),
      "town" => combined ? nil : blank_to_nil(addr[:town]),
      "address_line1" => combined ? blank_to_nil(addr[:address_line1]) : nil,
      "address_line2" => combined ? blank_to_nil(addr[:address_line2]) : nil,
      "country" => blank_to_nil(addr[:country])
    }
  end

  def self.swico_json(spec)
    info = spec[:bill_information]
    return nil unless info&.start_with?("//S1/")

    entry = SWICO.values.find { |raw, _| raw == info } or raise "no expected Swico data for #{info.inspect}"
    deep_stringify(entry[1])
  end

  def self.deep_stringify(obj)
    case obj
    when Hash then obj.to_h { |k, v| [k.to_s, deep_stringify(v)] }
    when Array then obj.map { |v| deep_stringify(v) }
    else obj
    end
  end

  def self.expected(spec, source: nil)
    account = spec.fetch(:account).delete(" ").upcase
    warnings = Array(spec[:warnings]).map { |f| { "field" => f } }
    {
      **(source ? { "_source" => source } : {}),
      **(spec[:note] ? { "_note" => spec[:note] } : {}),
      "version" => spec.fetch(:version, "0200"),
      "coding_type" => spec.fetch(:coding_type, "1"),
      "account" => account,
      "qr_iban" => CD.qr_iban?(account),
      "creditor" => address_json(spec[:creditor]),
      "ultimate_creditor" => nil,
      "amount" => blank_to_nil(spec[:amount]),
      "currency" => spec.fetch(:currency, "CHF"),
      "debtor" => address_json(spec[:debtor]),
      "reference_type" => spec.fetch(:reference_type).downcase,
      "reference" => blank_to_nil(spec[:reference]),
      "unstructured_message" => blank_to_nil(spec[:message]),
      "trailer" => "EPD",
      "bill_information" => blank_to_nil(spec[:bill_information]),
      "swico" => swico_json(spec),
      "alternative_procedures" => spec.fetch(:alternative_procedures, []),
      "errors" => [],
      "warnings" => warnings
    }
  end

  # Sanity checks on fixtures declared valid, so a typo in this file cannot
  # silently produce a "valid" fixture that is not.
  def self.assert_valid!(name, spec)
    payload = build(spec)
    account = spec[:account]
    fail_with = ->(msg) { raise "valid fixture #{name}: #{msg}" }
    fail_with.call("IBAN check digits") unless CD.iban_valid?(account)
    fail_with.call("not CH/LI") unless %w[CH LI].include?(account[0, 2]) && account.size == 21
    case spec[:reference_type]
    when "QRR"
      fail_with.call("QRR needs QR-IBAN") unless CD.qr_iban?(account)
      fail_with.call("QRR check digit") unless CD.qrr_valid?(spec[:reference])
      fail_with.call("QRR all zeros") if spec[:reference].match?(/\A0+\z/)
    when "SCOR"
      fail_with.call("SCOR needs IBAN") if CD.qr_iban?(account)
      fail_with.call("SCOR check digits") unless CD.scor_valid?(spec[:reference]) && spec[:reference].size.between?(5,
                                                                                                                    25)
    when "NON"
      fail_with.call("NON needs IBAN") if CD.qr_iban?(account)
      fail_with.call("NON with reference") unless spec[:reference].to_s.empty?
    end
    if ((amount = spec[:amount].to_s) != "") && !amount.match?(/\A(0|[1-9]\d{0,8})\.\d\d\z/)
      fail_with.call("amount format #{amount}")
    end
    fail_with.call("currency") unless %w[CHF EUR].include?(spec.fetch(:currency, "CHF"))
    fail_with.call("message+billing > 140") if spec[:message].to_s.size + spec[:bill_information].to_s.size > 140
    fail_with.call("> 2 alternative procedures") if spec.fetch(:alternative_procedures, []).size > 2
    if spec.fetch(:alternative_procedures, []).any? { |a| a.size > 100 } && !Array(spec[:warnings]).include?("alternative_procedures")
      fail_with.call("alternative procedure > 100")
    end
    fail_with.call("payload > 997 chars") if payload.size > 997
    [spec[:creditor], spec[:debtor]].compact.each do |a|
      fail_with.call("name > 70") if a[:name].to_s.size > 70
      next if a[:type] == "K"

      fail_with.call("street > 70") if a[:street].to_s.size > 70
      fail_with.call("building number > 16") if a[:building_number].to_s.size > 16
      fail_with.call("postal code > 16") if a[:postal_code].to_s.size > 16
      fail_with.call("town > 35") if a[:town].to_s.size > 35
    end
    allowed = /\A[ -~ -ÿĀ-ſȘ-ț€\r\n]*\z/
    fail_with.call("character outside the permitted set") unless payload.match?(allowed)
    payload
  end

  # --- official SIX samples (decoded from SIX's own QR codes) ---------------

  # Each entry: name, field spec, verbatim payload as decoded, source note.
  OFFICIAL = [
    ["six_ig_ex1_qrr",
     { account: "CH6431961000004421557", creditor: MUSTER_SOEHNE, amount: "50.00", debtor: SIMON_MUSTER,
       reference_type: "QRR", reference: "000008207791225857421286694", message: "Payment of travel",
       eol: CRLF, final_eol: true },
     "SIX IG QR-bill v2.4 (2026-02-24) Annex A example 1, QR code on p. 50; identical in style guide pp. 14/25"],
    ["six_ig_ex2_qrr_swico_two_alt_procedures",
     { account: "CH4431999123000889012", creditor: MUSTER_SOEHNE, amount: "1949.75", debtor: SIMON_MUSTER,
       reference_type: "QRR", reference: "210000000003139471430009017", message: "Order from 15.10.2020",
       bill_information: SWICO[:ig_example2][0],
       alternative_procedures: ["Name AV1: UV;UltraPay005;12345", "Name AV2: XY;XYService;54321"], eol: CRLF },
     "SIX IG QR-bill v2.4 Annex A example 2, QR code on p. 52"],
    ["six_ig_ex3_non_no_amount_no_debtor",
     { account: "CH5204835012345671000",
       creditor: s_addr("Sample Foundation", "PO Box", "", "3001", "Bern", "CH"),
       reference_type: "NON", eol: LF, final_eol: true },
     "SIX IG QR-bill v2.4 Annex A example 3, QR code on p. 53 (the table beside it differs: " \
     "'Muster Stiftung (sample foundation)', 'P.O. box')"],
    ["six_ig_ex4_scor",
     { account: "CH5800791123000889012",
       creditor: s_addr("Muster Krankenkasse", "Musterstrasse", "12", "8000", "Seldwyla", "CH"),
       amount: "211.00", debtor: SARAH_BEISPIEL, reference_type: "SCOR", reference: "RF240191230100405JSH0438",
       eol: LF, final_eol: true },
     "SIX IG QR-bill v2.4 Annex A example 4, QR code on p. 55 (the printed table/payment part show " \
     "RF72..., which has wrong check digits; see invalid/six_ig_ex4_table_scor_typo)"],
    ["six_ig_ex5_creditor_li",
     { account: "CH5800791123000889012",
       creditor: s_addr("Max Muster & Söhne", "Musterstrasse", "123", "9490", "Vaduz", "LI"),
       amount: "199.95", debtor: SARAH_BEISPIEL, reference_type: "SCOR", reference: "RF18539007547034",
       eol: LF, final_eol: true },
     "SIX IG QR-bill v2.4 Annex A example 5, QR code on p. 56"],
    ["six_ig_ex6_debtor_de",
     { account: "CH5800791123000889012", creditor: MUSTER_SOEHNE, amount: "199.95",
       debtor: s_addr("Sarah Beispiel", "Musterstrasse", "1", "78462", "Konstanz", "DE"),
       reference_type: "SCOR", reference: "RF18539007547034", eol: LF, final_eol: true },
     "SIX IG QR-bill v2.4 Annex A example 6, QR code on p. 58"],
    ["six_ig_notification_do_not_use",
     { account: "CH4431999123000889012", creditor: MUSTER_SOEHNE, amount: "0.00", debtor: SIMON_MUSTER,
       reference_type: "QRR", reference: "210000000003139471430009017", message: "DO NOT USE FOR PAYMENT",
       eol: LF, final_eol: true },
     "SIX IG QR-bill v2.4 ch. 4.4 'DO NOT USE FOR PAYMENT' (amount 0.00 is required there), QR code on p. 42"],
    ["six_ig_non_with_amount",
     { account: "CH5204835012345671000", creditor: MUSTER_SOEHNE, amount: "420.00",
       debtor: s_addr("Barbara Beispiel", "Musterstrasse", "1", "8000", "Seldwyla", "CH"),
       reference_type: "NON", eol: CRLF },
     "SIX IG QR-bill v2.4 figures 3 and 14, QR codes on pp. 15 and 48"],
    ["six_ig_fig1_qrr_full_swico",
     { account: "CH4431999123000889012",
       creditor: s_addr("Robert Schneider AG", "Rue du Lac", "1268", "2501", "Biel", "CH"),
       amount: "1949.75", debtor: RUTSCHMANN, reference_type: "QRR", reference: "210000000003139471430009017",
       message: "Auftrag vom 15.06.2020", bill_information: SWICO[:ig_figure1][0],
       alternative_procedures: ["Name AV1: UV;UltraPay005;12345", "Name AV2: XY;XYService;54321"], eol: LF },
     "SIX IG QR-bill v2.4 figure 1, QR code on p. 11"],
    ["six_ig_online_non_message",
     { account: "CH5204835012345671000", creditor: MUSTER_SOEHNE, amount: "50.00", debtor: SARAH_BEISPIEL,
       reference_type: "NON", message: "payment of the trip", eol: CRLF },
     "SIX IG QR-bill v2.4 ch. 3.8.4 figure 10 (online display), QR code on p. 29"],
    ["six_ap_ebill",
     { account: "CH4431999123000889012", creditor: MUSTER_SOEHNE, amount: "1949.75", debtor: SIMON_MUSTER,
       reference_type: "QRR", reference: "210000000003139471430009017", message: "Auftrag vom 15.10.2020",
       bill_information: SWICO[:ig_example2][0], alternative_procedures: ["eBill/B/simon.muster@example.com"],
       eol: CRLF },
     "SIX 'Alternative procedures' document (EN), figure 1, QR code on p. 11"],
    ["six_sg_qrr_empty_billing_two_alt_procedures",
     { account: "CH4431999123000889012", creditor: MUSTER_SOEHNE, amount: "2500.25", debtor: SIMON_MUSTER_SP,
       reference_type: "QRR", reference: "210000000003139471430009017", bill_information: "",
       alternative_procedures: ["Name AV1: UV;UltraPay005;12345", "Name AV2: XY;XYService;54321"], eol: CRLF },
     "SIX Style Guide QR-bill (2026-01) pp. 9/13/16/18/26/27/29 and introduction script p. 7 " \
     "(debtor street has a trailing blank)"],
    ["six_sg_qrr_swico",
     { account: "CH4431999123000889012", creditor: MUSTER_SOEHNE, amount: "1949.75", debtor: SIMON_MUSTER_SP,
       reference_type: "QRR", reference: "210000000003139471430009017", message: "Auftrag vom 15.06.2020",
       bill_information: SWICO[:style_guide][0],
       alternative_procedures: ["Name AV1: UV;UltraPay005;12345", "Name AV2: XY;XYService;54321"], eol: CRLF },
     "SIX Style Guide QR-bill pp. 15/19; introduction script pp. 5/10/12/16"],
    ["six_sg_scor_two_alt_procedures",
     { account: "CH5800791123000889012", creditor: MUSTER_SOEHNE, amount: "2500.25", debtor: SIMON_MUSTER_SP,
       reference_type: "SCOR", reference: "RF18539007547034", bill_information: "",
       alternative_procedures: ["Name AV1: UV;UltraPay005;12345", "Name AV2: XY;XYService;54321"], eol: CRLF },
     "SIX Style Guide QR-bill p. 20"],
    ["six_sg_scor_swico",
     { account: "CH5800791123000889012", creditor: MUSTER_SOEHNE, amount: "1949.75", debtor: SIMON_MUSTER_SP,
       reference_type: "SCOR", reference: "RF18539007547034", bill_information: SWICO[:style_guide_vat_date][0],
       alternative_procedures: ["Name AV1: UV;UltraPay005;12345", "Name AV2: XY;XYService;54321"], eol: CRLF },
     "SIX Style Guide QR-bill pp. 21/28; introduction script p. 13"],
    ["six_sg_non_swico",
     { account: "CH5800791123000889012", creditor: MUSTER_SOEHNE, amount: "1949.75", debtor: SIMON_MUSTER_SP,
       reference_type: "NON", message: "Auftrag vom 15.06.2020", bill_information: SWICO[:style_guide_vat_date][0],
       alternative_procedures: ["Name AV1: UV;UltraPay005;12345", "Name AV2: XY;XYService;54321"], eol: CRLF },
     "SIX Style Guide QR-bill p. 22; introduction script pp. 7/14"],
    ["six_sg_donation_en",
     { account: "CH5204835012345671000",
       creditor: s_addr("Better World Trust", "P.O. Box", "", "3001", "Bern", "CH"),
       reference_type: "NON", eol: LF },
     "SIX Style Guide QR-bill p. 23; introduction script pp. 11/17/20"],
    ["six_intro_donation_de",
     { account: "CH5204835012345671000",
       creditor: s_addr("Stiftung Bessere Welt", "Postfach", "", "3001", "Bern", "CH"),
       reference_type: "NON", eol: LF },
     "SIX introduction script for invoice issuers/recipients (EN) pp. 18/19"]
  ].freeze

  # The verbatim decoded payloads (see SOURCES.md for how they were obtained).
  OFFICIAL_VERBATIM = {
    "six_ig_ex1_qrr" => "SPC\r\n0200\r\n1\r\nCH6431961000004421557\r\nS\r\nMax Muster & Söhne\r\nMusterstrasse\r\n123\r\n8000\r\nSeldwyla\r\nCH\r\n\r\n\r\n\r\n\r\n\r\n\r\n\r\n50.00\r\nCHF\r\nS\r\nSimon Muster\r\nMusterstrasse\r\n1\r\n8000\r\nSeldwyla\r\nCH\r\nQRR\r\n000008207791225857421286694\r\nPayment of travel\r\nEPD\r\n",
    "six_ig_ex2_qrr_swico_two_alt_procedures" => "SPC\r\n0200\r\n1\r\nCH4431999123000889012\r\nS\r\nMax Muster & Söhne\r\nMusterstrasse\r\n123\r\n8000\r\nSeldwyla\r\nCH\r\n\r\n\r\n\r\n\r\n\r\n\r\n\r\n1949.75\r\nCHF\r\nS\r\nSimon Muster\r\nMusterstrasse\r\n1\r\n8000\r\nSeldwyla\r\nCH\r\nQRR\r\n210000000003139471430009017\r\nOrder from 15.10.2020\r\nEPD\r\n//S1/10/1234/11/201021/30/102673386/32/7.7/40/0:30\r\nName AV1: UV;UltraPay005;12345\r\nName AV2: XY;XYService;54321",
    "six_ig_ex3_non_no_amount_no_debtor" => "SPC\n0200\n1\nCH5204835012345671000\nS\nSample Foundation\nPO Box\n\n3001\nBern\nCH\n\n\n\n\n\n\n\n\nCHF\n\n\n\n\n\n\n\nNON\n\n\nEPD\n",
    "six_ig_ex4_scor" => "SPC\n0200\n1\nCH5800791123000889012\nS\nMuster Krankenkasse\nMusterstrasse\n12\n8000\nSeldwyla\nCH\n\n\n\n\n\n\n\n211.00\nCHF\nS\nSarah Beispiel\nMusterstrasse\n1\n8000\nSeldwyla\nCH\nSCOR\nRF240191230100405JSH0438\n\nEPD\n",
    "six_ig_ex5_creditor_li" => "SPC\n0200\n1\nCH5800791123000889012\nS\nMax Muster & Söhne\nMusterstrasse\n123\n9490\nVaduz\nLI\n\n\n\n\n\n\n\n199.95\nCHF\nS\nSarah Beispiel\nMusterstrasse\n1\n8000\nSeldwyla\nCH\nSCOR\nRF18539007547034\n\nEPD\n",
    "six_ig_ex6_debtor_de" => "SPC\n0200\n1\nCH5800791123000889012\nS\nMax Muster & Söhne\nMusterstrasse\n123\n8000\nSeldwyla\nCH\n\n\n\n\n\n\n\n199.95\nCHF\nS\nSarah Beispiel\nMusterstrasse\n1\n78462\nKonstanz\nDE\nSCOR\nRF18539007547034\n\nEPD\n",
    "six_ig_notification_do_not_use" => "SPC\n0200\n1\nCH4431999123000889012\nS\nMax Muster & Söhne\nMusterstrasse\n123\n8000\nSeldwyla\nCH\n\n\n\n\n\n\n\n0.00\nCHF\nS\nSimon Muster\nMusterstrasse\n1\n8000\nSeldwyla\nCH\nQRR\n210000000003139471430009017\nDO NOT USE FOR PAYMENT\nEPD\n",
    "six_ig_non_with_amount" => "SPC\r\n0200\r\n1\r\nCH5204835012345671000\r\nS\r\nMax Muster & Söhne\r\nMusterstrasse\r\n123\r\n8000\r\nSeldwyla\r\nCH\r\n\r\n\r\n\r\n\r\n\r\n\r\n\r\n420.00\r\nCHF\r\nS\r\nBarbara Beispiel\r\nMusterstrasse\r\n1\r\n8000\r\nSeldwyla\r\nCH\r\nNON\r\n\r\n\r\nEPD",
    "six_sg_qrr_empty_billing_two_alt_procedures" => "SPC\r\n0200\r\n1\r\nCH4431999123000889012\r\nS\r\nMax Muster & Söhne\r\nMusterstrasse\r\n123\r\n8000\r\nSeldwyla\r\nCH\r\n\r\n\r\n\r\n\r\n\r\n\r\n\r\n2500.25\r\nCHF\r\nS\r\nSimon Muster\r\nMusterstrasse \r\n1\r\n8000\r\nSeldwyla\r\nCH\r\nQRR\r\n210000000003139471430009017\r\n\r\nEPD\r\n\r\nName AV1: UV;UltraPay005;12345\r\nName AV2: XY;XYService;54321",
    "six_sg_qrr_swico" => "SPC\r\n0200\r\n1\r\nCH4431999123000889012\r\nS\r\nMax Muster & Söhne\r\nMusterstrasse\r\n123\r\n8000\r\nSeldwyla\r\nCH\r\n\r\n\r\n\r\n\r\n\r\n\r\n\r\n1949.75\r\nCHF\r\nS\r\nSimon Muster\r\nMusterstrasse \r\n1\r\n8000\r\nSeldwyla\r\nCH\r\nQRR\r\n210000000003139471430009017\r\nAuftrag vom 15.06.2020\r\nEPD\r\n//S1/10/10201409/11/170309/20/14000000/30/106017086\r\nName AV1: UV;UltraPay005;12345\r\nName AV2: XY;XYService;54321",
    "six_sg_scor_two_alt_procedures" => "SPC\r\n0200\r\n1\r\nCH5800791123000889012\r\nS\r\nMax Muster & Söhne\r\nMusterstrasse\r\n123\r\n8000\r\nSeldwyla\r\nCH\r\n\r\n\r\n\r\n\r\n\r\n\r\n\r\n2500.25\r\nCHF\r\nS\r\nSimon Muster\r\nMusterstrasse \r\n1\r\n8000\r\nSeldwyla\r\nCH\r\nSCOR\r\nRF18539007547034\r\n\r\nEPD\r\n\r\nName AV1: UV;UltraPay005;12345\r\nName AV2: XY;XYService;54321",
    "six_sg_scor_swico" => "SPC\r\n0200\r\n1\r\nCH5800791123000889012\r\nS\r\nMax Muster & Söhne\r\nMusterstrasse\r\n123\r\n8000\r\nSeldwyla\r\nCH\r\n\r\n\r\n\r\n\r\n\r\n\r\n\r\n1949.75\r\nCHF\r\nS\r\nSimon Muster\r\nMusterstrasse \r\n1\r\n8000\r\nSeldwyla\r\nCH\r\nSCOR\r\nRF18539007547034\r\n\r\nEPD\r\n//S1/10/10201409/11/170309/20/14000000/30/106017086/31/210122\r\nName AV1: UV;UltraPay005;12345\r\nName AV2: XY;XYService;54321",
    "six_sg_non_swico" => "SPC\r\n0200\r\n1\r\nCH5800791123000889012\r\nS\r\nMax Muster & Söhne\r\nMusterstrasse\r\n123\r\n8000\r\nSeldwyla\r\nCH\r\n\r\n\r\n\r\n\r\n\r\n\r\n\r\n1949.75\r\nCHF\r\nS\r\nSimon Muster\r\nMusterstrasse \r\n1\r\n8000\r\nSeldwyla\r\nCH\r\nNON\r\n\r\nAuftrag vom 15.06.2020\r\nEPD\r\n//S1/10/10201409/11/170309/20/14000000/30/106017086/31/210122\r\nName AV1: UV;UltraPay005;12345\r\nName AV2: XY;XYService;54321",
    "six_sg_donation_en" => "SPC\n0200\n1\nCH5204835012345671000\nS\nBetter World Trust\nP.O. Box\n\n3001\nBern\nCH\n\n\n\n\n\n\n\n\nCHF\n\n\n\n\n\n\n\nNON\n\n\nEPD",
    "six_intro_donation_de" => "SPC\n0200\n1\nCH5204835012345671000\nS\nStiftung Bessere Welt\nPostfach\n\n3001\nBern\nCH\n\n\n\n\n\n\n\n\nCHF\n\n\n\n\n\n\n\nNON\n\n\nEPD",
    "six_ig_fig1_qrr_full_swico" => "SPC\n0200\n1\nCH4431999123000889012\nS\nRobert Schneider AG\nRue du Lac\n1268\n2501\nBiel\nCH\n\n\n\n\n\n\n\n1949.75\nCHF\nS\nPia-Maria Rutschmann-Schnyder\nGrosse Marktgasse\n28\n9400\nRorschach\nCH\nQRR\n210000000003139471430009017\nAuftrag vom 15.06.2020\nEPD\n//S1/10/10201409/11/200701/20/140.000-53/30/102673831/31/200615/32/7.7/33/7.7:139.40/40/0:30\nName AV1: UV;UltraPay005;12345\nName AV2: XY;XYService;54321",
    "six_ig_online_non_message" => "SPC\r\n0200\r\n1\r\nCH5204835012345671000\r\nS\r\nMax Muster & Söhne\r\nMusterstrasse\r\n123\r\n8000\r\nSeldwyla\r\nCH\r\n\r\n\r\n\r\n\r\n\r\n\r\n\r\n50.00\r\nCHF\r\nS\r\nSarah Beispiel\r\nMusterstrasse\r\n1\r\n8000\r\nSeldwyla\r\nCH\r\nNON\r\n\r\npayment of the trip\r\nEPD",
    "six_ap_ebill" => "SPC\r\n0200\r\n1\r\nCH4431999123000889012\r\nS\r\nMax Muster & Söhne\r\nMusterstrasse\r\n123\r\n8000\r\nSeldwyla\r\nCH\r\n\r\n\r\n\r\n\r\n\r\n\r\n\r\n1949.75\r\nCHF\r\nS\r\nSimon Muster\r\nMusterstrasse\r\n1\r\n8000\r\nSeldwyla\r\nCH\r\nQRR\r\n210000000003139471430009017\r\nAuftrag vom 15.10.2020\r\nEPD\r\n//S1/10/1234/11/201021/30/102673386/32/7.7/40/0:30\r\neBill/B/simon.muster@example.com"
  }.freeze

  # --- hand-built valid fixtures ----------------------------------------------

  def self.max_len(str, len) = (str * ((len / str.size) + 1))[0, len]

  VALID = {
    "qriban_qrr_lf" =>
      { account: QRIBAN_CH, creditor: ELEKTRO, amount: "1234.50", debtor: RUTSCHMANN,
        reference_type: "QRR", reference: QRR1, message: "Rechnung 2026-1014", eol: LF },
    "qriban_qrr_crlf_final_newline_no_amount" =>
      { account: QRIBAN_CH2, creditor: ELEKTRO, debtor: RUTSCHMANN,
        reference_type: "QRR", reference: QRR2, eol: CRLF, final_eol: true },
    "iban_scor_eur" =>
      { account: IBAN_CH, creditor: VERLAG, amount: "870.00", currency: "EUR", debtor: LOERRACH,
        reference_type: "SCOR", reference: SCOR1, eol: CRLF },
    "iban_non_message_lf" =>
      { account: IBAN_CH2, creditor: VEREIN, amount: "120.00", debtor: RUTSCHMANN,
        reference_type: "NON", message: "Mitgliederbeitrag 2027", eol: LF },
    "iban_non_eur_minimal" =>
      { account: IBAN_CH, creditor: VERLAG, currency: "EUR", reference_type: "NON", eol: CRLF },
    "iban_non_no_debtor_with_amount" =>
      { account: IBAN_CH2, creditor: VEREIN, amount: "35.00", reference_type: "NON",
        message: "Spende Jugendlager", eol: LF, final_eol: true },
    "li_iban_scor" =>
      { account: IBAN_LI, creditor: VADUZ, amount: "4500.00", debtor: SARAH_BEISPIEL,
        reference_type: "SCOR", reference: SCOR2, eol: CRLF },
    "li_qriban_qrr" =>
      { account: QRIBAN_LI, creditor: VADUZ, amount: "99.90", debtor: SIMON_MUSTER,
        reference_type: "QRR", reference: QRR3, eol: LF },
    "swico_annex_d_ex1_qrr" =>
      { account: QRIBAN_CH, creditor: ELEKTRO, amount: "3949.75", debtor: RUTSCHMANN,
        reference_type: "QRR", reference: QRR1, bill_information: SWICO[:annex_d_example1][0], eol: CRLF },
    "swico_annex_d_ex2_scor" =>
      { account: IBAN_CH, creditor: VERLAG, amount: "1025.00", debtor: RUTSCHMANN,
        reference_type: "SCOR", reference: SCOR1, message: "Hotel, 26.-27.02.2018",
        bill_information: SWICO[:annex_d_example2][0], eol: LF },
    "swico_annex_d_ex3_non" =>
      { account: IBAN_CH2, creditor: VERLAG, amount: "68.65", debtor: SARAH_BEISPIEL,
        reference_type: "NON", message: "Import", bill_information: SWICO[:annex_d_example3][0], eol: CRLF },
    "swico_annex_d_ex4_escaped_slash" =>
      { account: QRIBAN_CH, creditor: ELEKTRO, amount: "120.15", debtor: SIMON_MUSTER,
        reference_type: "QRR", reference: QRR2, bill_information: SWICO[:annex_d_example4][0], eol: LF },
    "swico_all_tags_escaped_backslash" =>
      { account: IBAN_CH, creditor: VERLAG, amount: "171.90", debtor: RUTSCHMANN,
        reference_type: "SCOR", reference: SCOR1, bill_information: SWICO[:all_tags_escaped][0], eol: CRLF },
    "billing_info_not_swico" =>
      { account: IBAN_CH, creditor: VERLAG, amount: "10.00", reference_type: "NON",
        bill_information: "//XY/V1/order=4711/branch=7", eol: LF },
    "alt_procedure_one_ebill" =>
      { account: QRIBAN_CH, creditor: ELEKTRO, amount: "250.00", debtor: SIMON_MUSTER,
        reference_type: "QRR", reference: QRR1, bill_information: "",
        alternative_procedures: ["eBill/B/simon.muster@example.com"], eol: CRLF },
    "alt_procedures_two_with_swico" =>
      { account: IBAN_CH, creditor: VERLAG, amount: "48.00", debtor: SIMON_MUSTER,
        reference_type: "SCOR", reference: SCOR1, message: "Abo 2027",
        bill_information: SWICO[:minimal][0],
        alternative_procedures: ["eBill/B/41010560425610173", "XY;XYService;54321"], eol: LF },
    "trailing_empty_lines_crlf" =>
      { account: IBAN_CH2, creditor: VEREIN, amount: "20.00", reference_type: "NON",
        eol: CRLF, trailing_blank_lines: 2 },
    "trailing_empty_lines_after_alt_procedure_lf" =>
      { account: IBAN_CH2, creditor: VEREIN, amount: "20.00", reference_type: "NON", bill_information: "",
        alternative_procedures: ["eBill/B/info@example.org"], eol: LF, trailing_blank_lines: 3 },
    "trailing_empty_billing_line_crlf" =>
      { account: IBAN_CH, creditor: VERLAG, amount: "15.00", reference_type: "NON",
        bill_information: "", eol: CRLF },
    "combined_address_k_legacy" =>
      { account: QRIBAN_CH, creditor: k_addr("Elektro Muster AG", "Bahnhofstrasse 17", "8001 Zürich", "CH"),
        amount: "777.70", debtor: k_addr("Pia-Maria Rutschmann-Schnyder", "Grosse Marktgasse 28", "9400 Rorschach", "CH"),
        reference_type: "QRR", reference: QRR1, message: "Address type K (removed in IG 2.3)", eol: CRLF,
        warnings: %w[creditor.type debtor.type] },
    "combined_address_k_debtor_only" =>
      { account: IBAN_CH, creditor: VERLAG, amount: "12.00",
        debtor: k_addr("Anna Schmid", "Hauptstrasse 42", "D-79539 Lörrach", "DE"),
        reference_type: "NON", eol: LF, warnings: %w[debtor.type] },
    "max_lengths" =>
      { account: IBAN_CH,
        creditor: s_addr(max_len("Creditor Name ", 70), max_len("Long Street ", 70), max_len("B", 16),
                         max_len("9", 16), max_len("Town ", 35), "CH"),
        amount: "999999999.99",
        debtor: s_addr(max_len("Debtor Name ", 70), max_len("Debtor Street ", 70), max_len("7", 16),
                       max_len("8", 16), max_len("Village ", 35), "CH"),
        reference_type: "SCOR", reference: SCOR_MAX, message: max_len("Message ", 74),
        bill_information: "//XY/#{"9" * 61}",
        alternative_procedures: [max_len("AP1;", 100), max_len("AP2;", 100)], eol: LF },
    "min_amount_min_scor" =>
      { account: IBAN_CH2, creditor: VEREIN, amount: "0.01", reference_type: "SCOR", reference: SCOR_MIN, eol: LF },
    "unicode_charset" =>
      { account: IBAN_CH, creditor: s_addr("Ștefan Țurcanu Söhne & Cie", "Rue de Genève", "4bis", "1003",
                                           "Lausanne", "CH"),
        amount: "64.20", debtor: s_addr("Łukasz Œuvre-Müller", "Ørstedgade", "3", "1001", "Fürstenau", "CH"),
        reference_type: "NON", message: "Café Crème & Brötli, Preis in € umgerechnet (½ Rabatt) ș ț",
        eol: CRLF },
    "street_with_building_number" =>
      { account: IBAN_CH2, creditor: s_addr("Boulangerie Exemple Sàrl", "Rue du Marché 12", "", "1204", "Genève", "CH"),
        amount: "8.40", debtor: s_addr("Jean Exemple", "Chemin des Vignes 3a", nil, "1260", "Nyon", "CH"),
        reference_type: "NON", eol: LF },
    "debtor_without_street" =>
      { account: IBAN_CH, creditor: VERLAG, amount: "19.90",
        debtor: s_addr("Hans Muster", "", "", "3000", "Bern", "CH"), reference_type: "NON", eol: LF },
    "alt_procedure_too_long_warning" =>
      { account: IBAN_CH, creditor: VERLAG, amount: "100.00", debtor: SIMON_MUSTER, reference_type: "NON",
        bill_information: "", alternative_procedures: [max_len("AP1;", 101)], eol: LF,
        warnings: %w[alternative_procedures],
        note: "status A line: IG 4.2.1 says errors there must not cause rejection, so a warning, not an error" },
    "scor_lowercase" =>
      { account: IBAN_CH2, creditor: VEREIN, amount: "25.00", reference_type: "SCOR",
        reference: SCOR1.downcase, eol: LF,
        note: "IG 4.2.2: banks do not distinguish upper/lower case in references; reference kept as given" },
    "qriban_qrr_eur" =>
      { account: QRIBAN_CH, creditor: ELEKTRO, amount: "1500.00", currency: "EUR", debtor: LOERRACH,
        reference_type: "QRR", reference: QRR2, eol: CRLF,
        note: "valid under IG 2.3 (in force); IG 2.4 (from 2026-11-14) restricts QR-IBAN/QRR to CHF" }
  }.freeze

  # --- invalid fixtures -------------------------------------------------------

  BASE_QRR = { account: QRIBAN_CH, creditor: ELEKTRO, amount: "100.00", debtor: SIMON_MUSTER,
               reference_type: "QRR", reference: QRR1, eol: LF }.freeze
  BASE_NON = { account: IBAN_CH, creditor: VERLAG, amount: "100.00", debtor: SIMON_MUSTER,
               reference_type: "NON", eol: LF }.freeze

  def self.invalid
    {
      "wrong_header" => [BASE_QRR.merge(qr_type: "SPX"), "[fatal] header: QR type must be \"SPC\" (got \"SPX\")"],
      "not_a_qr_bill_url" => ["https://example.com/pay?id=4711",
                              "[fatal] header: not a Swiss QR-bill payload (a plain URL)"],
      "empty" => ["", "[fatal] header|payload: empty payload"],
      "six_ig22_field_labels" => [
        "QRType\nVersion\nCoding Type\nCompte (IBAN CRE)\nType d'adresse (CRE)\nNom (CRE)\nRue ou ligne d'adresse 1 (CRE)\nNuméro de maison ou ligne d'adresse 2 (CRE)\nCode postale (CRE)\nLieu (CRE)\nPays (CRE)\nType d'adresse (CREF)\nNom (CREF)\nRue ou ligne d'adresse 1 (CREF)\nNuméro de maison ou ligne d'adresse 2 (CREF)\nCode postale (CREF)\nLieu (CREF)\nPays (CREF)\nMontant\nMonnaie\nType d'adresse (DEBF)\nNom (DEBF)\nRue ou ligne d'adresse 1 (DEBF)\nNuméro de maison ou ligne d'adresse 2 (DEBF)\nCode postale (DEBF)\nLieu (DEBF)\nPays (DEBF)\nType de référence\nRéférence\nCommunication non structurée\nTrailer\nInformations de facture\nPA1 – Paramètres\nPA2 – Paramètres",
        "[fatal] header: QR code with the field names instead of values (decoded from SIX IG v2.2 p. 40); QR type is \"QRType\""
      ],
      "truncated_10_lines" => [build(BASE_QRR).lines[0, 10].join.chomp,
                               "[fatal] payload|trailer: only 10 lines, the payload ends inside the creditor block"],
      "missing_trailer" => [BASE_QRR.merge(mutate: ->(l) { l[0, 30] }),
                            "[fatal] trailer|payload: 30 lines, the trailer line \"EPD\" is missing"],
      "wrong_trailer" => [BASE_QRR.merge(trailer: "EOD"), "trailer: trailer must be \"EPD\" (got \"EOD\")"],
      "wrong_version" => [BASE_QRR.merge(version: "0100"), "version: version must be \"0200\" (got \"0100\")"],
      "wrong_version_sub" => [BASE_QRR.merge(version: "0201"),
                              "version: only \"0200\" is permitted in master version 02 (got \"0201\")"],
      "wrong_coding_type" => [BASE_QRR.merge(coding_type: "2"), "coding_type: coding type must be \"1\" (got \"2\")"],
      "iban_bad_checksum" => [BASE_NON.merge(account: IBAN_CH.sub(/\ACH\d\d/) do |m|
        "CH%02d" % ((m[2, 2].to_i + 1) % 100)
      end),
                              "account: IBAN check digits are wrong (mod 97 != 1)"],
      "iban_too_short" => [BASE_NON.merge(account: IBAN_CH[0, 20]), "account: IBAN must be exactly 21 characters"],
      "iban_not_ch_li" => [BASE_NON.merge(account: IBAN_LV),
                           "account: only CH and LI IBANs are permitted (LV IBAN with valid check digits)"],
      "iban_with_spaces" => [BASE_NON.merge(account: IBAN_CH.scan(/.{1,4}/).join(" ")),
                             "account: IBAN must be given without spaces"],
      "iban_empty" => [BASE_NON.merge(account: ""), "account: IBAN is mandatory"],
      "qriban_with_scor" => [BASE_QRR.merge(reference_type: "SCOR", reference: SCOR1),
                             "reference_type: a QR-IBAN requires reference type QRR (got SCOR)"],
      "qriban_with_non" => [BASE_QRR.merge(reference_type: "NON", reference: nil),
                            "reference_type: a QR-IBAN requires reference type QRR (got NON)"],
      "iban_with_qrr" => [BASE_NON.merge(reference_type: "QRR", reference: QRR1),
                          "reference_type: reference type QRR requires a QR-IBAN (ordinary IBAN given)"],
      "qrr_bad_checksum" => [BASE_QRR.merge(reference: QRR1[0, 26] + ((QRR1[26].to_i + 1) % 10).to_s),
                             "reference: QR reference check digit (mod 10 recursive) is wrong"],
      "qrr_wrong_length" => [BASE_QRR.merge(reference: QRR1[1..]),
                             "reference: QR reference must be 27 digits (got 26)"],
      "qrr_not_numeric" => [BASE_QRR.merge(reference: "21000000000313947143000901A"),
                            "reference: QR reference must be numeric"],
      "qrr_missing" => [BASE_QRR.merge(reference: ""), "reference: reference type QRR requires a reference"],
      "scor_bad_checksum" => [BASE_NON.merge(reference_type: "SCOR", reference: SCOR1.sub(/\ARF\d\d/, "RF00")),
                              "reference: creditor reference (ISO 11649) check digits are wrong"],
      "six_ig_ex4_table_scor_typo" => [
        { account: "CH5800791123000889012",
          creditor: s_addr("Muster Krankenkasse", "Musterstrasse", "12", "8000", "Seldwyla", "CH"),
          amount: "211.00", debtor: SARAH_BEISPIEL, reference_type: "SCOR", reference: "RF720191230100405JSH0438",
          eol: CRLF },
        "reference: RF72 0191 2301 0040 5JSH 0438 as printed in SIX IG Annex A example 4 table/payment part " \
        "has wrong ISO 11649 check digits (the QR code there carries RF24...)"
      ],
      "scor_too_long" => [BASE_NON.merge(reference_type: "SCOR", reference: CD.scor("ABCDEFGHIJKLMNOPQRS123")),
                          "reference: creditor reference is 26 characters (max 25) although its check digits are valid"],
      "qrr_all_zeros" => [BASE_QRR.merge(reference: "0" * 27),
                          "reference: QR reference must not consist only of zeros (IG 2.3+; its check digit 0 is formally correct)"],
      "non_with_reference" => [BASE_NON.merge(reference: QRR1),
                               "reference: reference type NON must have an empty reference"],
      "unknown_reference_type" => [BASE_NON.merge(reference_type: "ISR"),
                                   "reference_type: unknown reference type \"ISR\""],
      "amount_too_large" => [BASE_NON.merge(amount: "1000000000.00"), "amount: above the maximum 999999999.99"],
      "amount_comma" => [BASE_NON.merge(amount: "50,00"), "amount: decimal separator must be \".\" (got \"50,00\")"],
      "amount_three_decimals" => [BASE_NON.merge(amount: "50.000"), "amount: must have exactly two decimal places"],
      "amount_negative" => [BASE_NON.merge(amount: "-5.00"), "amount: negative amount"],
      "amount_leading_zero" => [BASE_NON.merge(amount: "0050.00"), "amount: amount must not have leading zeroes"],
      "currency_unknown" => [BASE_NON.merge(currency: "USD"), "currency: only CHF and EUR are permitted (got USD)"],
      "currency_missing" => [BASE_NON.merge(currency: ""), "currency: currency is mandatory"],
      "creditor_missing" => [BASE_NON.merge(creditor: Array.new(7, "")),
                             "creditor: creditor (address type, name, postal code, town, country) is mandatory"],
      "creditor_name_too_long" => [BASE_NON.merge(creditor: VERLAG.merge(name: max_len("Verlag ", 71))),
                                   "creditor.name: name longer than 70 characters"],
      "creditor_name_missing" => [BASE_NON.merge(creditor: VERLAG.merge(name: "")), "creditor.name: name is mandatory"],
      "creditor_postal_code_missing" => [BASE_NON.merge(creditor: VERLAG.merge(postal_code: "")),
                                         "creditor.postal_code: postal code is mandatory for a structured address"],
      "creditor_town_too_long" => [BASE_NON.merge(creditor: VERLAG.merge(town: max_len("Town ", 36))),
                                   "creditor.town: town longer than 35 characters"],
      "creditor_building_number_too_long" => [BASE_NON.merge(creditor: VERLAG.merge(building_number: "12345678901234567")),
                                              "creditor.building_number: building number longer than 16 characters"],
      "creditor_country_invalid" => [BASE_NON.merge(creditor: VERLAG.merge(country: "CHE")),
                                     "creditor.country: country must be a two-letter ISO 3166-1 code (got \"CHE\")"],
      "creditor_address_type_invalid" => [BASE_NON.merge(creditor: VERLAG.merge(type: "X")),
                                          "creditor.type: address type must be \"S\" (or legacy \"K\"), got \"X\""],
      "combined_address_k_with_postal_code" => [
        BASE_NON.merge(creditor: ["K", "Verlag Beispiel GmbH", "Steinentorstrasse 8", "4051 Basel", "4051", "", "CH"]),
        "creditor.postal_code: combined address (K) must not fill postal code / town"
      ],
      "combined_address_k_missing_line2" => [
        BASE_NON.merge(creditor: ["K", "Verlag Beispiel GmbH", "Steinentorstrasse 8", "", "", "", "CH"]),
        "creditor.address_line2: combined address (K) requires address line 2 (postal code and town)"
      ],
      "ultimate_creditor_filled" => [BASE_NON.merge(ultimate_creditor: address_lines(VADUZ)),
                                     "ultimate_creditor: the ultimate creditor group is reserved and must be empty"],
      "debtor_name_missing" => [BASE_NON.merge(debtor: SIMON_MUSTER.merge(name: "")),
                                "debtor.name: debtor address given without a name"],
      "debtor_country_missing" => [BASE_NON.merge(debtor: SIMON_MUSTER.merge(country: "")),
                                   "debtor.country: debtor address given without a country"],
      "message_too_long" => [BASE_NON.merge(message: max_len("Message ", 141)),
                             "unstructured_message: longer than 140 characters"],
      "message_plus_billing_too_long" => [
        BASE_NON.merge(message: max_len("Invoice ", 90), bill_information: SWICO[:annex_d_example2][0][0, 51]),
        "unstructured_message|bill_information: message (90) + billing information (51) exceed 140 characters together"
      ],
      "alt_procedures_three" => [
        BASE_NON.merge(bill_information: "",
                       alternative_procedures: %w[eBill/B/a@example.com XY;XYService;1
                                                  ZZ;Third;3]),
        "alternative_procedures|payload: 3 alternative procedures (max 2), 35 lines"
      ],
      "too_many_lines" => [BASE_NON.merge(bill_information: "", alternative_procedures: %w[A B],
                                          mutate: ->(l) { l + Array.new(6) { |i| "junk #{i}" } }),
                           "payload|alternative_procedures: 40 lines (max 34)"],
      "extra_line_in_creditor" => [BASE_NON.merge(mutate: ->(l) { l.insert(7, "c/o Muster") }),
                                   "trailer|payload: an extra line shifts all fields, line 31 is \"\" not \"EPD\""],
      "payload_too_long" => [
        BASE_NON.merge(message: max_len("Lorem ipsum dolor sit amet ", 700), bill_information: "",
                       alternative_procedures: [max_len("AP1;", 100), max_len("AP2;", 100)]),
        "payload|unstructured_message: more than 997 characters (the 700-character message is also over 140)"
      ],
      "invalid_character_cyrillic" => [BASE_NON.merge(creditor: VERLAG.merge(name: "Издательство Пример")),
                                       "creditor.name: characters outside the permitted Latin character set"],
      "invalid_character_emoji" => [BASE_NON.merge(message: "Thanks 😀"),
                                    "unstructured_message: characters outside the permitted Latin character set"],
      "invalid_character_tab" => [BASE_NON.merge(message: "Rechnung\t4711"),
                                  "unstructured_message: control character (TAB) is not permitted"],
      "mixed_line_endings" => [BASE_NON.merge(mutate: ->(l) { [l[0, 15].join("\r\n"), *l[15..]] }),
                               "payload: CRLF and LF mixed (IG 4.1.4: the same separator must be used throughout)"]
    }
  end

  # --- writing ----------------------------------------------------------------

  def self.write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
  end

  def self.json(obj) = "#{JSON.pretty_generate(obj)}\n"

  def self.payloads
    valid_dir = File.join(ROOT, "payloads", "valid")
    invalid_dir = File.join(ROOT, "payloads", "invalid")
    swico_dir = File.join(ROOT, "payloads", "swico")
    [valid_dir, invalid_dir, swico_dir].each { |d| FileUtils.rm_rf(d) }

    OFFICIAL.each do |name, spec, source|
      payload = assert_valid!(name, spec)
      verbatim = OFFICIAL_VERBATIM.fetch(name)
      raise "#{name}: rebuilt payload differs from SIX original" unless payload == verbatim

      write(File.join(valid_dir, "#{name}.txt"), verbatim)
      write(File.join(valid_dir, "#{name}.json"), json(expected(spec, source: source)))
    end

    VALID.each do |name, spec|
      payload = assert_valid!(name, spec)
      write(File.join(valid_dir, "#{name}.txt"), payload)
      write(File.join(valid_dir, "#{name}.json"), json(expected(spec, source: "hand-built (generate.rb)")))
    end

    invalid.each do |name, (spec, reason)|
      payload = spec.is_a?(String) ? spec : build(spec)
      raise "#{name}: reason must be one line" if reason.include?("\n")

      write(File.join(invalid_dir, "#{name}.txt"), payload)
      write(File.join(invalid_dir, "#{name}.reason"), "#{reason}\n")
    end
    payload_too_long = File.binread(File.join(invalid_dir, "payload_too_long.txt")).force_encoding("UTF-8")
    raise "payload_too_long is only #{payload_too_long.size} chars" unless payload_too_long.size > 997

    SWICO.each do |name, (raw, fields)|
      write(File.join(swico_dir, "#{name}.txt"), raw)
      write(File.join(swico_dir, "#{name}.json"),
            json({ "_source" => swico_source(name) }.merge(deep_stringify(fields))))
    end
  end

  def self.swico_source(name)
    case name
    when :ig_example2 then "SIX IG QR-bill v2.4 Annex A example 2"
    when :style_guide, :style_guide_vat_date then "SIX Style Guide QR-bill sample QR codes"
    when /annex_d/ then "SIX IG QR-bill v2.4 Annex D, table 31, #{name.to_s.sub("annex_d_", "")}"
    else "hand-built (generate.rb)"
    end
  end

  # --- images -----------------------------------------------------------------

  module Images
    module_function

    QUIET = 4 # modules of quiet zone required by ISO 18004

    def qr_modules(text)
      require "rqrcode"
      qr = RQRCode::QRCode.new(text, level: :m, mode: :byte_8bit)
      raise "ECC level must be M" unless qr.qrcode.error_correction_level == :m

      qr.modules
    end

    # Draws the Swiss cross (7 x 7 mm on a 46 x 46 mm code) into the centre.
    def swiss_cross(img, size)
      white = ChunkyPNG::Color::WHITE
      black = ChunkyPNG::Color::BLACK
      cross = (size * 7.0 / 46).round
      x0 = (img.width - cross) / 2
      y0 = (img.height - cross) / 2
      img.rect(x0, y0, x0 + cross - 1, y0 + cross - 1, white, white)
      b = (cross * 0.06).ceil
      img.rect(x0 + b, y0 + b, x0 + cross - 1 - b, y0 + cross - 1 - b, black, black)
      arm = (cross * 0.18).round
      len = (cross * 0.58).round
      cx = x0 + (cross / 2)
      cy = y0 + (cross / 2)
      img.rect(cx - (arm / 2), cy - (len / 2), cx + (arm / 2), cy + (len / 2), white, white)
      img.rect(cx - (len / 2), cy - (arm / 2), cx + (len / 2), cy + (arm / 2), white, white)
    end

    def png(text, scale: 6, cross: false)
      require "chunky_png"
      mods = qr_modules(text)
      n = mods.size
      dim = (n + (2 * QUIET)) * scale
      img = ChunkyPNG::Image.new(dim, dim, ChunkyPNG::Color::WHITE)
      mods.each_with_index do |row, y|
        row.each_with_index do |dark, x|
          next unless dark

          px = (x + QUIET) * scale
          py = (y + QUIET) * scale
          img.rect(px, py, px + scale - 1, py + scale - 1, ChunkyPNG::Color::BLACK, ChunkyPNG::Color::BLACK)
        end
      end
      swiss_cross(img, n * scale) if cross
      img
    end

    def side_by_side(*imgs)
      require "chunky_png"
      gap = 40
      w = imgs.sum(&:width) + (gap * (imgs.size + 1))
      h = imgs.map(&:height).max + (2 * gap)
      canvas = ChunkyPNG::Image.new(w, h, ChunkyPNG::Color::WHITE)
      x = gap
      imgs.each do |img|
        canvas.replace!(img, x, gap)
        x += img.width + gap
      end
      canvas
    end

    # A minimal hand-written PDF (no PDF library needed): A4 pages with a line
    # of text and the QR code drawn as vector rectangles at 46 x 46 mm,
    # like a digitally created invoice.
    def pdf(pages)
      mm = 72 / 25.4
      objects = []
      add = lambda { |body|
        objects << body
        objects.size
      }
      font = add.call("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
      page_ids = []
      pages_id_placeholder = "PAGES_ID"
      pages.each do |page|
        ops = +"BT /F1 14 Tf #{20 * mm} #{270 * mm} Td (#{page[:title]}) Tj ET\n"
        page[:codes].each do |code|
          mods = qr_modules(code[:text])
          n = mods.size
          size = (code[:size_mm] || 46) * mm
          m = size / n
          ox = code[:x_mm] * mm
          oy = code[:y_mm] * mm
          ops << "0 g\n"
          mods.each_with_index do |row, y|
            row.each_with_index do |dark, x|
              ops << format("%.3f %.3f %.3f %.3f re\n", ox + (x * m), oy + size - ((y + 1) * m), m, m) if dark
            end
          end
          ops << "f\n"
          next unless code[:cross]

          c = 7 * mm
          cx = ox + ((size - c) / 2)
          cy = oy + ((size - c) / 2)
          b = c * 0.06
          arm = c * 0.18
          len = c * 0.58
          ops << format("1 g %.3f %.3f %.3f %.3f re f\n", cx, cy, c, c)
          ops << format("0 g %.3f %.3f %.3f %.3f re f\n", cx + b, cy + b, c - (2 * b), c - (2 * b))
          ops << format("1 g %.3f %.3f %.3f %.3f re f\n", cx + ((c - arm) / 2), cy + ((c - len) / 2), arm, len)
          ops << format("1 g %.3f %.3f %.3f %.3f re f\n", cx + ((c - len) / 2), cy + ((c - arm) / 2), len, arm)
        end
        data = Zlib::Deflate.deflate(ops, Zlib::BEST_COMPRESSION)
        content = add.call("<< /Length #{data.bytesize} /Filter /FlateDecode >>\nstream\n".b + data + "\nendstream".b)
        page_ids << add.call("<< /Type /Page /Parent #{pages_id_placeholder} 0 R /MediaBox [0 0 595.28 841.89] " \
                         "/Resources << /Font << /F1 #{font} 0 R >> >> /Contents #{content} 0 R >>")
      end
      pages_id = add.call("<< /Type /Pages /Kids [#{page_ids.map do |i|
        "#{i} 0 R"
      end.join(" ")}] /Count #{page_ids.size} >>")
      catalog = add.call("<< /Type /Catalog /Pages #{pages_id} 0 R >>")
      out = +"%PDF-1.4\n%\xE2\xE3\xCF\xD3\n".b
      offsets = []
      objects.each_with_index do |body, i|
        offsets << out.bytesize
        body = body.sub(pages_id_placeholder, pages_id.to_s) if body.start_with?("<< /Type /Page ")
        out << "#{i + 1} 0 obj\n".b << body.b << "\nendobj\n".b
      end
      xref = out.bytesize
      out << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n".b
      offsets.each { |o| out << format("%010d 00000 n \n", o).b }
      out << "trailer\n<< /Size #{objects.size + 1} /Root #{catalog} 0 R >>\nstartxref\n#{xref}\n%%EOF\n".b
      out
    end
  end

  NOT_A_BILL = "https://example.com/pay?id=4711"

  def self.images
    require "qr_reader"
    dir = File.join(ROOT, "images")
    FileUtils.mkdir_p(dir)
    Dir[File.join(dir, "*.{png,pdf}")].each { |f| File.delete(f) }
    payload = ->(name) { File.binread(File.join(ROOT, "payloads", "valid", "#{name}.txt")).force_encoding("UTF-8") }
    expected = {}

    singles = {
      "six_ig_ex1_qrr" => {},
      "six_ig_ex2_qrr_swico_two_alt_procedures" => {},
      "iban_scor_eur" => {},
      "combined_address_k_legacy" => {},
      "unicode_charset" => {},
      "max_lengths" => { scale: 4 },
      "qriban_qrr_lf" => { cross: true, scale: 8 }
    }
    singles.each do |name, opts|
      file = opts[:cross] ? "#{name}_swiss_cross.png" : "#{name}.png"
      Images.png(payload.call(name), **opts).save(File.join(dir, file))
      expected[file] = [name]
    end

    two = Images.side_by_side(Images.png(payload.call("iban_non_message_lf"), cross: true), Images.png(NOT_A_BILL))
    two.save(File.join(dir, "bill_and_url.png"))
    expected["bill_and_url.png"] = ["iban_non_message_lf", { "not_a_bill" => NOT_A_BILL }]

    Images.png(NOT_A_BILL).save(File.join(dir, "url_only.png"))
    expected["url_only.png"] = [{ "not_a_bill" => NOT_A_BILL }]

    pdf = Images.pdf([
                       { title: "Rechnung 4711 - Max Muster & Soehne (SIX IG example 2 data)",
                         codes: [{ text: payload.call("six_ig_ex2_qrr_swico_two_alt_procedures"), x_mm: 67, y_mm: 37,
                                   cross: true }] },
                       { title: "Invoice / Rechnung (two codes on one page)",
                         codes: [{ text: payload.call("iban_scor_eur"), x_mm: 67, y_mm: 37, cross: true },
                                 { text: NOT_A_BILL, x_mm: 150, y_mm: 230, size_mm: 25 }] }
                     ])
    File.binwrite(File.join(dir, "invoice_two_pages.pdf"), pdf)
    expected["invoice_two_pages.pdf"] = ["six_ig_ex2_qrr_swico_two_alt_procedures", "iban_scor_eur",
                                         { "not_a_bill" => NOT_A_BILL }]

    # Verify every image decodes back to exactly the expected texts.
    expected.each do |file, items|
      want = items.map { |i| i.is_a?(Hash) ? i["not_a_bill"] : payload.call(i) }.sort
      got = QrReader.decode_all(File.join(dir, file)).sort
      raise "#{file}: decoded #{got.inspect}, expected #{want.inspect}" unless got == want

      warn "verified #{file} (#{got.size} code#{"s" unless got.size == 1})"
    end
    write(File.join(dir, "expected.json"), json(expected))
  end

  def self.run(argv)
    payloads
    images unless argv.include?("--no-images")
    warn "fixtures written to #{ROOT}"
  end
end

FixtureGen.run(ARGV) if $PROGRAM_NAME == __FILE__
# rubocop:enable Metrics, Layout/LineLength, Style/FormatStringToken, Style/StringConcatenation, Style/FormatString
