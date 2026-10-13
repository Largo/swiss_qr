# frozen_string_literal: true

module SwissQr
  # IBAN helpers. A QR-bill account is a Swiss (CH) or Liechtenstein (LI)
  # IBAN of exactly 21 characters; a QR-IBAN is one whose institution
  # identification (positions 5-9) lies in 30000..31999.
  module Iban
    # Shape of any IBAN (country, check digits, 11-30 character BBAN).
    PATTERN = /\A[A-Z]{2}\d{2}[A-Z0-9]{11,30}\z/
    # Shape of a CH/LI IBAN: country, check digits, 5-digit IID, 12-character account.
    QR_BILL_PATTERN = /\A(?:CH|LI)\d{2}\d{5}[A-Z0-9]{12}\z/
    QR_IID_RANGE = (30_000..31_999)
    COUNTRIES = %w[CH LI].freeze

    module_function

    # Removes all whitespace and upcases ASCII letters (only those: "ſ" must
    # not turn into "S").
    def normalize(iban)
      iban.to_s.gsub(/[[:space:]]/, "").upcase(:ascii)
    end

    # True for any IBAN with a valid structure and MOD 97-10 check digits.
    # Spaces and lower case are tolerated.
    def valid?(iban)
      value = normalize(iban)
      value.match?(PATTERN) && Checksum.mod97(value) == 1
    end

    # True for a valid CH/LI IBAN usable on a QR-bill (QR-IBAN or ordinary).
    def qr_bill_account?(iban)
      value = normalize(iban)
      value.match?(QR_BILL_PATTERN) && Checksum.mod97(value) == 1
    end

    # True for a valid CH/LI QR-IBAN (institution id 30000..31999).
    def qr_iban?(iban)
      qr_bill_account?(iban) && qr_iid?(normalize(iban))
    end

    # True when a CH/LI-shaped IBAN carries a QR-IID; check digits are not
    # verified.
    def qr_iid?(iban)
      value = normalize(iban)
      value.match?(QR_BILL_PATTERN) && QR_IID_RANGE.cover?(value[4, 5].to_i)
    end

    # The institution identification (positions 5-9) of a CH/LI IBAN.
    def iid(iban)
      value = normalize(iban)
      value[4, 5] if value.match?(QR_BILL_PATTERN)
    end

    # Groups of four for display: "CH44 3199 9123 0008 8901 2".
    def format(iban)
      normalize(iban).scan(/.{1,4}/).join(" ")
    end
  end
end
