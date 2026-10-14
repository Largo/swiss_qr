# Test fixtures

`generate.rb` creates everything in this directory except this README and
`images/SOURCES.md`. To change a fixture, edit `generate.rb` and run:

    bundle exec ruby test/fixtures/generate.rb              # payloads and images (a few seconds)
    bundle exec ruby test/fixtures/generate.rb --no-images

Payload files are written byte for byte as UTF-8. Line endings matter, so read
them with `File.binread(path).force_encoding("UTF-8")` rather than `File.read`
in text mode.

## payloads/valid/NAME.txt and NAME.json

Every `.txt` must parse with `strict: true` and give no errors. The `.json`
shows the expected `Bill#to_h` with these conventions:

- Keys that start with `_` (`_source`, `_note`) are comments. Tests ignore them.
- Fields are whitespace-stripped, and an empty field becomes `null`. Some SIX
  sample codes carry `"Musterstrasse "`, which is expected as `"Musterstrasse"`.
- `amount` is a decimal string such as `"50.00"`, or `null` when the amount is
  open. Compare numerically: `BigDecimal(expected) == bill.amount`. The same
  goes for the Swico rates and amounts. `"0.00"` is valid: SIX's "DO NOT USE
  FOR PAYMENT" notifications require it (IG §4.4).
- Symbols become strings: `reference_type` is `"qrr" | "scor" | "non"` and
  address `type` is `"structured" | "combined"`.
- `iban` is normalised (no spaces, upper case). `reference` is kept exactly
  as given, including the lower-case `scor_lowercase` fixture.
- `ultimate_creditor` is always `null` in valid fixtures. `raw` is not listed,
  because it is the `.txt` itself.
- `swico` is `null` unless `billing_information` starts with `//S1/`. Its shape:
  - Missing tags are `null`.
  - Dates are ISO `YYYY-MM-DD`.
  - `vat_dates` holds one or two dates, from `/31/`.
  - `vat_details` comes from `/32/` and `vat_import_taxes` from `/33/`. Both are
    lists of `{rate, amount}`. A single-rate `/32/7.7` gives `amount: null`.
  - `payment_conditions` comes from `/40/` as a list of `{discount, days}`, with
    `days` an Integer.
  - `\/` and `\\` are unescaped.
- `errors` is always `[]`.
- `warnings` lists `{field}` entries that **must** be present. Extra warnings
  are fine, for example for blank padding. Messages are free-form, so only
  `field` is compared. Current warning fields:
  - `creditor.type` and `debtor.type` for a legacy combined "K" address.
  - `alternative_procedures` for an over-long alternative procedure. Status A
    lines must not cause rejection (IG §4.2.1).

## payloads/invalid/NAME.txt and NAME.reason

Every `.txt` must fail `SwissQr.valid?` and raise `SwissQr::InvalidPayload`
under `strict: true`. The `.reason` file is one line in this format:

    [fatal] field[|field...]: human explanation

- `field` lists the acceptable `Problem#field` values. At least one error must
  have one of these fields, or be nested under one: `creditor` matches
  `creditor.name`. The field names used are:
  - `header`, `version`, `coding_type`
  - `iban`
  - `creditor.<attr>`, `ultimate_creditor`, `debtor.<attr>`
  - `amount`, `currency`
  - `reference_type`, `reference`
  - `unstructured_message`, `billing_information`, `alternative_procedures`
  - `trailer`
  - `payload`, for size, line count, character set or separators as a whole
- `[fatal]` marks payloads that are not structurally a QR-bill: the QR type is
  not `SPC`, or there are fewer than 31 lines. These must raise
  `InvalidPayload` even with `strict: false`, and `SwissQr.looks_like_qr_bill?` should be
  false for the non-`SPC` ones. Without `[fatal]`, `strict: false` must return a
  Bill whose `errors` include the field.

## payloads/swico/NAME.txt and NAME.json

A bare "Billing information" line. The `.json` is the expected
`SwissQr::BillingInformation#to_h`, with the same conventions as `swico` above.

## images/

PNG and PDF renderings of some valid payloads, verified with `QrReader`. See
`images/SOURCES.md` and `images/expected.json`.
