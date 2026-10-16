# Changelog

## [Unreleased]

## [0.1.0] - 2026-10-16

First release.

- `SwissQr.parse(payload, strict: true)` parses the payload of the Swiss QR
  Code on a Swiss QR-bill (SIX Implementation Guidelines 2.3/2.4, `SPC` /
  `0200`) into immutable `Data` objects: `Bill`, `Address` and
  `BillingInformation` (Swico S1). `SwissQr.valid?` and
  `SwissQr.looks_like_qr_bill?` go with it.
- Every rule of the guidelines is validated: IBAN and QR-IBAN check digits,
  reference type against account, QR reference (mod 10 recursive), ISO 11649
  creditor reference, amount, currency, addresses, field lengths, character
  set, the 997-character limit and line separators. Problems come back per
  field as errors and warnings; `strict: false` returns the bill with them.
  Deviations real generators make (CR LF or LF, a final line break, trailing
  empty lines, a byte order mark) are accepted.
- `SwissQr.read` and `SwissQr.read_all` find QR-bills in images and PDFs
  through a pluggable reader: qr_reader 0.0.3 or newer by default (optional,
  loaded on first use), or any object with `decode_all` or any callable. A
  `String` input is always a file path; image bytes come as an IO.
- `swiss_qr` command: prints the bills in images, PDFs or a payload as JSON.
- Runs on MRI 3.3 to 4.0, JRuby 10 and TruffleRuby (tested in CI), and on
  ruby.wasm with bigdecimal-pure.
