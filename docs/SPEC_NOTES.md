# Swiss QR-bill payload: spec notes for the parser

This is a digest of the rules a parser and validator of the Swiss QR Code payload
(`SPC` / `0200` / `1` … `EPD`) needs. It was written for the `swiss_qr` gem, and every
rule cites its primary source by short tag, version and section. Anything not confirmed
from a primary source is marked **UNVERIFIED**.

Compiled 2026-10-14 from the PDFs listed under [Sources](#sources), downloaded the same day.

---

## 0. Which version applies (as of 2026-10-14)

| IG version | Published | In force | Status today |
|---|---|---|---|
| 2.2 | 22.02.2021 | 22.02.2021 | superseded; still allowed address type `K` |
| **2.3** | 20.11.2023 | **21/22 Nov 2025** (SIC release) | **current** [IG2.3 General notes; SIX QR-bill page] |
| 2.4 | 24.02.2026 | **14 Nov 2026** (SIC release of 13 Nov 2026) | published, **not yet in force**; "Version 2.3 remains valid until November 2027" [IG2.4 General notes, "Change control"] |

- No v2.5 or newer was found (searched 2026-10-14). The SIX release cycle collects change
  requests until June, consults in Nov–Dec, publishes in February and introduces in
  November at the earliest [Δ2.3 §1.1.1 item 4].
- **The payload version string stays `0200` under 2.2, 2.3 and 2.4.** "Only the version
  designation "0200" is permitted in master version 02. From master version 03 onwards,
  depiction of sub-versions is enabled." [IG2.3 and IG2.4 §4.2.2, element `Version`].
  The IG version therefore **cannot be told from the payload**, so a parser should take
  the rule set as an option (for example `rules: :ig_2_3`, later `:ig_2_4`) instead of guessing it.
- What 2.4 changes in the payload rules:
  1. **QR-IBAN + QRR is CHF-only.** "It can only be used for invoicing and payments in
     CHF" [IG2.4 §2.10]. The QR reference "May only be used for invoices in CHF" [IG2.4 §4.2.2
     `Ref`; §2.12.1; §4.3.2]. "For invoicing in euros (EUR), only the combination IBAN/SCOR
     reference and IBAN/unstructured message is possible" [IG2.4 General notes]. Version 2.3
     has no currency restriction on QRR [IG2.3 §2.12.1, §4.2.2 `Ref`].
  2. `PstCd`/`TwnNm` of the creditor are marked `D*` with the note "Due to the obligation to
     provide a structured address, the element must always be supplied" [IG2.4 §4.2.2,
     lines 9–10]. Version 2.3 already required them in prose [IG2.3 §4.3.1].
  3. Otherwise 2.4 is textual ("field" becomes "line"), plus Romansh headings and a Romansh
     "DO NOT USE FOR PAYMENT" text [IG2.4 revision history; §4.4]. 2.4 also takes over the
     S1 billing-information syntax as "Syntax definition of SIX (Version 1.2)" [IG2.4 Annex D].

---

## 1. Payload framing

### 1.1 Encoding and character set
- The payload must be UTF-8 [IG2.3/IG2.4 §4.1.1]. Coding type `1` means "UTF-8 restricted to
  the Latin character set, see chapter 4.1.1" [IG2.4 §4.2.2 `Coding`].
- **Allowed code points** (IG ≥ 2.3) [IG2.3 §4.1.1, IG2.4 §4.1.1, Δ2.3 §1.1.4 item 1]:
  - U+0020–U+007E Basic Latin
  - U+00A0–U+00FF Latin-1 Supplement (the C1 controls U+0080–U+009F are excluded)
  - U+0100–U+017F Latin Extended-A
  - U+0218, U+0219, U+021A, U+021B (Ș ș Ț ț, with comma below)
  - U+20AC (€)

  Ruby: `/\A[ -~ -ſȘ-ț€]*\z/` per line, after splitting on
  the separators. TAB and lone CR are therefore illegal inside a value.
  (The IG2.3 PDF prints the glyph "Ț" against "LATIN SMALL LETTER T…U+021B". That is a typo:
  the code point U+021B is what counts, and IG2.4 fixed the glyph.)
- **What changed in 2.3 (the extended set).** IG2.2 §4.1.1 only says "only the Latin
  character set (unescaped) is permitted", deferring to the Swiss pain.001 IG without
  listing characters. The explicit code-point list above is new in 2.3 [Δ2.3 §1.1.4 item 1].
  SIX's factsheet: "more special characters and umlauts (diacritical characters) can now be
  used. The allowed character sets now cover all characters authorised by the federal
  administration in the register of persons", and reading aids "must … be able to process
  QR-bills with the extended character set from 22 November 2025" [FS-ERP p.1–2].
  The exact pre-2025 restricted set (the SPS pain.001 "Swiss character set") is
  **UNVERIFIED**; I did not fetch that document. It matters only if you want a "legacy
  generator" warning, so the parser should simply apply the ≥ 2.3 set.
- Character classes used in line definitions [IG2.4 §4.1.2 Table 6]: *numeric* `0–9`,
  *alphanumeric* `A–Z a–z 0–9`, *decimal* `0–9` plus `.`, *general* = the set above.
- Processing rule: field content outside the permitted set means the payment is not
  processed [PR1.2 §5.6 Table 4 #7].
- A UTF-8 BOM is not mentioned anywhere. **UNVERIFIED**; suggest stripping it with a warning.

### 1.2 Separators
- "Separated from one another with a carriage return… The following carriage returns are
  permitted: CR + LF; LF" [IG2.3/IG2.4 §4.1.4]. Δ2.3 adds: "If the data element has no content,
  there must be at least one line feed (CR + LF or LF), **but not just CR**" [Δ2.3 §1.1.4 item 2;
  IG2.2 §4.1.4 says the same].
- "**The same type of carriage return must always be used within a document**" [IG2.3/IG2.4
  §4.1.4]. Mixed CRLF/LF breaks this rule. Suggest an error in strict mode, a warning otherwise.
- "All data elements must be present. If the data element has no content, at least a new line
  must be present" [IG2.4 §4.1.4]. Positions are fixed, so an empty value is an empty line.
- "**The carriage return after the final element is eliminated**" [IG2.2/2.3/2.4 §4.1.4].
  However, **SIX's own sample QR codes violate this.** Of the 12 distinct official payloads
  decoded from the IG PDFs (see §7), 6 end with `EPD\n` or `EPD\r\n`. A tolerant parser must
  accept a trailing separator and trailing empty lines after `EPD`, the billing information
  or the alternative procedures. The Annex A tables also show empty `Billing information ¶`,
  `AV1 ¶` and `AV2` rows where those lines are unused [IG2.4 Annex A, Tables 17, 19–22].
- Lines with status **A** (additional), meaning billing information and alternative
  procedures, "are omitted if they are not used, and no further subsequent line is used"
  [IG2.4 §4.1.4, Table 7]. Valid line counts are therefore **31** (ends at `EPD`), **32**
  (+ billing info), **33** or **34** (+ 1–2 alternative procedures). Billing info must be
  present (possibly empty) when an alternative procedure follows, because positions are fixed.
- Status **A** lines "are not relevant for payment processing. QR-bills with errors in lines
  with status A may not be rejected" [IG2.4 §4.2.1 Table 7]. Errors in billing information or
  alternative procedures should therefore be **warnings**, not hard errors. PR1.2 agrees:
  invalid billing info syntax gives "Payment is processed" (#32), and the same holds when
  alternative procedure parameters are used (#33).

### 1.3 Size
- "The maximum Swiss QR Code data content permitted is **997 characters (including the element
  separators)**" [IG2.4 §6.2; same in IG2.3 §6.2]. The spec says *characters*, so count code
  points (`String#length`), not bytes. Whether a validator should count bytes instead is
  **UNVERIFIED**. The sample payloads are all ≤ 385 characters.
- Error correction level M and QR version ≤ 25 (117×117 modules) [IG2.4 §2.5, §6.1, §6.2].
  These are image properties, not payload rules.

### 1.4 Field length rule
- Lengths are maxima. "It is not permitted to fill in the elements with blanks up to the
  maximum length" [IG2.4 §4.1.3]. Padding is a violation. The gem strips blanks and records:
  - an **error** for blanks around fixed-format elements (QR type, version, coding type, IBAN,
    amount, currency, address type, country, reference type, reference, trailer), and for a
    line of blanks where an element must be empty or absent (e.g. the reserved ultimate
    creditor, the reference with `NON`);
  - a **warning** for blanks around free text (names, street, building number, postal code,
    town, message), because SIX's own Style Guide samples have `Musterstrasse ` with a
    trailing blank (fixtures `six_sg_*`), and for anything in status A lines.

---

## 2. Line-by-line data structure (IG 2.3 / 2.4 §4.2.2, Table 8)

Status codes [IG2.4 §4.2.1 Table 7]: **M** = must be present and filled; **D** = must be
filled if its (optional) group is filled; **O** = line must be present, may be empty;
**A** = omitted if unused; **X** = line must be present and **must be empty**.
(IG2.3 Table 7 misprints "A" as "B".)

| # | Element | St. | Rule (max length = characters) |
|---|---|---|---|
| 1 | `QRType` | M | Fixed `SPC` |
| 2 | `Version` | M | Fixed `0200` (4-digit numeric; only `0200` allowed in master version 02) |
| 3 | `Coding` | M | Fixed `1` |
| 4 | `CdtrInf.IBAN` | M | Exactly 21 alphanumeric characters, **no spaces**, country code `CH` or `LI` only. IBAN or QR-IBAN |
| 5 | `Cdtr.AdrTp` | M | `S` (2.3+). `K` was allowed until 2.2 (see §4) |
| 6 | `Cdtr.Name` | M | ≤ 70 |
| 7 | `Cdtr.StrtNmOrAdrLine1` | O | ≤ 70 (S: street or P.O. box; K: address line 1) |
| 8 | `Cdtr.BldgNbOrAdrLine2` | O | S: ≤ **16**; K: ≤ 70 (address line 2) |
| 9 | `Cdtr.PstCd` | D (2.4: D*, always) | ≤ 16, "without a country" code prefix |
| 10 | `Cdtr.TwnNm` | D (2.4: D*, always) | ≤ 35 |
| 11 | `Cdtr.Ctry` | M | 2-letter ISO 3166-1 (alpha-2) |
| 12–18 | `UltmtCdtr.*` (AdrTp, Name, StrtNmOrAdrLine1, BldgNbOrAdrLine2, PstCd, TwnNm, Ctry) | **X** | "The entire data group must not be filled in". All 7 lines present and empty (reserved for future use) |
| 19 | `CcyAmt.Amt` | O | Empty or decimal; see §3.4 |
| 20 | `CcyAmt.Ccy` | M | `CHF` or `EUR` |
| 21 | `UltmtDbtr.AdrTp` | D | `S` (2.2: also `K`) |
| 22 | `UltmtDbtr.Name` | D | ≤ 70 |
| 23 | `UltmtDbtr.StrtNmOrAdrLine1` | O | ≤ 70 |
| 24 | `UltmtDbtr.BldgNbOrAdrLine2` | O | S: ≤ 16; K: ≤ 70 |
| 25 | `UltmtDbtr.PstCd` | D | ≤ 16, without country code |
| 26 | `UltmtDbtr.TwnNm` | D | ≤ 35 |
| 27 | `UltmtDbtr.Ctry` | D | ISO 3166-1 alpha-2 |
| 28 | `RmtInf.Tp` | M | `QRR`, `SCOR` or `NON` (≤ 4 alphanumeric) |
| 29 | `RmtInf.Ref` | D | QRR: 27 numeric; SCOR: 5–25 alphanumeric; NON: must be empty |
| 30 | `AddInf.Ustrd` | O | ≤ 140; **combined with line 32 ≤ 140** |
| 31 | `AddInf.Trailer` | M | Fixed `EPD` |
| 32 | `AddInf.StrdBkgInf` | A | ≤ 140; combined with line 30 ≤ 140; see §5 |
| 33, 34 | `AltPmtInf.AltPmt` | A | 0–2 occurrences, each ≤ **100**; see §6 |

Sources: [IG2.4 §4.2.2 Table 8; IG2.3 §4.2.2 Table 8; IG2.2 §4.2.2 Table 7 (for K and the K length variants)].

Notes:
- Line numbers 1–34 come from the "Line" column added in IG2.4.
- **Ultimate creditor:** PR1.2 #15 says "Field for ultimate creditor has been wrongly provided
  (prior to "future use" approval)" means the payment is not processed (physical channel) or
  the element is not processed (m-banking). Suggest an error in strict mode. In lenient mode,
  parse it into `ultimate_creditor` with an error entry.
- **Creditor country:** only the IBAN is restricted to CH/LI. The creditor's address country
  is not restricted (sample: creditor in Vaduz, `LI`; debtor in Konstanz, `DE`) [IG2.4 Annex A
  examples 5–6].
- Ctry is validated against the ISO 3166-1 alpha-2 list (`SwissQr::Countries`, plus the
  user-assigned `XK` for Kosovo, which SWIFT and the IBAN registry use). ISO alpha-2 codes
  are upper case, so lowercase is an error.
- PstCd "must be provided without a country": a prefix that is an ISO code or an
  international vehicle code followed by `-` or a blank (`CH-8000`, `D-78462`, `FL 9490`) is an
  error, except where the country's official format includes it (`LV-1050`, `LT-01100`,
  `MD-2001`). Other letter prefixes followed by `-` only give a warning.
- Fields are case-sensitive except references: "The banks draw no distinction between lower
  and upper case when processing" [IG2.4 §4.2.2 `Ref`]. So validate SCOR case-insensitively.

---

## 3. Field rules in detail

### 3.1 Header
- `SPC`, `0200`, `1` must match exactly. Processing: an invalid QRType, Version or Coding
  type means the payment is not processed [PR1.2 Table 4 #4–#6; IG2.4 §7.1 "The content must
  match a valid value; this applies for QR type, the version, the coding type and the currency"].
- For `looks_like_qr_bill?`, a cheap check: the payload starts with `SPC` followed by `\r\n` or `\n`.
  Suggestion: also require a second line of the form `\d{4}`.

### 3.2 Account (IBAN / QR-IBAN)
- 21 characters, no spaces, `CH` or `LI` [IG2.3/2.4 §4.2.2 line 4]. A normalizer may strip
  spaces and upcase for the `iban` attribute, but strict validation of the raw line should
  flag spaces (IG2.3 explicitly adds "no spaces allowed" [Δ2.3 §1.1.4 item 4.1]).
- Structure of a CH/LI (QR-)IBAN: positions 1–2 country code, 3–4 check digits, **5–9 IID or
  QR-IID**, 10–21 internal account number [IID1.1 §3.2, Illustration 2]. The account part may
  contain letters: the SWIFT registry format is `CH2!n5!n12!c`, and the published LI example
  is `LI21 0881 0000 2324 013A A`. The registry entry itself is **UNVERIFIED**: swift.com
  blocked the automated download, so this comes from secondary reproductions. Validate
  positions 5–9 as digits and positions 10–21 as `[A-Z0-9]`.
- **QR-IBAN** = an IBAN whose IID (positions 5–9) is in **30000–31999** [IG2.4 §2.8, §2.10;
  IID1.1 §1.3.2, §1.3.4]. Example: `CH4431999123000889012` has IID `31999`, so it is a QR-IBAN.
- **Check digits (ISO 13616 mod-97):** move the first 4 characters to the end, replace letters
  with numbers (A=10 … Z=35), and the resulting integer mod 97 must equal 1. ISO 13616 / ISO 7064
  are paywalled, so the algorithm text is **UNVERIFIED from a primary source**. It is
  confirmed empirically against all four SIX sample IBANs (§7).
  PR1.2 #8: an invalid IBAN (structure or check digit) means the payment is not processed.

### 3.3 Reference type ⇔ account ⇔ reference
| Account | `Tp` | `Ref` | Currency |
|---|---|---|---|
| QR-IBAN | **must** be `QRR` | mandatory, 27 digits, mod-10 recursive | 2.3: CHF or EUR; **2.4: CHF only** |
| IBAN | `SCOR` | mandatory, ISO 11649 `RF…` | CHF or EUR |
| IBAN | `NON` | **must be empty** | CHF or EUR |

Sources: [IG2.4 §4.2.2 lines 28–29; §4.3.2 ("An IBAN cannot be used" with QRR; "A QR-IBAN
cannot be used" with SCOR); §7.1 bullet 4; IID1.1 §3.1 Illustration 1 (IBAN: QR reference
"Prohibited")]. PR1.2 Table 4: #10 (QR-IBAN missing with a QR reference), #26 (invalid or
missing Tp), #27 (QRR without Ref), #28 (SCOR without Ref), #29 (Ref present with NON) all
mean the payment is not processed.

**QR reference (QRR)** [IG2.4 §2.12.1, §4.2.2 `Ref`, Annex B]:
- Exactly 27 numeric characters. The 27th is a mod-10-recursive check digit over digits 1–26.
- "The reference must not consist exclusively of zeros" (new in 2.3 [Δ2.3 §1.1.2 item 2]).
- Mod-10 recursive (Annex B matrix, checked against the rendered table on IG2.4 p.60):
  ```ruby
  TABLE = [0, 9, 4, 6, 8, 2, 7, 1, 3, 5]
  carry = digits26.each_char.reduce(0) { |c, d| TABLE[(c + d.to_i) % 10] }
  check = (10 - carry) % 10
  ```
  Spec example: `21000000000313947143000901` gives check digit `7`, i.e.
  `210000000003139471430009017` [IG2.4 Annex B].
- PR1.2 #30: invalid QRR check digit means the payment is not processed.
- A QRR is printed in groups of 2 + 5×5 and a SCOR in groups of 4 [IG2.4 §3.5.4]. This only
  matters for display helpers.

**Creditor Reference (SCOR, ISO 11649)** [IG2.4 §2.12.2, §4.2.2 `Ref`]:
- 5–25 alphanumeric characters, starting with `RF`; characters 3–4 are check digits
  (2 digits); checked by "modulo 97-10".
- Algorithm (ISO 11649 is paywalled, so **UNVERIFIED from primary**; verified empirically
  against SIX samples): move the first 4 characters to the end, map letters A=10…Z=35, and
  the integer mod 97 must equal 1. Case-insensitive (upcase first).
- PR1.2 #31: an invalid SCOR check digit gives "**Payment is processed**". PR1.2 is from 2021
  and predates IG2.3. Banks are therefore lenient here, but the IG says "must". Suggest an
  error in strict mode, plus a note in the docs.
- **Erratum in SIX's own document:** the text table of IG Annex A example 4 (v2.2 Table 13,
  v2.3 Table 20, v2.4 Table 20) prints `RF720191230100405JSH0438`, which **fails** mod-97. The
  QR code embedded in the same page encodes `RF240191230100405JSH0438`, which passes. The
  printed payment-part image also shows "RF72 …". Use the QR-decoded value as the fixture and
  `RF72…` as a negative test.

### 3.4 Amount and currency
- `Ccy`: `CHF` or `EUR` only [IG2.4 §4.2.2 line 20]. Anything else (or empty) means the payment
  is not processed [PR1.2 #19].
- `Amt` [IG2.4 §4.2.2 line 19]: "entered without leading zeroes, including decimal separators and
  two decimal places. Decimal, maximum 12 digits permitted, including decimal separators. Only
  decimal points (".") are permitted as decimal separators. The amount must be between
  CHF/EUR 0.01 and 999,999,999.99." The thousands separator in the spec text is prose only.
  The payload never contains separators.
  - Regex: `/\A(?:0|[1-9]\d{0,8})\.\d{2}\z/` (max `999999999.99`, 12 characters).
  - **Empty** = the debtor fills in the amount (donation case) [IG2.4 §4.4 comments; Annex A ex. 3].
  - **`0.00` is legal despite the 0.01 minimum:** a "DO NOT USE FOR PAYMENT" notification
    *must* use amount `0.00` together with an exact text in `Ustrd` [IG2.4 §4.4 Table 10]:
    `NICHT ZUR ZAHLUNG VERWENDEN`, `NE PAS UTILISER POUR LE PAIEMENT`,
    `NON UTILIZZARE PER IL PAGAMENTO`, `DO NOT USE FOR PAYMENT`, and (2.4, in force
    1 Jan 2026) `BETG DUVRAR PER IL PAJAMENT`. "The line amount must not be left blank" for
    notifications. SIX's sample notification QR encodes `0.00` with
    `DO NOT USE FOR PAYMENT` (§7 vector N1).
    The gem accepts `0.00` only with one of the five texts (`bill.notification?`); `0.00`
    with any other message is an error, since it is below the 0.01 minimum.
  - Strict mode should reject `50`, `50.0`, `050.00`, `50,00`, `1'000.00` and `-1.00`.
    Lenient mode can still parse a BigDecimal and add an error.

### 3.5 Addresses
See §4.

### 3.6 Additional information
- `Ustrd` ≤ 140, and **`Ustrd.length + StrdBkgInf.length ≤ 140`** [IG2.4 §4.2.2 `AddInf`;
  §4.3.3]. The rule as written does not count separators between the two lines.
- 2.4 footnote: in EUR, "Supplementary information on the structured reference will not be
  forwarded to the creditor's bank" (SEPA CT after the euroSIC end, Nov 2027 at the latest)
  [IG2.4 §4.2.2 line 30; §4.3.3 fn.3]. This is informational only.

### 3.7 Trailer
- Line 31 must be exactly `EPD` [IG2.4 §4.2.2 `Trailer`]. If line 31 is not `EPD` in a
  ≥ 31-line payload, the payload is structurally broken (wrong line count or layout). The
  Processing Rules treat a sequence that does not comply with the IG as not processed
  [PR1.2 #2].

---

## 4. Address types `S` and `K`

### 4.1 `S`, structured (the only type from IG 2.3 on)
- Lines: Name (M, ≤ 70), Street (O, ≤ 70; may hold a P.O. box), Building number (O, ≤ 16),
  Postal code (≤ 16), Town (≤ 35), Country (M). "Postal code", "Town" and "Country" must
  be filled in [IG2.3/IG2.4 §4.3.1, Table 9].
- Tolerance: "For the time being, the specification of the house number … in the element
  "StrtNmOrAdrLine1" is allowed and will not be rejected" [IG2.4 §4.3.1 fn. 2]. Do **not**
  error on `"Musterstrasse 1"` with an empty building number.
- c/o lines and P.O. box details "are irrelevant for the payer" and belong in the invoice
  [IG2.4 §3.5.4]. This is layout guidance, not a payload rule.
- Ultimate debtor: the group is optional. If any of lines 21–27 is non-empty, then AdrTp,
  Name, PstCd, TwnNm and Ctry must be filled (status D), while street and building number
  stay optional [IG2.4 §4.1.5 ("If a data group is used, in those marked with "Optional",
  all sub-elements marked as "Dependent" must be filled"), §4.2.2 lines 21–27]. PR1.2 #20–#25:
  invalid type, missing compulsory data, or data present without an address type means the
  payment is not processed.
- Debtor street in EUR payments is not forwarded [IG2.4 §4.2.2 line 23]. Informational only.

### 4.2 `K`, combined (removed in IG 2.3)
Rules from IG2.2 (the last version that defined `K`) [IG2.2 §4.2.2 Table 7; §4.3.1 Table 8]:
- `StrtNmOrAdrLine1` = address line 1 (street + building number, or P.O. box), O, ≤ 70.
- `BldgNbOrAdrLine2` = address line 2 (postal code + town), ≤ **70**, "**Must be provided for
  address type "K"**".
- `PstCd` and `TwnNm`: "Combined address elements: **must not be provided**".
- `Name` and `Ctry` are mandatory (PR1.2 #13: "name, country"). PR1.2 #14 and #23: postal code
  or town wrongly provided for K means the payment is not processed (for the ultimate
  debtor, m-banking does not process those elements).

Removal and deprecation:
- IG2.3: "Removal of address type "K": Combined address fields" [Δ2.3 §1.1.4 item 4.2]. The
  2.3 and 2.4 tables allow only `"S"` [IG2.3/IG2.4 §4.2.2 lines 5, 21]. 2.4 adds "Adjustments
  due to the obligation to use the structured address" [IG2.4 revision history; §4.2.2].
- SIX factsheet: "bills with unstructured addresses (address type "K") can only be used for a
  short transitional period after 21 November 2025", and for reading aids "It is also
  recommended that the new versions of the reading aids no longer process QR-bills with
  unstructured addresses (address type "K")" [FS-ERP p.2]. The SIX QR-bill web page says "The
  introduction of the structured address … remains scheduled for November 2026" [SIX QR-bill
  page, fetched 2026-10-14]. The exact end date of K acceptance by banks is **UNVERIFIED**;
  it is probably tied to the 14 Nov 2026 release.
- **Gem behaviour (fixed design decision):** parse `K` into `Address(type: :combined,
  address_line1:, address_line2:)` with a **warning**, not an error. Under the K rules,
  non-empty `PstCd` or `TwnNm`, or an empty AdrLine2, are spec violations of K itself
  (IG2.2), so treat them as errors.
- "It is not planned to introduce the hybrid address for QR-bills" [FS-ERP p.2].

---

## 5. Billing information (`StrdBkgInf`, line 32)

General rules [IG2.4 §4.2.2 line 32, §4.3.3, Annex D]:
- Status A (omitted if unused), ≤ 140 characters, shares the 140-character budget with `Ustrd`.
- "The coding of the element always begins with "//" (slash slash) followed by the
  double-digit, abbreviated name of the proposed version of the "Structured information for
  the invoice issuer"". Syntaxes must be agreed with SIX. "At the time of publication … only
  SIX (previously Swico) has published" one: **S1** [IG2.4 Annex D notes].
- Errors here must not cause rejection (status A, §1.2). Parse unknown `//XX` prefixes as
  raw strings only (`billing_information: nil`).

### 5.1 S1 syntax (SIX, ex-Swico, Version 1.2)
Sources: [S1 v1.2 23.11.2018 (Swico, FR), pp.3–7; IG2.4 Annex D Tables 28–31 ("Syntax definition
of SIX (Version 1.2)"); IG2.2 Annex E].

Format: `//S1` followed by repeated `/<tag>/<value>`.

| Tag | Meaning | Value format |
|---|---|---|
| `/10/` | Invoice number | free text |
| `/11/` | Invoice (voucher) date | `YYMMDD`; reference date for `/40/` |
| `/20/` | Customer reference | free text |
| `/30/` | VAT number (UID) | numeric UID **without** `CHE`, separators or MWST/TVA/IVA/VAT suffix, e.g. `106017086` = CHE-106.017.086. If there are several, give the first |
| `/31/` | VAT date | `YYMMDD`, or `YYMMDDYYMMDD` (start and end) |
| `/32/` | VAT details | a single rate (`7.7`) for the whole amount, **or** a list `rate:net;rate:net` (e.g. `8:1000;2.5:51.80;7.7:250`); applies to the invoiced amount excluding discount |
| `/33/` | VAT on import | list `rate:vat_amount;…` (pure VAT amounts) |
| `/40/` | Payment conditions | list `discount_pct:days;…`; `0:n` = net payment due in n days from `/11/` |

Rules [S1 p.4; IG2.4 Table 29]:
- `/nn/` tags must appear in **ascending order**, each **at most once**.
- An empty tag is the same as an omitted tag.
- Value length is not directly limited (the 140 total applies).
- **Escaping:** a literal `/` in a value is written `\/` and a literal `\` is written `\\`
  (example 4: `/10/X.66711\/8824` = invoice number `X.66711/8824`).
- Decimals use `.`. Numbers below 1 have a leading zero (`0.3`). Dates are `YYMMDD`. List
  separator `;`, pair separator `:`.
- "The order of the data elements is not predefined" [IG2.4 Table 29] (FR: "L'ordre des
  éléments de données peut être choisi librement"). This contradicts the ascending-tag rule
  unless it refers to list items. **UNVERIFIED** reading: suggest it means items within a
  list. Parse any tag order and warn when tags are not ascending.
- Unknown tags (e.g. `/50/`) are not specified (**UNVERIFIED**). Suggest keeping them in an
  `unknown` hash with a warning.
- Tokenizing: split on unescaped `/`. After `//S1`, the stream is
  `/` tag `/` value `/` tag `/` value …; unescape `\/` and `\\` afterwards.

---

## 6. Alternative procedures (`AltPmt`, lines 33–34)

- 0 to **2** occurrences, each ≤ **100** characters, status A [IG2.4 §4.2.2 lines 33–34; §3.5.5].
- Syntax convention: first the (short) procedure name (e.g. `eBill`), then **the next
  character is the sub-element separator** (e.g. `/`), then procedure-specific data
  [IG2.4 §3.5.5; AP1.0 §2.1]. "@" is explicitly allowed [AP1.0 §2.1]. The content is
  interpreted only by the procedure provider, so the gem should keep these as raw strings.
- eBill example (provider spec, not SIX IG) [EB §3]:
  `eBill/<B|R>/<email | billRecipientID(≤17 digits) | CHE#########>[/<referencedBill>]`,
  e.g. `eBill/B/simon.muster@example.com`. `B` = invoice or rolled-over invoice, `R` = reminder.
- IG sample QR codes use the placeholders `Name AV1: UV;UltraPay005;12345` and
  `Name AV2: XY;XYService;54321`. These are dummy values; the colon and space form shows
  that the "separator" convention is not enforced.

---

## 7. Test vectors (official)

**Method.** Text tables in the IG PDFs contain typos and do not match the embedded QR codes.
So the vectors below were obtained by **decoding the QR images embedded in the SIX PDFs**
with `qr_reader` 0.0.2 (`pdfimages -png`, then `QrReader.decode_all`). They are shown
verbatim as Ruby string literals; `test/fixtures/generate.rb` rebuilds each of them
from its fields and checks the result byte for byte. PDF pages are the PDF page index.

Check-digit verification (independently of the gem's code): all IBANs pass mod-97. QR-IIDs
`31961` and `31999` are in range; `04835` and `00791` are not. QRR `…286694` and `…009017`
have correct mod-10 check digits. `RF18539007547034` and `RF240191230100405JSH0438` pass, and
`RF720191230100405JSH0438` (the text-table version) **fails**.

**V1: QR-IBAN + QRR, CHF, debtor; CRLF with trailing CRLF** (IG2.2 p.43, IG2.3 p.49, IG2.4 p.50; Annex A ex. 1)
```ruby
"SPC\r\n0200\r\n1\r\nCH6431961000004421557\r\nS\r\nMax Muster & Söhne\r\nMusterstrasse\r\n123\r\n8000\r\nSeldwyla\r\nCH\r\n\r\n\r\n\r\n\r\n\r\n\r\n\r\n50.00\r\nCHF\r\nS\r\nSimon Muster\r\nMusterstrasse\r\n1\r\n8000\r\nSeldwyla\r\nCH\r\nQRR\r\n000008207791225857421286694\r\nPayment of travel\r\nEPD\r\n"
```

**V2: QR-IBAN + QRR + S1 billing info + 2 alternative procedures; CRLF, no trailing separator** (IG2.2 p.45, IG2.3 p.51, IG2.4 p.52; Annex A ex. 2. The text table instead shows a single `eBill/B/simon.muster@example.com`)
```ruby
"SPC\r\n0200\r\n1\r\nCH4431999123000889012\r\nS\r\nMax Muster & Söhne\r\nMusterstrasse\r\n123\r\n8000\r\nSeldwyla\r\nCH\r\n\r\n\r\n\r\n\r\n\r\n\r\n\r\n1949.75\r\nCHF\r\nS\r\nSimon Muster\r\nMusterstrasse\r\n1\r\n8000\r\nSeldwyla\r\nCH\r\nQRR\r\n210000000003139471430009017\r\nOrder from 15.10.2020\r\nEPD\r\n//S1/10/1234/11/201021/30/102673386/32/7.7/40/0:30\r\nName AV1: UV;UltraPay005;12345\r\nName AV2: XY;XYService;54321"
```

**V3: IBAN + NON, no amount, no debtor (donation); LF with trailing LF** (IG2.2 p.47, IG2.3 p.53, IG2.4 p.53; Annex A ex. 3)
```ruby
"SPC\n0200\n1\nCH5204835012345671000\nS\nSample Foundation\nPO Box\n\n3001\nBern\nCH\n\n\n\n\n\n\n\n\nCHF\n\n\n\n\n\n\n\nNON\n\n\nEPD\n"
```

**V4: IBAN + SCOR; LF with trailing LF** (IG2.2 p.49, IG2.3 p.55, IG2.4 p.55; Annex A ex. 4, valid RF24 version)
```ruby
"SPC\n0200\n1\nCH5800791123000889012\nS\nMuster Krankenkasse\nMusterstrasse\n12\n8000\nSeldwyla\nCH\n\n\n\n\n\n\n\n211.00\nCHF\nS\nSarah Beispiel\nMusterstrasse\n1\n8000\nSeldwyla\nCH\nSCOR\nRF240191230100405JSH0438\n\nEPD\n"
```

**V5: creditor in LI, IBAN + SCOR** (IG2.2 p.51, IG2.3 p.57, IG2.4 p.56; Annex A ex. 5)
```ruby
"SPC\n0200\n1\nCH5800791123000889012\nS\nMax Muster & Söhne\nMusterstrasse\n123\n9490\nVaduz\nLI\n\n\n\n\n\n\n\n199.95\nCHF\nS\nSarah Beispiel\nMusterstrasse\n1\n8000\nSeldwyla\nCH\nSCOR\nRF18539007547034\n\nEPD\n"
```

**V6: debtor in DE, IBAN + SCOR** (IG2.2 p.52, IG2.3 p.59, IG2.4 p.58; Annex A ex. 6)
```ruby
"SPC\n0200\n1\nCH5800791123000889012\nS\nMax Muster & Söhne\nMusterstrasse\n123\n8000\nSeldwyla\nCH\n\n\n\n\n\n\n\n199.95\nCHF\nS\nSarah Beispiel\nMusterstrasse\n1\n78462\nKonstanz\nDE\nSCOR\nRF18539007547034\n\nEPD\n"
```

**V7: IBAN + NON, 420.00; CRLF, no trailing separator** (IG2.3 p.15 and p.47, IG2.4 p.15 and p.48; Figures 3 and 14)
```ruby
"SPC\r\n0200\r\n1\r\nCH5204835012345671000\r\nS\r\nMax Muster & Söhne\r\nMusterstrasse\r\n123\r\n8000\r\nSeldwyla\r\nCH\r\n\r\n\r\n\r\n\r\n\r\n\r\n\r\n420.00\r\nCHF\r\nS\r\nBarbara Beispiel\r\nMusterstrasse\r\n1\r\n8000\r\nSeldwyla\r\nCH\r\nNON\r\n\r\n\r\nEPD"
```

**V8: IBAN + NON + message** (IG2.3 p.29, IG2.4 p.29; Figure 10, online display)
```ruby
"SPC\r\n0200\r\n1\r\nCH5204835012345671000\r\nS\r\nMax Muster & Söhne\r\nMusterstrasse\r\n123\r\n8000\r\nSeldwyla\r\nCH\r\n\r\n\r\n\r\n\r\n\r\n\r\n\r\n50.00\r\nCHF\r\nS\r\nSarah Beispiel\r\nMusterstrasse\r\n1\r\n8000\r\nSeldwyla\r\nCH\r\nNON\r\n\r\npayment of the trip\r\nEPD"
```

**V9: full S1 with /20/ /31/ /33/ + 2 alternative procedures; LF, no trailing separator** (IG2.2 p.7, IG2.4 p.11; Figure 1)
```ruby
"SPC\n0200\n1\nCH4431999123000889012\nS\nRobert Schneider AG\nRue du Lac\n1268\n2501\nBiel\nCH\n\n\n\n\n\n\n\n1949.75\nCHF\nS\nPia-Maria Rutschmann-Schnyder\nGrosse Marktgasse\n28\n9400\nRorschach\nCH\nQRR\n210000000003139471430009017\nAuftrag vom 15.06.2020\nEPD\n//S1/10/10201409/11/200701/20/140.000-53/30/102673831/31/200615/32/7.7/33/7.7:139.40/40/0:30\nName AV1: UV;UltraPay005;12345\nName AV2: XY;XYService;54321"
```

**V10: eBill alternative procedure, CRLF** (AP1.0 p.11, Figure 1)
```ruby
"SPC\r\n0200\r\n1\r\nCH4431999123000889012\r\nS\r\nMax Muster & Söhne\r\nMusterstrasse\r\n123\r\n8000\r\nSeldwyla\r\nCH\r\n\r\n\r\n\r\n\r\n\r\n\r\n\r\n1949.75\r\nCHF\r\nS\r\nSimon Muster\r\nMusterstrasse\r\n1\r\n8000\r\nSeldwyla\r\nCH\r\nQRR\r\n210000000003139471430009017\r\nAuftrag vom 15.10.2020\r\nEPD\r\n//S1/10/1234/11/201021/30/102673386/32/7.7/40/0:30\r\neBill/B/simon.muster@example.com"
```

**V11: style guide, donation without amount, no trailing separator** (Style Guide v1.1, embedded image)
```ruby
"SPC\n0200\n1\nCH5204835012345671000\nS\nBetter World Trust\nP.O. Box\n\n3001\nBern\nCH\n\n\n\n\n\n\n\n\nCHF\n\n\n\n\n\n\n\nNON\n\n\nEPD"
```

**N1: "DO NOT USE FOR PAYMENT" notification, amount 0.00** (IG2.2 p.38, IG2.3 p.41, IG2.4 p.42; §4.4)
```ruby
"SPC\n0200\n1\nCH4431999123000889012\nS\nMax Muster & Söhne\nMusterstrasse\n123\n8000\nSeldwyla\nCH\n\n\n\n\n\n\n\n0.00\nCHF\nS\nSimon Muster\nMusterstrasse\n1\n8000\nSeldwyla\nCH\nQRR\n210000000003139471430009017\nDO NOT USE FOR PAYMENT\nEPD\n"
```

**S1 billing-information strings** (IG2.4 Annex D Table 31 = S1 v1.2 examples 1–4, verbatim):
```
//S1/10/10201409/11/190512/20/1400.000-53/30/106017086/31/180508/32/7.7/40/2:10;0:30
//S1/10/10104/11/180228/30/395856455/31/180226180227/32/3.7:400.19;7.7:553.39;0:14/40/0:30
//S1/10/4031202511/11/180107/20/61257233.4/30/105493567/32/8:49.82/33/2.5:14.85/40/0:30
//S1/10/X.66711\/8824/11/200712/20/MW-2020-04/30/107978798/32/2.5:117.22/40/3:5;1.5:20;1:40;0:60
```
Expected values for example 4: invoice number `X.66711/8824`, date 2020-07-12, customer
reference `MW-2020-04`, UID `107978798`, VAT `[[2.5, 117.22]]`, conditions
`[[3,5],[1.5,20],[1,40],[0,60]]`.

**Negative and constructed vectors (not official; derived from the rules above):**
- V4 with `RF240191230100405JSH0438` replaced by the IG text-table value `RF720191230100405JSH0438`
  must fail the SCOR check digit.
- V1 with the QR-IBAN `CH6431961000004421557` but `Tp=SCOR` must fail the reference-type
  combination rule.
- QRR `000000000000000000000000000` (27 zeros; its mod-10 check digit is 0, so it is
  "well-formed") must fail "not exclusively zeros" (IG ≥ 2.3).
- **K address (constructed from IG2.2 Table 8, no official QR found):** creditor lines 5–11
  = `K`, `Pia-Maria Rutschmann-Schnyder`, `Grosse Marktgasse 28`, `9400 Rorschach`, ``, ``, `CH`.
  This should parse with a deprecation warning.
- A payload mixing `\r\n` and `\n` violates "same type of carriage return"; it should warn
  or error depending on mode.

---

## 8. Implementation checklist (derived)

1. Strip a BOM (**UNVERIFIED** rule) and require valid UTF-8. Detect the separator from the
   first line ending (`\r\n` vs `\n`); a lone `\r` is invalid.
2. Split on `/\r?\n/`. Drop trailing empty lines beyond line 31, but **keep** an empty line 32
   if a line 33 follows. The count must be 31–34 after trimming.
3. Lines 1–3 are a structural gate. A wrong header raises `InvalidPayload` even when
   `strict: false`.
4. Line 31 must be `EPD`. If not, the layout is structurally broken.
5. Validate the character set per line, max lengths, and the ≤ 997 total.
6. IBAN: 21 characters, CH/LI, mod-97; QR-IBAN = IID 30000–31999.
7. Reference-type matrix (§3.3); QRR mod-10 and not all zeros; SCOR mod-97 (case-insensitive).
8. Amount regex; 0.00 means notification; empty means open amount. Currency CHF/EUR.
9. Addresses: S rules; K accepted with a warning plus the K-specific rules; ultimate creditor
   lines must all be empty; ultimate-debtor group "all D filled if any filled".
10. `Ustrd + StrdBkgInf ≤ 140`. Billing info and alternative-procedure problems are
    **warnings** (status A must not cause rejection). Parse `//S1` into `BillingInformation`.
11. Optional rule-set switch: under IG 2.4 (from 2026-11-14), QRR/QR-IBAN with EUR is an error.

---

## Sources

| Tag | Document | Version / date | URL |
|---|---|---|---|
| IG2.4 | SIX, *Swiss Implementation Guidelines for the QR-bill* | 2.4, 24.02.2026, valid from 14 Nov 2026 | https://www.six-group.com/dam/download/banking-services/standardization/qr-bill/ig-qr-bill-v2.4-en.pdf |
| IG2.3 | same | 2.3, 20.11.2023, valid from 21 Nov 2025 | https://www.six-group.com/dam/download/banking-services/standardization/qr-bill/ig-qr-bill-v2.3-en.pdf |
| IG2.2 | same | 2.2, 22.02.2021 | https://www.six-group.com/dam/download/banking-services/standardization/qr-bill/ig-qr-bill-v2.2-en.pdf |
| Δ2.3 | SIX, *Delta Guide QR-bill 2.2 → 2.3* | 2.3, 20.11.2023 | https://www.six-group.com/dam/download/banking-services/standardization/qr-bill/ig-qr-bill-delta-guide-v2.3-en.pdf |
| PR1.2 | SIX, *Processing Rules for QR-bills* | 1.2, 04.10.2021 | https://www.six-group.com/dam/download/banking-services/standardization/qr-bill/processing-rules-qr-bill-v1.2-en.pdf |
| IID1.1 | SIX, *Technical information about the QR-IID and QR-IBAN* | 1.1, 29.02.2020 | https://www.six-group.com/dam/download/banking-services/standardization/qr-bill/qr-iid-iban-en.pdf |
| S1 | Swico, *Définition syntaxique des informations de facturation (S1)* | 1.2, 23.11.2018 | https://www.swico.ch/media/filer_public/1c/cd/1ccd7062-fc69-40f8-be3f-2a3ba9048c5f/v2_qr-bill-s1-syntax-fr.pdf |
| FS-ERP | SIX, *QR-bill transition period 2025–2026: ERP/payment software providers* | 19.08.2025 | https://www.six-group.com/dam/download/banking-services/standardization/qr-bill/factsheet-qr-bill-transition-period-erp-en.pdf |
| AP1.0 | SIX, *Using the Alternative Procedures* | 1.0, 20.05.2022 | https://www.six-group.com/dam/download/banking-services/standardization/qr-bill/alternative-procedures-en.pdf |
| SG1.1 | SIX, *QR-bill Style Guide* | 1.1, Dec 2025 | https://www.six-group.com/dam/download/banking-services/standardization/qr-bill/style-guide-qr-bill-en.pdf |
| EB | SIX/eBill, *Specification on the Use of the Alternative Scheme eBill in the Swiss QR Code* | D0543-EN-01, 03.02.2020 | https://ebill.ch/dam/downloads/network-partner/qr-bill/ebill-qr-code-specifications-en.pdf |
| SIX page | SIX QR-bill standards page (version status, dates) | fetched 2026-10-14 | https://www.six-group.com/en/products-services/banking-services/payment-standardization/standards/qr-bill.html |

Not obtained, so the related rules are marked UNVERIFIED: ISO 13616 (IBAN), ISO 7064 (mod 97-10)
and ISO 11649 (RF) are paywalled; the SWIFT IBAN Registry (automated download blocked); the
SPS pain.001 IG (pre-2.3 character set).
