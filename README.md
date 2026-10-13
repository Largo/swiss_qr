# SwissQr

Parses and validates the payload of the Swiss QR Code printed on a Swiss
QR-bill ("QR-Rechnung", "QR-facture"), as defined by the SIX *Swiss
Implementation Guidelines for the QR-bill* (QR type `SPC`, version `0200`,
coding type `1`, trailer `EPD`).

- No runtime dependencies besides `bigdecimal`.
- Immutable value objects (`Data`): `SwissQr::Bill`, `SwissQr::Address`,
  `SwissQr::BillInformation` (Swico/SIX "S1" billing information).
- Checks every payload rule of IG 2.3: header, IBAN/QR-IBAN and check digits,
  reference type against account, QR reference (mod 10 recursive) and ISO
  11649 creditor reference (mod 97), amount format, currency, addresses,
  reserved ultimate creditor, field lengths, character set, 997-character
  limit, line separators.
- Tolerates CR LF or LF, a final line break and trailing empty lines, which
  real-world generators (SIX's own samples included) produce.

## Installation

```bash
bundle add swiss_qr
```

## Usage

```ruby
require "swiss_qr"

bill = SwissQr.parse(payload)       # raises SwissQr::InvalidPayload on any rule violation
bill.account                         # => "CH4431999123000889012"
bill.qr_iban?                        # => true
bill.formatted_account               # => "CH44 3199 9123 0008 8901 2"
bill.amount                          # => 0.194975e4 (BigDecimal, nil when open)
bill.currency                        # => "CHF"
bill.creditor.name                   # => "Max Muster & Söhne"
bill.creditor.lines                  # => ["Max Muster & Söhne", "Musterstrasse 123", "8000 Seldwyla"]
bill.debtor&.town                    # => "Seldwyla"
bill.reference_type                  # => :qrr (:qrr, :scor or :non)
bill.formatted_reference             # => "21 00000 00003 13947 14300 09017"
bill.unstructured_message            # => "Order from 15.10.2020"
bill.swico&.invoice_number           # => "1234"
bill.swico&.payment_conditions       # => [#<data PaymentCondition discount=0.0, days=30>]
bill.alternative_procedures          # => ["eBill/B/simon.muster@example.com"]
bill.warnings                        # => [] (e.g. legacy address type "K")
bill.to_h                            # Ruby types (BigDecimal, Date, Symbol)
bill.to_json                         # JSON (amount as "1949.75")
```

### Lenient parsing

```ruby
bill = SwissQr.parse(payload, strict: false)
bill.valid?                          # => false
bill.errors.map(&:to_s)              # => ["reference: QR reference check digit (modulo 10 recursive) is wrong: ..."]
```

`strict: false` returns the bill with `errors` filled in. It still raises
`SwissQr::InvalidPayload` when the text is not a QR-bill at all (QR type is
not `SPC`, fewer than 31 lines). Each `SwissQr::Problem` has a `field`
symbol (`:account`, `:"creditor.name"`, `:reference`, `:payload`, …) and a
`message`. `SwissQr::InvalidPayload#errors` lists all of them and `#bill` holds
the partially parsed bill.

```ruby
SwissQr.valid?(payload)              # => true / false
SwissQr.qr_bill?(text)               # cheap "looks like SPC" check, e.g. to skip other QR codes
```

Billing information and alternative procedures have status "A" in the
guidelines: errors there must not make a bill be rejected, so they only produce
warnings. Address type "K" (combined address) was removed in IG 2.3; it is
still parsed (`address.combined?`, `address_line1`, `address_line2`) with a
warning.

### Helpers

```ruby
SwissQr::Iban.valid?("CH44 3199 9123 0008 8901 2")    # => true
SwissQr::Iban.qr_iban?("CH4431999123000889012")       # => true
SwissQr::Iban.format("CH4431999123000889012")         # => "CH44 3199 9123 0008 8901 2"
SwissQr::Reference.valid_qrr?("210000000003139471430009017")   # => true
SwissQr::Reference.valid_scor?("RF18 5390 0754 7034")          # => true
SwissQr::Reference.qrr("21000000000313947143000901")           # => "210000000003139471430009017"
SwissQr::Reference.scor("539007547034")                        # => "RF18539007547034"
SwissQr::Reference.format_qrr("210000000003139471430009017")   # => "21 00000 00003 13947 14300 09017"
SwissQr::Reference.format_scor("RF18539007547034")             # => "RF18 5390 0754 7034"
SwissQr::BillInformation.parse("//S1/10/10201409/11/190512/32/7.7/40/2:10;0:30")
```

## Specification

`docs/SPEC_NOTES.md` digests the SIX documents (IG 2.2–2.4, processing
rules, QR-IID, S1 syntax) with a source for every rule. The test fixtures in
`test/fixtures` include the official SIX sample QR codes.

## Development

After checking out the repo, run `bin/setup` to install dependencies, then
`bundle exec rake` to run the tests and RuboCop. `bin/console` gives an
interactive prompt.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
