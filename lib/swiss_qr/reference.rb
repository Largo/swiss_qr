# frozen_string_literal: true

module SwissQr
  # Payment reference helpers: the 27-digit QR reference (QRR, used with a
  # QR-IBAN) and the ISO 11649 creditor reference (SCOR, "RF..." with an
  # ordinary IBAN).
  #
  # All predicates ignore whitespace, so display-formatted references are
  # accepted. The parser itself is stricter and rejects spaces in a payload.
  module Reference
    QRR_PATTERN = /\A\d{27}\z/
    SCOR_PATTERN = /\ARF\d{2}[A-Z0-9]{1,21}\z/

    module_function

    def normalize(reference)
      reference.to_s.gsub(/[[:space:]]/, "")
    end

    # True for 27 digits with a correct modulo-10 recursive check digit that
    # are not all zeros (IG 2.3).
    def valid_qrr?(reference)
      value = normalize(reference)
      value.match?(QRR_PATTERN) && !value.match?(/\A0+\z/) &&
        Checksum.mod10_recursive(value[0, 26]) == value[26].to_i
    end

    # True for a 5-25 character creditor reference "RF" + 2 check digits +
    # up to 21 alphanumerics with valid MOD 97-10 check digits. Case-insensitive.
    def valid_scor?(reference)
      value = normalize(reference).upcase
      value.match?(SCOR_PATTERN) && Checksum.mod97(value) == 1
    end

    # Appends the check digit to up to 26 digits (left-padded with zeros):
    # <tt>build_qrr("21000000000313947143000901")</tt> => "210000000003139471430009017".
    def build_qrr(digits)
      body = normalize(digits)
      raise ArgumentError, "QR reference body must be 1-26 digits" unless body.match?(/\A\d{1,26}\z/)

      body = body.rjust(26, "0")
      "#{body}#{Checksum.mod10_recursive(body)}"
    end

    # Builds a creditor reference from up to 21 alphanumerics:
    # <tt>build_scor("539007547034")</tt> => "RF18539007547034".
    def build_scor(payload)
      body = normalize(payload).upcase
      raise ArgumentError, "creditor reference body must be 1-21 alphanumerics" unless body.match?(/\A[A-Z0-9]{1,21}\z/)

      check = 98 - Checksum.mod97("RF00#{body}")
      Kernel.format("RF%<check>02d%<body>s", check: check, body: body)
    end

    # Display form of a QR reference: "21 00000 00003 13947 14300 09017"
    # (groups of five from the right).
    def format_qrr(reference)
      value = normalize(reference)
      value.reverse.scan(/.{1,5}/).join(" ").reverse
    end

    # Display form of a creditor reference: "RF18 5390 0754 7034".
    def format_scor(reference)
      normalize(reference).upcase.scan(/.{1,4}/).join(" ")
    end

    # Display form chosen by shape (QRR if all digits, otherwise SCOR style).
    def format(reference, type = nil)
      return nil if reference.nil?

      type ||= normalize(reference).match?(/\A\d+\z/) ? :qrr : :scor
      case type
      when :qrr then format_qrr(reference)
      when :scor then format_scor(reference)
      else reference.to_s
      end
    end
  end
end
