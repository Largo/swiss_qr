# frozen_string_literal: true

module SwissQr
  # Turns a Swiss QR Code payload into a Bill. Use SwissQr.parse.
  class Parser
    include Validation

    BOM = "\uFEFF"
    # Encodings that QR decoders commonly (and wrongly, for coding type 1)
    # tag byte-mode segments with; valid UTF-8 bytes in them are UTF-8.
    MISTAGGED_ENCODINGS = [Encoding::ISO_8859_1, Encoding::Windows_1252].freeze
    # Header lines as parse recognizes them (blanks around SPC and the
    # version are tolerated here so that looks_like_qr_bill? never skips what parse
    # would report as an invalid QR-bill).
    HEADER = /\A(?:\xEF\xBB\xBF)?[ \t]*SPC[ \t]*\r?\n[ \t]*\d{4}[ \t]*\r?\n/n

    def self.parse(payload, strict: true)
      new(payload).parse(strict: strict)
    end

    # Cheap check whether +text+ looks like a QR-bill payload ("SPC", a
    # line break, a four-digit version and another line break).
    def self.looks_like_qr_bill?(text)
      return false unless text.respond_to?(:to_str)

      text = text.to_str
      text.b.match?(HEADER) || (!text.encoding.ascii_compatible? && utf8_bytes(text).match?(HEADER))
    end

    # The UTF-8 bytes of a UTF-16/UTF-32 string, for the byte-level match.
    def self.utf8_bytes(text)
      text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).b
    rescue EncodingError
      text.b
    end
    private_class_method :utf8_bytes

    def initialize(payload)
      raise TypeError, "payload must be a String (got #{payload.class})" unless payload.respond_to?(:to_str)

      @payload = payload.to_str
      @errors = []
      @warnings = []
    end

    def parse(strict: true)
      text = utf8(@payload)
      @raw = text.frozen? ? text : text.dup.freeze
      check_input_size!(text)
      text = strip_bom(text)
      lines = split_lines(text)
      check_structure!(lines)
      values = read_values(lines)
      bill = build_bill(values)
      raise InvalidPayload.new(bill.errors, bill: bill) if strict && !bill.valid?

      bill
    end

    private

    def utf8(text)
      return text if text.encoding == Encoding::UTF_8 && text.valid_encoding?

      text = text.dup
      if [Encoding::BINARY, Encoding::US_ASCII, Encoding::UTF_8].include?(text.encoding)
        text.force_encoding(Encoding::UTF_8)
      elsif mistagged_utf8?(text)
        warning(:payload, "payload tagged #{text.encoding} is valid UTF-8 and was read as UTF-8 (coding type 1)")
        text.force_encoding(Encoding::UTF_8)
      else
        begin
          text = text.encode(Encoding::UTF_8)
        rescue EncodingError
          text.force_encoding(Encoding::UTF_8)
        end
      end
      return text if text.valid_encoding?

      error(:payload, "payload is not valid UTF-8")
      text.scrub("\uFFFD")
    end

    # QR byte segments without an ECI are ISO-8859-1 by default, so many
    # decoders tag a QR-bill's UTF-8 bytes that way; transcoding them would
    # turn "ö" into "Ã¶".
    def mistagged_utf8?(text)
      MISTAGGED_ENCODINGS.include?(text.encoding) && !text.ascii_only? &&
        text.dup.force_encoding(Encoding::UTF_8).valid_encoding?
    end

    def strip_bom(text)
      return text unless text.start_with?(BOM)

      warning(:payload, "byte order mark (BOM) removed")
      text.delete_prefix(BOM)
    end

    # Drops the final line break and trailing empty (or blank) lines that
    # many generators (SIX's own samples included) leave behind, then splits
    # on CR LF or LF and checks the separators between the remaining lines.
    def split_lines(text)
      body = text.sub(/(?:\r\n|\n|\r)\s*\z/, "")
      @crlf = body.include?("\r\n")
      if @crlf && body.match?(/(?<!\r)\n/)
        error(:payload, "CR LF and LF line separators are mixed; IG 4.1.4 requires the same separator throughout")
      end
      error(:payload, "a lone CR is not a permitted line separator (use CR LF or LF)") if body.match?(/\r(?!\n)/)

      body.split(/\r?\n/, -1)
    end

    def check_structure!(lines)
      header = lines.first&.strip
      if header != QR_TYPE
        message = header.nil? ? "empty payload" : %(QR type must be "#{QR_TYPE}" (got #{header[0, 20].inspect}))
        raise InvalidPayload, @errors + [Problem.new(field: :header, message: message)]
      end
      return if lines.size >= MIN_LINES

      message = "only #{lines.size} lines (not counting trailing empty lines); " \
                "a QR-bill has #{MIN_LINES} to #{MAX_LINES} lines ending with the trailer #{TRAILER.inspect}"
      raise InvalidPayload, @errors + [Problem.new(field: :payload, message: message)]
    end

    # Checks character set, padding and overall size; returns the stripped
    # line values with empty lines as nil. Lines beyond MAX_LINES are
    # reported by check_size and otherwise ignored.
    def read_values(lines)
      check_size(lines)
      lines = lines.first(MAX_LINES)
      fields = line_fields(lines)
      lines.each_with_index.map do |line, index|
        field = fields.fetch(index, :payload)
        status_a = index >= MIN_LINES
        check_characters(field, line, status_a: status_a)
        value = line.strip
        check_padding(field, line, value, status_a: status_a) if value != line
        value.empty? ? nil : value.freeze
      end
    end

    def check_size(lines)
      if lines.size > MAX_LINES
        error(:payload, "#{lines.size} lines; at most #{MAX_LINES} are permitted (31 + billing information + " \
                        "2 alternative procedures), the extra lines are ignored")
      end
      length = lines.sum(&:length) + lines.size - 1 # separators count as one character each (LF)
      length += lines.size - 1 if @crlf
      return if length <= MAX_PAYLOAD_LENGTH

      error(:payload, "payload is #{length} characters including separators; at most #{MAX_PAYLOAD_LENGTH} are permitted")
    end

    def line_fields(lines)
      %i[header version coding_type iban] +
        address_fields(:creditor, lines[4]&.strip) +
        address_fields(:ultimate_creditor, lines[11]&.strip) +
        %i[amount currency] +
        address_fields(:debtor, lines[20]&.strip) +
        %i[reference_type reference unstructured_message trailer billing_information
           alternative_procedures alternative_procedures]
    end

    # Fields are validated in line order so that errors come out in that order.
    def build_bill(values)
      check_header(values[1], values[2])
      attributes = { version: values[1], coding_type: values[2] }
      attributes.merge!(parties_and_amount(values))
      attributes.merge!(reference_attributes(values, attributes))
      attributes.merge!(additional_information(values, attributes[:amount]))
      Bill.new(**attributes, errors: @errors.dup.freeze, warnings: @warnings.dup.freeze, raw: @raw)
    end

    def parties_and_amount(values)
      iban = values[3] && Iban.normalize(values[3]).freeze
      check_iban(values[3], iban)
      {
        iban: iban,
        qr_iban: !iban.nil? && Iban.qr_iid?(iban),
        creditor: build_address(:creditor, values[4, 7], required: true),
        ultimate_creditor: build_ultimate_creditor(values[11, 7]),
        amount: parse_amount(values[18]),
        currency: values[19].tap { |currency| check_currency(currency) },
        debtor: build_address(:debtor, values[20, 7], required: false)
      }
    end

    def reference_attributes(values, attributes)
      reference_type = parse_reference_type(values[27])
      check_iban_reference_type(attributes[:iban], attributes[:qr_iban], reference_type, attributes[:currency])
      check_reference(reference_type, values[28])
      { reference_type: reference_type, reference: values[28] }
    end

    def additional_information(values, amount)
      message, trailer, raw_billing_information = values[29, 3]
      alternative_procedures = values[32, 2] || []
      check_notification(amount, message)
      check_trailer(trailer)
      check_additional_information(message, raw_billing_information)
      billing_information = parse_billing_information(raw_billing_information)
      check_alternative_procedures(alternative_procedures)
      {
        unstructured_message: message, trailer: trailer, raw_billing_information: raw_billing_information,
        billing_information: billing_information,
        alternative_procedures: alternative_procedures.compact.freeze
      }
    end
  end
end
