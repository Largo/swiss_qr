# frozen_string_literal: true

module SwissQr
  # Turns a Swiss QR Code payload into a Bill. Use SwissQr.parse.
  class Parser
    include Validation

    BOM = "\uFEFF"

    def self.parse(payload, strict: true)
      new(payload).parse(strict: strict)
    end

    # Cheap check whether +text+ looks like a QR-bill payload ("SPC", a
    # line break, a four-digit version and another line break).
    def self.qr_bill?(text)
      return false unless text.respond_to?(:to_str)

      text.to_str.b.match?(/\A(?:\xEF\xBB\xBF)?SPC\r?\n\d{4}\r?\n/n)
    end

    def initialize(payload)
      raise TypeError, "payload must be a String (got #{payload.class})" unless payload.respond_to?(:to_str)

      @payload = payload.to_str
      @errors = []
      @warnings = []
    end

    def parse(strict: true)
      text = utf8(@payload)
      @raw = text.frozen? ? text : text.dup.freeze
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

    def strip_bom(text)
      return text unless text.start_with?(BOM)

      warning(:payload, "byte order mark (BOM) removed")
      text.delete_prefix(BOM)
    end

    # Splits on CR LF or LF, checks the separators and drops the trailing
    # empty lines many generators (SIX's own samples included) leave behind.
    def split_lines(text)
      crlf = text.include?("\r\n")
      if crlf && text.match?(/(?<!\r)\n/)
        error(:payload, "CR LF and LF line separators are mixed; IG 4.1.4 requires the same separator throughout")
      end
      error(:payload, "a lone CR is not a permitted line separator (use CR LF or LF)") if text.match?(/\r(?!\n)/)

      lines = text.split(/\r?\n/, -1)
      lines.pop while lines.last&.strip&.empty?
      lines
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
    # line values with empty lines as nil.
    def read_values(lines)
      check_size(lines)
      fields = line_fields(lines)
      lines.each_with_index.map do |line, index|
        field = fields.fetch(index, :payload)
        status_a = index >= MIN_LINES
        check_characters(field, line, status_a: status_a)
        value = line.strip
        warning(field, "leading or trailing whitespace removed") if value != line && !value.empty?
        value.empty? ? nil : value.freeze
      end
    end

    def check_size(lines)
      if lines.size > MAX_LINES
        error(:payload, "#{lines.size} lines; at most #{MAX_LINES} are permitted (31 + billing information + " \
                        "2 alternative procedures), the extra lines are ignored")
      end
      length = lines.sum(&:length) + lines.size - 1 # separators count as one character each (LF)
      length += lines.size - 1 if @payload.include?("\r\n")
      return if length <= MAX_PAYLOAD_LENGTH

      error(:payload, "payload is #{length} characters including separators; at most #{MAX_PAYLOAD_LENGTH} are permitted")
    end

    def line_fields(lines)
      %i[header version coding_type account] +
        address_fields(:creditor, lines[4]&.strip) +
        address_fields(:ultimate_creditor, lines[11]&.strip) +
        %i[amount currency] +
        address_fields(:debtor, lines[20]&.strip) +
        %i[reference_type reference unstructured_message trailer bill_information
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
      account = values[3] && Iban.normalize(values[3]).freeze
      check_account(values[3], account)
      {
        account: account,
        qr_iban: !account.nil? && Iban.qr_iid?(account),
        creditor: build_address(:creditor, values[4, 7], required: true),
        ultimate_creditor: build_ultimate_creditor(values[11, 7]),
        amount: parse_amount(values[18]),
        currency: values[19].tap { |currency| check_currency(currency) },
        debtor: build_address(:debtor, values[20, 7], required: false)
      }
    end

    def reference_attributes(values, attributes)
      reference_type = parse_reference_type(values[27])
      check_account_reference_type(attributes[:account], attributes[:qr_iban], reference_type, attributes[:currency])
      check_reference(reference_type, values[28])
      { reference_type: reference_type, reference: values[28] }
    end

    def additional_information(values, amount)
      message, trailer, bill_information = values[29, 3]
      alternative_procedures = values[32, 2] || []
      check_notification(amount, message)
      check_trailer(trailer)
      check_additional_information(message, bill_information)
      swico = parse_bill_information(bill_information)
      check_alternative_procedures(alternative_procedures)
      {
        unstructured_message: message, trailer: trailer, bill_information: bill_information, swico: swico,
        alternative_procedures: alternative_procedures.compact.freeze
      }
    end
  end
end
