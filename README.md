# SwissQr

Parses and validates the Swiss QR Code printed on a Swiss QR-bill
("QR-Rechnung", "QR-facture", "QR-fattura"), as defined by the SIX *Swiss
Implementation Guidelines for the QR-bill* (QR type `SPC`, version `0200`,
coding type `1`, trailer `EPD`). It can also find the code in images and PDFs.

- **Parser with no dependencies** other than `bigdecimal`. Values come back as
  immutable `Data` objects: `SwissQr::Bill`, `SwissQr::Address` and
  `SwissQr::BillingInformation` (Swico/SIX "S1" billing information).
- **Checks every payload rule:** header, IBAN and QR-IBAN check digits, the
  reference type against the account, QR reference (modulo 10 recursive), ISO
  11649 creditor reference (modulo 97), amount, currency, addresses, the
  reserved ultimate creditor, field lengths, character set, the 997-character
  limit and line separators.
- **Tolerant where real generators deviate:** CR LF or LF, a final line break
  (of either kind), trailing empty lines, a byte order mark and blanks after
  free text are accepted (SIX's own samples have some of these).
- **Reads QR codes from images and PDFs** through a pluggable reader. By
  default this is the pure-Ruby [`qr_reader`](https://rubygems.org/gems/qr_reader)
  gem, which is optional and loaded only when you call `SwissQr.read`. Any
  other decoder (ZXing, ZBar, a cloud API, ...) can be plugged in instead.
- **`swiss_qr` command** that prints bills as JSON.
- **Runs on every major Ruby implementation:** MRI (CRuby) 3.3 to 4.0, JRuby 10,
  TruffleRuby and ruby.wasm (with
  [`bigdecimal-pure`](https://rubygems.org/gems/bigdecimal-pure)). All of them
  run the test suite in CI except ruby.wasm, which was tested by hand; see
  [Ruby versions and platforms](#ruby-versions-and-platforms).

## Installation

```bash
bundle add swiss_qr
bundle add qr_reader    # optional: only needed for SwissQr.read / read_all and the CLI
```

or `gem install swiss_qr qr_reader`.

### Ruby versions and platforms

Ruby 3.3 or newer. Both gems are plain Ruby; neither has a C extension of its
own.

| Ruby | |
|---|---|
| MRI 3.3, 3.4, 4.0 | tested |
| TruffleRuby 25 | tested |
| JRuby 10 | tested |
| ruby.wasm (Ruby 4.0) | works with `bigdecimal-pure`, see below |
| MRI 3.2 and older, JRuby 9.4 and older | not supported (3.2 is end of life) |

Amounts, VAT rates and discounts are `BigDecimal`s, so swiss_qr depends on
the `bigdecimal` gem. That gem is a C extension. Where it cannot be built or
loaded, ruby.wasm above all, use
[`bigdecimal-pure`](https://rubygems.org/gems/bigdecimal-pure) instead: a
`BigDecimal` written in Ruby on top of `Rational`, exact like the original for
everything swiss_qr does. Its `require "bigdecimal"` loads the native
extension when there is one, and the pure class otherwise.

Put its `lib` on the load path ahead of swiss_qr, which is how gems are
usually loaded into ruby.wasm (for example with the `@ruby/4.0-wasm-wasi`
npm package):

```ruby
$LOAD_PATH.unshift "/gems/bigdecimal-pure/lib", "/gems/swiss_qr/lib", "/gems/qr_reader/lib"
require "swiss_qr"   # its require "bigdecimal" gets bigdecimal-pure's class
```

Reading images and PDFs under ruby.wasm needs a qr_reader newer than 0.0.2
(not yet released); 0.0.2 crashes the wasm VM inside zlib on PNGs and
compressed PDFs. Parsing payloads does not use qr_reader at all.

Under Bundler this does not work yet: swiss_qr's dependency installs the
`bigdecimal` gem itself (Bundler cannot substitute one gem for another), and
bigdecimal-pure 0.1.0 does not fall back to its pure class when that gem's
Ruby files are present but its C extension cannot be loaded.

## Parsing a payload

```ruby
require "swiss_qr"

bill = SwissQr.parse(payload)       # raises SwissQr::InvalidPayload on any rule violation
bill.iban                            # => "CH4431999123000889012"
bill.qr_iban?                        # => true
bill.formatted_iban                  # => "CH44 3199 9123 0008 8901 2"
bill.amount                          # => 0.194975e4 (BigDecimal, nil when open)
bill.formatted_amount                # => "1949.75"
bill.currency                        # => "CHF"
bill.creditor.name                   # => "Max Muster & Söhne"
bill.creditor.lines                  # => ["Max Muster & Söhne", "Musterstrasse 123", "8000 Seldwyla"]
bill.debtor&.town                    # => "Seldwyla"
bill.reference_type                  # => :qrr (:qrr, :scor or :non)
bill.reference                       # => "210000000003139471430009017"
bill.formatted_reference             # => "21 00000 00003 13947 14300 09017"
bill.unstructured_message            # => "Order from 15.10.2020"
bill.billing_information&.invoice_number      # => "1234"
bill.billing_information&.invoice_date        # => Date.new(2020, 10, 21)
bill.billing_information&.payment_conditions  # => [#<data PaymentCondition discount=0.0, days=30>]
bill.alternative_procedures          # => ["Name AV1: UV;UltraPay005;12345", "Name AV2: XY;XYService;54321"]
bill.warnings                        # => [] (e.g. legacy address type "K")
bill.to_h                            # Ruby types (BigDecimal, Date, Symbol), nested hashes
bill.to_json                         # JSON (amount as "1949.75", symbols as strings)
```

The payload is the decoded text of the QR code: a String, ideally UTF-8.
Binary strings are taken as UTF-8, and strings in other encodings (UTF-16,
UTF-32, real Latin-1, ...) are transcoded. A string tagged ISO-8859-1 or
Windows-1252 whose bytes are valid UTF-8 is read as UTF-8 with a warning:
many QR decoders tag byte-mode data that way, but a QR-bill is always UTF-8.
Input longer than 4096 bytes (more than any QR code holds) is rejected with
`InvalidPayload` before it is parsed.

```ruby
SwissQr.valid?(payload)              # => true / false, never raises
SwissQr.looks_like_qr_bill?(text)               # cheap "starts like SPC/0200" check, no validation
```

## Reading QR-bills from images and PDFs

```ruby
require "swiss_qr"

bill  = SwissQr.read("invoice.pdf")      # first QR-bill found, or nil
bills = SwissQr.read_all("scans.pdf")    # every QR-bill on every page, [] when none
```

`input` can be:

- a file path (`String` or `Pathname`),
- an `IO` with the image or PDF: a `File`, an upload's `Tempfile`, or
  `StringIO.new(bytes)` for bytes you already hold,
- with the default reader, also a `ChunkyPNG::Image`-like object (`#width`,
  `#height`, `#pixels`).

A `String` is always a file path, never image data, as with `File.read`. Image
bytes in a `String` raise `ArgumentError` (wrap them in `StringIO.new`), so
bytes uploaded by a client can never be taken for a path on the server:

```ruby
SwissQr.read(params[:invoice].tempfile)   # an upload
SwissQr.read(StringIO.new(pdf_bytes))     # bytes from an API or a database
```

Supported formats are PNG, JPEG, JPEG 2000, GIF, BMP, PNM and TIFF (including
fax), and PDFs (scanned pages, as well as vector-drawn codes in generated
PDFs). The Swiss cross in the middle of the code is no problem.

Other QR codes on the page, such as a link to an online portal or a TWINT code,
are skipped: only texts for which `SwissQr.looks_like_qr_bill?` is true are parsed. `read`
stops at the first QR-bill. With the default reader it does not decode the
rest of a long PDF.

`strict:` works as for `parse` (see below). With the default `strict: true`, an
invalid QR-bill in the image raises `SwissQr::InvalidPayload`. A QR code that
does not start with `SPC` is not a QR-bill, so it is skipped and does not
raise. Errors from the reader itself propagate: `Errno::ENOENT` for a missing
file, and `QrReader::ImageError` or `QrReader::UnsupportedImageError` for
unreadable data.

### Choosing or replacing the QR code reader

`SwissQr` does not decode QR codes itself. It asks a *reader* for the texts of
all codes in the input. A reader is either:

- **an object with `decode_all(input)`** that returns an Array of Strings (the
  `QrReader` module is one), or
- **a callable** (Proc, lambda, `Method`, any object with `#call(input)`) that
  returns a String, an Array of Strings, or `nil`.

Elements may also be result objects with a `#text` method (for example
`QrReader::Result`). `nil` elements are ignored.

The reader gets the input as passed to `read`. A `String` it receives is
always a file path, because image bytes in a `String` are refused before any
reader is asked.

The default reader is `SwissQr::Reader::QrReaderAdapter`. Creating it does not
load anything. It runs `require "qr_reader"` on the first read. If the gem is
missing, the read raises `SwissQr::ReaderUnavailable`, and the message says how
to install the gem (`gem install qr_reader` or `bundle add qr_reader`) or to set
another reader. `require "swiss_qr"` never loads `qr_reader`.

Replace the reader for the whole process, or pass one per call:

```ruby
# qr_reader with options (fail fast on pages without a code); options are
# passed on to qr_reader, which is still loaded only on the first read
SwissQr.reader = SwissQr::Reader::QrReaderAdapter.new(try_harder: false)

# any object with decode_all
class MyZxingReader
  def decode_all(path) = ZXing.decode_all(path)   # e.g. the zxing gem (JRuby)
end
SwissQr.reader = MyZxingReader.new

# ZBar's command-line tool, for images that carry a single code
# (zbarimg --raw cannot separate several multi-line codes)
require "open3"
SwissQr.reader = lambda do |path|
  out, status = Open3.capture2("zbarimg", "--quiet", "--raw", "-Sdisable", "-Sqrcode.enable", path.to_s)
  status.success? ? out.chomp : nil
end

# per call; the global reader is unchanged
SwissQr.read("scan.png", reader: ->(path) { my_cloud_ocr(path) })

SwissQr.reader = nil                       # back to the default (qr_reader)
```

Prefer `QrReaderAdapter.new(**options)` over `SwissQr.reader = QrReader` or a
lambda calling `QrReader.decode_all` (which also needs `require "qr_reader"`):
only the adapter returns no codes for a PDF without any image, where qr_reader
itself raises `QrReader::UnsupportedImageError`, and only the adapter lets
`read` stop decoding at the first QR-bill.

A callable may return a single result object (anything with `#text`, such as a
`Struct` or `Data`) instead of an Array; it counts as one code.

`SwissQr.reader=` checks that the object responds to `#decode_all` or `#call`
and raises `ArgumentError` otherwise. A reader that returns anything other
than Strings (or objects with `#text`) makes `read` raise `TypeError`.

Assigning `SwissQr.reader` is thread-safe, but the reader is global to the
process. Assign it once at boot, or pass `reader:` per call.

## Validation and strict mode

```ruby
SwissQr.parse(payload)                     # strict: true (default) raises on any error
bill = SwissQr.parse(payload, strict: false)
bill.valid?                                # => false
bill.errors.map(&:to_s)                    # => ["reference: QR reference check digit (modulo 10 recursive) is wrong: ..."]
bill.warnings                              # problems that do not make the bill invalid
```

- **`strict: true`** raises `SwissQr::InvalidPayload` when there is any error.
  `#errors` lists every `SwissQr::Problem`, and `#bill` holds the partially
  parsed bill.
- **`strict: false`** returns the bill with `errors` filled in. It still raises
  `InvalidPayload` when the text is not structurally a QR-bill: the QR type is
  not `SPC`, or there are fewer than 31 lines. `#bill` is `nil` then.
- A **`SwissQr::Problem`** has a `field` symbol (`:iban`, `:"creditor.name"`,
  `:reference`, `:payload`, ...) and a `message`. `problem.about?(:creditor)`
  matches all creditor fields.
- **Warnings** never make a bill invalid. Billing information and alternative
  procedures have status "A" in the guidelines (errors there must not lead to
  rejection), so only warnings are given for them. Other warnings: legacy
  address type `K`, a removed BOM, blanks around free text (names, street,
  town, message), a UTF-8 payload tagged as Latin-1, a postal code that may
  have a country prefix. Blanks around fixed-format elements (IBAN, amount,
  codes, reference, country) are errors.

Errors: `SwissQr::Error` (base) → `SwissQr::InvalidPayload`,
`SwissQr::ReaderUnavailable`.

## Value objects

All three are immutable (`Data`) and support `#to_h`, `#as_json` and `==`.

### `SwissQr::Bill`

| Field | Type | Notes |
|---|---|---|
| `version` | String | `"0200"` |
| `coding_type` | String | `"1"` (UTF-8, Latin character set) |
| `iban` | String | IBAN or QR-IBAN, no spaces, upper case (`formatted_iban` adds spaces) |
| `qr_iban` | Boolean | Also `qr_iban?`. QR-IID 30000–31999 |
| `creditor` | Address | Required |
| `ultimate_creditor` | Address, nil | Reserved by SIX. Must be empty, so always `nil` in a valid bill |
| `amount` | BigDecimal, nil | `nil` = open amount (`open_amount?`). `0.00` = notification (`notification?`). `formatted_amount` gives `"50.00"` |
| `currency` | String | `"CHF"` or `"EUR"` |
| `debtor` | Address, nil | Optional |
| `reference_type` | Symbol | `:qrr` (QR reference, needs QR-IBAN), `:scor` (ISO 11649 creditor reference) or `:non` |
| `reference` | String, nil | As given. `formatted_reference` groups the digits |
| `unstructured_message` | String, nil | Free text |
| `trailer` | String | `"EPD"` |
| `raw_billing_information` | String, nil | Billing information as given (line 32) |
| `billing_information` | BillingInformation, nil | The billing information parsed, when it uses the Swico S1 syntax (`//S1/...`) |
| `alternative_procedures` | Array of String | At most 2 (e.g. `"eBill/B/..."`) |
| `errors`, `warnings` | Array of Problem | `valid?` is `errors.empty?` |
| `raw` | String | The payload as given (UTF-8) |

### `SwissQr::Address`

| Field | Notes |
|---|---|
| `type` | `:structured` (`S`) or `:combined` (`K`, legacy). Also `structured?` and `combined?` |
| `name` | Name or company |
| `street`, `building_number` | Type `S` only |
| `postal_code`, `town` | Type `S` only |
| `address_line1`, `address_line2` | Type `K` only (street and number, then postal code and town) |
| `country` | ISO 3166-1 alpha-2, e.g. `"CH"` |

`#lines` gives the postal lines for display. `#to_s` joins them with line
breaks.

### `SwissQr::BillingInformation` (Swico S1)

| Field | S1 tag | Type |
|---|---|---|
| `invoice_number` | `/10/` | String |
| `invoice_date` | `/11/` | Date |
| `customer_reference` | `/20/` | String |
| `vat_number` | `/30/` | String (UID digits without `CHE`) |
| `vat_dates` | `/31/` | Array of Date (one date, or start and end of a period) |
| `vat_details` | `/32/` | Array of `VatRate(rate, amount)` |
| `vat_import_taxes` | `/33/` | Array of `VatRate(rate, amount)` |
| `payment_conditions` | `/40/` | Array of `PaymentCondition(discount, days)` |
| `unknown_tags` | other tags | Hash |
| `warnings`, `raw` | | |

`SwissQr::BillingInformation.parse("//S1/10/10201409/11/190512/32/7.7/40/2:10;0:30")`
parses a string directly.

### Helpers

```ruby
SwissQr::Iban.valid?("CH44 3199 9123 0008 8901 2")    # => true
SwissQr::Iban.qr_iban?("CH4431999123000889012")       # => true
SwissQr::Iban.format("CH4431999123000889012")         # => "CH44 3199 9123 0008 8901 2"
SwissQr::Reference.valid_qrr?("210000000003139471430009017")   # => true
SwissQr::Reference.valid_scor?("RF18 5390 0754 7034")          # => true
SwissQr::Reference.build_qrr("21000000000313947143000901")           # => "210000000003139471430009017" (adds the check digit)
SwissQr::Reference.build_scor("539007547034")                        # => "RF18539007547034"
SwissQr::Reference.format_qrr("210000000003139471430009017")   # => "21 00000 00003 13947 14300 09017"
SwissQr::Reference.format_scor("RF18539007547034")             # => "RF18 5390 0754 7034"
```

## Supported specification

- **Swiss Implementation Guidelines for the QR-bill, version 2.3** (in force
  since November 2025). The payload version is `0200`.
- **Version 2.4** (in force from 14 November 2026) does not change the payload
  version, so the two cannot be told apart from the payload. Its main new rule
  (QR-IBAN with a QR reference only in CHF) is reported as a warning on
  `currency`.
- **Version 2.2 and older:** address type `K` (combined address), removed in
  2.3, is still parsed (`address_line1`, `address_line2`) with a warning.
- **Billing information:** the SIX/Swico "S1" syntax (IG Annex D).
- **Not yet published:** master version `03`, which is when the payload version
  string will start to change. It is not supported.

`docs/SPEC_NOTES.md` digests the SIX documents (IG 2.2–2.4, processing rules,
QR-IID, S1 syntax), with a source for every rule. The test fixtures in
`test/fixtures` include the payloads of the official SIX sample QR codes.

## Command line

```console
$ swiss_qr invoice.pdf scan.png        # all QR-bills in the files, as a JSON array
[
  {
    "file": "invoice.pdf",
    "version": "0200",
    "iban": "CH4431999123000889012",
    "amount": "1949.75",
    ...
  }
]
$ swiss_qr --text < payload.txt         # parse a payload (the QR code's text) from stdin
$ swiss_qr - < scan.png                 # image from stdin
$ swiss_qr --lines *.pdf                # one compact JSON object per line
$ swiss_qr --no-strict broken.png       # print invalid bills too, with their "errors"
$ swiss_qr --version
```

Each JSON object is `Bill#as_json` plus `"file"` (`"-"` for stdin). Messages
go to stderr.

| Exit status | Meaning |
|---|---|
| 0 | Every input held at least one QR-bill, and all of them were valid |
| 1 | An input held no QR-bill, or held an invalid one. With `--no-strict`, invalid bills are still printed |
| 2 | Usage error, unreadable file, or no QR code reader (`gem install qr_reader`) |

The command uses `SwissQr.reader`, so it needs `qr_reader` to be installed.

## Development

After checking out the repo, run `bin/setup` to install dependencies (this
includes `qr_reader`, `rqrcode` and `chunky_png` for the image tests). Then run
`bundle exec rake` for the tests and RuboCop. `bin/console` gives an
interactive prompt. `test/fixtures/README.md` explains how the fixtures are
generated.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
