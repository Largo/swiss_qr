# frozen_string_literal: true

require "bigdecimal"

module SwissQr
  # Field rules of the SIX "Swiss Implementation Guidelines for the QR-bill"
  # (IG 2.3, with IG 2.2 rules for the legacy combined address type "K").
  # See docs/SPEC_NOTES.md for the sources of every rule.
  #
  # Mixed into Parser; every rule records a Problem via #error or #warning.
  module Validation
    QR_TYPE = "SPC"
    VERSION = "0200"
    CODING_TYPE = "1"
    TRAILER = "EPD"
    CURRENCIES = %w[CHF EUR].freeze
    REFERENCE_TYPES = { "QRR" => :qrr, "SCOR" => :scor, "NON" => :non }.freeze

    MIN_LINES = 31
    MAX_LINES = 34
    MAX_PAYLOAD_LENGTH = 997
    MAX_INPUT_BYTES = 4096
    MAX_MESSAGE_LENGTH = 140 # unstructured message + billing information together
    MAX_ALTERNATIVE_PROCEDURE_LENGTH = 100

    # Permitted characters since IG 2.3: Basic Latin, Latin-1 Supplement,
    # Latin Extended-A, Ș ș Ț ț and the euro sign.
    INVALID_CHARACTER = /[^ -~ -ſȘ-ț€]/
    AMOUNT = /\A(?:0|[1-9]\d{0,8})\.\d{2}\z/

    # Texts that turn a bill with amount 0.00 into a "DO NOT USE FOR PAYMENT"
    # notification (IG 4.4; Romansh added in IG 2.4).
    NOTIFICATION_TEXTS = [
      "NICHT ZUR ZAHLUNG VERWENDEN",
      "NE PAS UTILISER POUR LE PAIEMENT",
      "NON UTILIZZARE PER IL PAGAMENTO",
      "DO NOT USE FOR PAYMENT",
      "BETG DUVRAR PER IL PAJAMENT"
    ].freeze

    # Elements with a fixed format, where blanks are never part of the value.
    FIXED_FORMAT_FIELDS = %i[header version coding_type account amount currency reference_type reference
                             trailer].freeze

    STRUCTURED_FIELDS = %i[type name street building_number postal_code town country].freeze
    COMBINED_FIELDS = %i[type name address_line1 address_line2 postal_code town country].freeze

    private

    def error(field, message)
      @errors << Problem.new(field: field, message: message)
      nil
    end

    def warning(field, message)
      @warnings << Problem.new(field: field, message: message)
      nil
    end

    # A QR code holds at most 2953 bytes, so a longer text cannot have come
    # from one; it is rejected before any line is looked at.
    def check_input_size!(text)
      return if text.bytesize <= MAX_INPUT_BYTES

      message = "payload is #{text.bytesize} bytes; a QR code holds at most 2953 and a QR-bill at most " \
                "#{MAX_PAYLOAD_LENGTH} characters"
      raise InvalidPayload, @errors + [Problem.new(field: :payload, message: message)]
    end

    def check_length(field, value, max, label)
      return if value.nil? || value.length <= max

      error(field, "#{label} longer than #{max} characters (#{value.length})")
    end

    # Records a character-set problem in a raw (unstripped) line. Problems in
    # status A lines (billing information, alternative procedures) are
    # warnings because the IG forbids rejecting a bill for them.
    def check_characters(field, line, status_a: false)
      bad = line.scan(INVALID_CHARACTER).uniq
      return if bad.empty?

      listed = bad.first(3).map { |c| "#{c.inspect} (U+#{c.ord.to_s(16).upcase.rjust(4, "0")})" }.join(", ")
      kind = if bad.all? do |c|
        c.match?(/[[:cntrl:]]/)
      end
               "control character not permitted"
             else
               "characters outside the permitted Latin character set"
             end
      status_a ? warning(field, "#{kind}: #{listed}") : error(field, "#{kind}: #{listed}")
    end

    # "It is not permitted to fill in the elements with blanks" (IG 4.1.3).
    # Blanks around a fixed-format element (header, IBAN, amount, codes,
    # reference, country), and a line of blanks instead of an empty line, are
    # errors. Around free text (names, street, town, message) they are only
    # warnings, because SIX's own Style Guide samples have a trailing blank
    # after a street name. Status A lines only ever get warnings.
    def check_padding(field, line, value, status_a:)
      if status_a
        warning(field, "leading or trailing blanks removed")
      elsif value.empty?
        error(field, "blanks instead of an empty line are not permitted (IG 4.1.3)")
      elsif fixed_format?(field)
        error(field, "leading or trailing blanks are not permitted (IG 4.1.3; got #{line.inspect})")
      else
        warning(field, "leading or trailing blanks removed (IG 4.1.3 does not permit padding)")
      end
    end

    def fixed_format?(field)
      FIXED_FORMAT_FIELDS.include?(field) || field.end_with?(".type", ".country")
    end

    def check_header(version, coding_type)
      if version != VERSION
        detail = if version.to_s.match?(/\A02\d\d\z/)
                   %(only "#{VERSION}" is permitted in master version 02)
                 else
                   %(version must be "#{VERSION}")
                 end
        error(:version, "#{detail} (got #{version.inspect})")
      end
      error(:coding_type, %(coding type must be "#{CODING_TYPE}" (got #{coding_type.inspect}))) if coding_type != CODING_TYPE
    end

    def check_account(raw, account)
      return error(:account, "IBAN is mandatory") if raw.nil?

      error(:account, "IBAN must be given without spaces") if raw.match?(/[[:space:]]/)
      return error(:account, "IBAN may only contain letters and digits") if raw.match?(/[^A-Za-z0-9[:space:]]/)

      warning(:account, "IBAN should be in upper case") if raw.match?(/[a-z]/)
      if !account.match?(/\A[A-Z0-9]+\z/)
        error(:account, "IBAN may only contain letters and digits")
      elsif account.match?(/\A[A-Z]{2}/) && !Iban::COUNTRIES.include?(account[0, 2])
        error(:account, "only CH and LI IBANs are permitted (got #{account[0, 2]})")
      elsif account.length != 21
        error(:account, "IBAN must be exactly 21 characters (got #{account.length})")
      elsif !account.match?(Iban::QR_BILL_PATTERN)
        error(:account, "malformed CH/LI IBAN: country, 2 check digits, 5-digit institution id, 12-character account")
      elsif Checksum.mod97(account) != 1
        error(:account, "IBAN check digits are wrong (mod 97 != 1)")
      end
    end

    def address_fields(group, code)
      fields = code == "K" ? COMBINED_FIELDS : STRUCTURED_FIELDS
      fields.map { |attr| :"#{group}.#{attr}" }
    end

    # Validates and builds an address from its seven stripped lines.
    def build_address(group, values, required:)
      if values.all?(&:nil?)
        error(group, "the #{group} (address type, name, postal code, town, country) is mandatory") if required
        return nil
      end

      code, name, line1, line2, postal_code, town, country = values
      field = ->(attr) { :"#{group}.#{attr}" }
      check_address_type(field[:type], code)
      error(field[:name], "name is mandatory") if name.nil?
      check_length(field[:name], name, 70, "name")
      if code == "K"
        check_combined_lines(field, line1, line2, postal_code, town)
      else
        check_structured_lines(field, line1, line2, postal_code, town)
        check_postal_code_prefix(field[:postal_code], postal_code, country) if postal_code
      end
      check_country(field[:country], country)
      Address.from_lines(values)
    end

    def check_address_type(field, code)
      case code
      when "S" then nil
      when "K"
        warning(field, 'address type "K" (combined address) was removed in IG 2.3 (Nov 2025); ' \
                       'only structured addresses ("S") are permitted')
      when nil then error(field, 'address type is mandatory ("S")')
      else error(field, %(address type must be "S" (or legacy "K"), got #{code.inspect}))
      end
    end

    def check_structured_lines(field, street, building_number, postal_code, town)
      check_length(field[:street], street, 70, "street")
      check_length(field[:building_number], building_number, 16, "building number")
      error(field[:postal_code], "postal code is mandatory for a structured address") if postal_code.nil?
      check_length(field[:postal_code], postal_code, 16, "postal code")
      error(field[:town], "town is mandatory for a structured address") if town.nil?
      check_length(field[:town], town, 35, "town")
    end

    # "The postal code must be provided without a country" (IG 4.2.2): a
    # country code or international vehicle code followed by "-" or a blank
    # ("CH-8000", "D-78462", "FL 9490") is an error, except where the
    # prefix is part of the country's official format ("LV-1050"). Other
    # letter prefixes followed by "-" are only suspicious.
    def check_postal_code_prefix(field, postal_code, country)
      match = postal_code.match(/\A([A-Za-z]{1,3})([- ])(?=\d)/)
      return unless match

      prefix = match[1].upcase
      separator = match[2]
      return if prefix == country&.upcase && Countries::PREFIXED_POSTAL_CODES.include?(prefix)

      if Countries.iso?(prefix) || Countries::VEHICLE_CODES.key?(prefix)
        error(field, "postal code must be given without a country prefix (got #{postal_code.inspect})")
      elsif separator == "-"
        warning(field, "postal code looks like it has a country prefix (#{postal_code.inspect})")
      end
    end

    # IG 2.2 rules for address type "K".
    def check_combined_lines(field, line1, line2, postal_code, town)
      check_length(field[:address_line1], line1, 70, "address line 1")
      error(field[:address_line2], "combined address (K) requires address line 2 (postal code and town)") if line2.nil?
      check_length(field[:address_line2], line2, 70, "address line 2")
      error(field[:postal_code], "combined address (K) must not fill postal code (it belongs in address line 2)") if postal_code
      error(field[:town], "combined address (K) must not fill town (it belongs in address line 2)") if town
    end

    def check_country(field, country)
      if country.nil?
        error(field, "country is mandatory")
      elsif !Countries.iso?(country.upcase(:ascii))
        error(field, "country must be a two-letter ISO 3166-1 code (got #{country.inspect})")
      elsif country.match?(/[a-z]/)
        error(field, "country code must be upper case (got #{country.inspect})")
      end
    end

    def build_ultimate_creditor(values)
      return nil if values.all?(&:nil?)

      error(:ultimate_creditor, "the ultimate creditor group is reserved for future use and must be empty")
      Address.from_lines(values)
    end

    def parse_amount(value)
      return nil if value.nil?

      error(:amount, amount_problem(value)) unless value.match?(AMOUNT)
      return nil unless value.match?(/\A-?\d+(?:[.,]\d+)?\z/)

      BigDecimal(value.tr(",", "."))
    end

    def amount_problem(value)
      case value
      when /,/ then %(decimal separator must be "." (got #{value.inspect}))
      when /\A-/ then "amount must not be negative (got #{value.inspect})"
      when /\A0\d/ then "amount must not have leading zeroes (got #{value.inspect})"
      when /\A\d+(?:\.\d?|\.\d{3,})?\z/ then "amount must have exactly two decimal places (got #{value.inspect})"
      when /\A\d{10,}\.\d{2}\z/ then "amount above the maximum 999999999.99 (got #{value.inspect})"
      else "amount must be a decimal such as 1949.75 (got #{value.inspect})"
      end
    end

    def check_notification(amount, message)
      return unless amount&.zero?
      return if NOTIFICATION_TEXTS.include?(message)

      error(:amount, "amount must be at least 0.01; 0.00 is only permitted for a notification whose message is " \
                     "one of #{NOTIFICATION_TEXTS.map(&:inspect).join(", ")} (IG 4.4)")
    end

    def check_currency(currency)
      if currency.nil?
        error(:currency, "currency is mandatory (CHF or EUR)")
      elsif !CURRENCIES.include?(currency)
        error(:currency, "only CHF and EUR are permitted (got #{currency})")
      end
    end

    def parse_reference_type(value)
      return error(:reference_type, "reference type is mandatory (QRR, SCOR or NON)") if value.nil?

      REFERENCE_TYPES.fetch(value) do
        error(:reference_type, "unknown reference type #{value.inspect} (QRR, SCOR or NON)")
      end
    end

    # QR-IBAN requires QRR; an ordinary IBAN forbids it.
    def check_account_reference_type(account, qr_iban, reference_type, currency)
      return if reference_type.nil? || account.nil? || !account.match?(Iban::QR_BILL_PATTERN)

      if qr_iban && reference_type != :qrr
        error(:reference_type, "a QR-IBAN requires reference type QRR (got #{reference_type.to_s.upcase})")
      elsif !qr_iban && reference_type == :qrr
        error(:reference_type, "reference type QRR requires a QR-IBAN (institution id 30000-31999); " \
                               "#{account} is an ordinary IBAN")
      elsif reference_type == :qrr && currency == "EUR"
        warning(:currency, "from IG 2.4 (in force 14 Nov 2026) a QR-IBAN with QR reference may only be used for CHF")
      end
    end

    def check_reference(type, reference)
      case type
      when :qrr then check_qrr(reference)
      when :scor then check_scor(reference)
      when :non
        error(:reference, "reference type NON must have an empty reference (got #{reference.inspect})") if reference
      end
    end

    def check_qrr(reference)
      return error(:reference, "reference type QRR requires a reference") if reference.nil?
      return error(:reference, "QR reference must not contain spaces") if reference.match?(/[[:space:]]/)
      return error(:reference, "QR reference must be numeric") unless reference.match?(/\A\d+\z/)
      return error(:reference, "QR reference must be 27 digits (got #{reference.length})") if reference.length != 27
      return error(:reference, "QR reference must not consist only of zeros") if reference.match?(/\A0+\z/)

      expected = Checksum.mod10_recursive(reference[0, 26])
      return if expected == reference[26].to_i

      error(:reference, "QR reference check digit (modulo 10 recursive) is wrong: expected #{expected}, got #{reference[26]}")
    end

    def check_scor(reference)
      problem = scor_problem(reference)
      error(:reference, problem) if problem
    end

    def scor_problem(reference)
      if reference.nil? then "reference type SCOR requires a creditor reference"
      elsif reference.match?(/[[:space:]]/) then "creditor reference must not contain spaces"
      elsif !reference.match?(/\A[A-Za-z0-9]+\z/) then "creditor reference may only contain letters and digits"
      elsif !(5..25).cover?(reference.length) then "creditor reference must be 5 to 25 characters (got #{reference.length})"
      elsif !reference.match?(/\ARF\d{2}/i) then 'creditor reference must start with "RF" and two check digits'
      elsif Checksum.mod97(reference.upcase) != 1 then "creditor reference (ISO 11649) check digits are wrong"
      end
    end

    def check_additional_information(message, bill_information)
      if message && message.length > MAX_MESSAGE_LENGTH
        check_length(:unstructured_message, message, MAX_MESSAGE_LENGTH, "unstructured message")
      elsif message.to_s.length + bill_information.to_s.length > MAX_MESSAGE_LENGTH
        error(:unstructured_message,
              "unstructured message (#{message.to_s.length}) and billing information " \
              "(#{bill_information.to_s.length}) together exceed #{MAX_MESSAGE_LENGTH} characters")
      end
    end

    def check_trailer(trailer)
      return if trailer == TRAILER

      detail = trailer.nil? ? "line 31 is empty" : "got #{trailer.inspect}"
      error(:trailer, %(trailer must be "#{TRAILER}" (#{detail}); a line may be missing or extra))
    end

    # Billing information is status A: problems are warnings only.
    def parse_bill_information(value)
      return nil if value.nil?

      unless value.start_with?("//")
        warning(:bill_information, 'billing information should start with "//" and a syntax identifier such as "S1"')
      end
      return nil unless BillInformation.s1?(value)

      info = BillInformation.parse(value)
      @warnings.concat(info.warnings)
      info
    end

    # Alternative procedures are status A: problems are warnings only.
    def check_alternative_procedures(values)
      values.each_with_index do |value, index|
        if value.nil?
          warning(:alternative_procedures, "alternative procedure #{index + 1} is empty")
        elsif value.length > MAX_ALTERNATIVE_PROCEDURE_LENGTH
          warning(:alternative_procedures,
                  "alternative procedure #{index + 1} longer than #{MAX_ALTERNATIVE_PROCEDURE_LENGTH} characters " \
                  "(#{value.length})")
        end
      end
    end
  end
end
