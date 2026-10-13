# frozen_string_literal: true

require "bigdecimal"
require "date"

module SwissQr
  # Structured billing information in the SIX/Swico "S1" syntax
  # (QR-bill line 32, starting with "//S1/").
  #
  #   //S1/10/10201409/11/190512/20/1400.000-53/30/106017086/31/180508/32/7.7/40/2:10;0:30
  #
  # Tags: /10/ invoice number, /11/ invoice date, /20/ customer reference,
  # /30/ VAT number (UID without "CHE"), /31/ VAT date or period, /32/ VAT
  # rate(s), /33/ VAT on imports, /40/ payment conditions. A literal "/" in
  # a value is written "\/", a literal "\" as "\\". Unknown tags are kept
  # in +unknown_tags+. Problems never make the bill invalid (billing
  # information has status A in the IG); they are collected in +warnings+.
  BillInformation = Data.define(
    :raw, :invoice_number, :invoice_date, :customer_reference, :vat_number,
    :vat_dates, :vat_details, :vat_import_taxes, :payment_conditions,
    :unknown_tags, :warnings
  ) do
    def self.prefix = "//S1/"

    # True when +text+ uses the S1 syntax.
    def self.s1?(text) = text.is_a?(String) && text.start_with?(prefix)

    # Parses an S1 billing-information string. Raises ArgumentError unless
    # it starts with "//S1/".
    def self.parse(text)
      raise ArgumentError, "S1 billing information must start with #{prefix.inspect}" unless s1?(text)

      self::S1Parser.new(text).parse
    end

    # Decimal for JSON: "7.7", "100", "12.5".
    def self.decimal_string(value)
      return nil if value.nil?

      string = value.to_s("F")
      string.end_with?(".0") ? string[0..-3] : string
    end

    def to_h(&)
      hash = super().merge(
        vat_details: vat_details&.map(&:to_h),
        vat_import_taxes: vat_import_taxes&.map(&:to_h),
        payment_conditions: payment_conditions&.map(&:to_h),
        warnings: warnings.map(&:to_h)
      )
      block_given? ? hash.to_h(&) : hash
    end

    def as_json(*)
      {
        "raw" => raw,
        "invoice_number" => invoice_number,
        "invoice_date" => invoice_date&.iso8601,
        "customer_reference" => customer_reference,
        "vat_number" => vat_number,
        "vat_dates" => vat_dates&.map(&:iso8601),
        "vat_details" => vat_details&.map(&:as_json),
        "vat_import_taxes" => vat_import_taxes&.map(&:as_json),
        "payment_conditions" => payment_conditions&.map(&:as_json),
        "unknown_tags" => unknown_tags,
        "warnings" => warnings.map(&:as_json)
      }
    end
  end

  class BillInformation
    # One VAT rate in percent and the amount it applies to (/32/: net
    # amount, or nil when one rate covers the whole bill; /33/: VAT amount).
    VatRate = Data.define(:rate, :amount) do
      def as_json(*)
        { "rate" => BillInformation.decimal_string(rate), "amount" => BillInformation.decimal_string(amount) }
      end
    end

    # Discount in percent when paid within +days+ days of the invoice date
    # (+discount+ 0 = net payment term).
    PaymentCondition = Data.define(:discount, :days) do
      def as_json(*)
        { "discount" => BillInformation.decimal_string(discount), "days" => days }
      end
    end

    # Tokenizer and value parser behind BillInformation.parse.
    # @api private
    class S1Parser
      FIELD = :bill_information
      KNOWN_TAGS = %w[10 11 20 30 31 32 33 40].freeze
      DECIMAL = /\A\d+(?:\.\d+)?\z/

      def initialize(text)
        @text = text
        @warnings = []
      end

      def parse
        values = collect_tags
        BillInformation.new(
          raw: @text.dup.freeze,
          invoice_number: values["10"],
          invoice_date: values["11"] && parse_dates(values["11"], "/11/ invoice date", max: 1)&.first,
          customer_reference: values["20"],
          vat_number: values["30"] && parse_uid(values["30"]),
          vat_dates: values["31"] && parse_dates(values["31"], "/31/ VAT date", max: 2),
          vat_details: values["32"] && parse_vat_details(values["32"]),
          vat_import_taxes: values["33"] && parse_pairs(values["33"], "/33/ VAT on imports"),
          payment_conditions: values["40"] && parse_conditions(values["40"]),
          unknown_tags: values.except(*KNOWN_TAGS).freeze,
          warnings: @warnings.freeze
        )
      end

      private

      def warn(message)
        @warnings << Problem.new(field: FIELD, message: message)
        nil
      end

      # Splits on unescaped "/" and unescapes "\/" and "\\".
      def tokens
        result = [+""]
        chars = @text[(BillInformation.prefix.length - 1)..].each_char
        loop do
          char = chars.next
          if char == "\\"
            following = begin
              chars.next
            rescue StopIteration
              ""
            end
            result.last << (%w[/ \\].include?(following) ? following : "\\#{following}")
          elsif char == "/"
            result << +""
          else
            result.last << char
          end
        end
        result.drop(1)
      end

      def collect_tags
        values = {}
        previous = nil
        tokens.each_slice(2) do |tag, value|
          next if tag.empty? && value.nil?
          next unless valid_tag?(tag, previous)

          previous = tag
          if values.key?(tag)
            warn("tag /#{tag}/ appears more than once; the first value is used")
          elsif !value.nil? && !value.empty?
            values[tag] = value.freeze
          end
        end
        values
      end

      def valid_tag?(tag, previous)
        unless tag.match?(/\A\d{2}\z/)
          warn("#{tag.inspect} is not a two-digit S1 tag")
          return false
        end
        warn("tag /#{tag}/ is not one of #{KNOWN_TAGS.join(", ")}; kept in unknown_tags") unless KNOWN_TAGS.include?(tag)
        warn("tag /#{tag}/ after /#{previous}/: S1 tags must be in ascending order") if previous && tag <= previous
        true
      end

      def parse_dates(value, label, max:)
        unless value.match?(/\A(?:\d{6}){1,#{max}}\z/)
          return warn("#{label} must be #{max == 1 ? "YYMMDD" : "YYMMDD or YYMMDDYYMMDD"} (got #{value.inspect})")
        end

        dates = value.scan(/\d{6}/).map do |yymmdd|
          Date.new(2000 + yymmdd[0, 2].to_i, yymmdd[2, 2].to_i, yymmdd[4, 2].to_i)
        rescue Date::Error
          return warn("#{label} #{yymmdd} is not a calendar date")
        end
        dates.freeze
      end

      def parse_uid(value)
        warn("/30/ VAT number should be the 9 UID digits without CHE (got #{value.inspect})") unless value.match?(/\A\d{9}\z/)
        value
      end

      # "/32/7.7" (one rate for the whole amount) or "8:1000;2.5:51.80".
      def parse_vat_details(value)
        return [BillInformation::VatRate.new(rate: BigDecimal(value), amount: nil)].freeze if value.match?(DECIMAL)

        parse_pairs(value, "/32/ VAT details")
      end

      def parse_pairs(value, label)
        pairs = split_pairs(value, label)
        pairs&.map do |rate, amount|
          return warn("#{label}: #{rate}:#{amount} is not rate:amount") unless rate.match?(DECIMAL) && amount.match?(DECIMAL)

          BillInformation::VatRate.new(rate: BigDecimal(rate), amount: BigDecimal(amount))
        end&.freeze
      end

      def parse_conditions(value)
        pairs = split_pairs(value, "/40/ payment conditions")
        pairs&.map do |discount, days|
          unless discount.match?(DECIMAL) && days.match?(/\A\d+\z/)
            return warn("/40/ payment conditions: #{discount}:#{days} is not discount:days")
          end

          BillInformation::PaymentCondition.new(discount: BigDecimal(discount), days: days.to_i)
        end&.freeze
      end

      def split_pairs(value, label)
        pairs = value.split(";").map { |item| item.split(":", -1) }
        return pairs unless pairs.empty? || pairs.any? { |pair| pair.size != 2 }

        warn("#{label} must be a list of a:b pairs separated by \";\" (got #{value.inspect})")
      end
    end
  end
end
