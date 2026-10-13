# frozen_string_literal: true

module SwissQr
  # Base class of every error raised by this gem.
  class Error < StandardError; end

  # One violation of the QR-bill rules.
  #
  # +field+ is a Symbol naming the offending element, e.g. +:account+,
  # +:"creditor.name"+, +:reference+ or +:payload+ (for problems with the
  # payload as a whole: size, line count, separators, encoding).
  Problem = Data.define(:field, :message) do
    def initialize(field:, message:)
      super(field: field.to_sym, message: message.to_s.dup.freeze)
    end

    # True when this problem concerns +name+ or an element nested in it
    # (+problem.about?(:creditor)+ matches +:"creditor.name"+).
    def about?(name)
      name = name.to_s
      field.to_s == name || field.to_s.start_with?("#{name}.")
    end

    def to_s = "#{field}: #{message}"

    def as_json(*) = { "field" => field.to_s, "message" => message }
  end

  # Raised when a payload is not a valid Swiss QR-bill.
  #
  # With <tt>strict: true</tt> it is raised for any rule violation; with
  # <tt>strict: false</tt> only when the payload is not even structurally a
  # QR-bill (wrong QR type, fewer than 31 lines). #bill holds the partially
  # parsed bill when there is one.
  class InvalidPayload < Error
    attr_reader :errors, :bill

    def initialize(errors, bill: nil)
      @errors = Array(errors).freeze
      @bill = bill
      super(build_message)
    end

    private

    def build_message
      return "invalid QR-bill payload" if errors.empty?

      shown = errors.first(3).map(&:to_s)
      shown << "#{errors.size - 3} more" if errors.size > 3
      "invalid QR-bill payload: #{shown.join("; ")}"
    end
  end

  # Raised when no QR code reader is configured and the default one, the
  # +qr_reader+ gem, cannot be loaded.
  class ReaderUnavailable < Error; end
end
