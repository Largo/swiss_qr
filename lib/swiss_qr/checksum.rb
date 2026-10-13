# frozen_string_literal: true

module SwissQr
  # Check-digit algorithms used by IBANs and payment references.
  module Checksum
    # Carry table of the modulo-10 recursive algorithm (IG QR-bill Annex B).
    MOD10_TABLE = [0, 9, 4, 6, 8, 2, 7, 1, 3, 5].freeze

    module_function

    # Check digit (0-9) of a digit string, modulo 10 recursive.
    def mod10_recursive(digits)
      carry = digits.each_char.reduce(0) { |c, d| MOD10_TABLE[(c + d.to_i) % 10] }
      (10 - carry) % 10
    end

    # ISO 7064 MOD 97-10 remainder as used by IBAN (ISO 13616) and the
    # creditor reference (ISO 11649): the first four characters move to the
    # end and letters become 10..35. The value is valid when the result is 1.
    # +value+ must consist of A-Z and 0-9 only.
    def mod97(value)
      rearranged = value[4..] + value[0, 4]
      rearranged.each_char.reduce(0) do |rem, char|
        number = char.to_i(36)
        ((rem * (number > 9 ? 100 : 10)) + number) % 97
      end
    end
  end
end
