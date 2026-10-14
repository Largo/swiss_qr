# frozen_string_literal: true

require "bigdecimal"

module SwissQr
  # A parsed Swiss QR-bill payload. Immutable.
  #
  # [version, coding_type] "0200" and "1"
  # [account]              IBAN or QR-IBAN, without spaces, upper case
  # [qr_iban]              true when +account+ is a QR-IBAN (also #qr_iban?)
  # [creditor]             Address
  # [ultimate_creditor]    Address or nil (reserved by SIX, must be empty)
  # [amount]               BigDecimal, or nil when the payer fills in the amount
  # [currency]             "CHF" or "EUR"
  # [debtor]               Address or nil
  # [reference_type]       :qrr, :scor or :non
  # [reference]            QR or creditor reference as given, or nil
  # [unstructured_message] free text or nil
  # [trailer]              "EPD"
  # [raw_bill_information] billing information as given (line 32) or nil
  # [bill_information]     the billing information parsed (BillInformation)
  #                        when it uses the Swico S1 syntax, else nil
  # [alternative_procedures] up to two strings (e.g. "eBill/B/...")
  # [errors, warnings]     Arrays of Problem
  # [raw]                  the payload as given
  Bill = Data.define(
    :version, :coding_type, :account, :qr_iban, :creditor, :ultimate_creditor,
    :amount, :currency, :debtor, :reference_type, :reference, :unstructured_message,
    :trailer, :raw_bill_information, :bill_information, :alternative_procedures,
    :errors, :warnings, :raw
  ) do
    def qr_iban? = qr_iban

    # True when the payload satisfied every rule.
    def valid? = errors.empty?

    # True for a "DO NOT USE FOR PAYMENT" notification (amount 0.00).
    def notification? = !amount.nil? && amount.zero?

    # True when the payer has to fill in the amount.
    def open_amount? = amount.nil?

    def formatted_account = account && Iban.format(account)

    def formatted_reference = reference && Reference.format(reference, reference_type)

    # Amount with two decimals ("1949.75"), or nil.
    def formatted_amount = amount && Bill.amount_string(amount)

    def self.amount_string(value)
      units, decimals = value.round(2).to_s("F").split(".")
      "#{units}.#{decimals.to_s.ljust(2, "0")}"
    end

    # Plain Ruby hash; nested value objects become hashes too.
    def to_h(&)
      hash = super().merge(
        creditor: creditor&.to_h,
        ultimate_creditor: ultimate_creditor&.to_h,
        debtor: debtor&.to_h,
        bill_information: bill_information&.to_h,
        errors: errors.map(&:to_h),
        warnings: warnings.map(&:to_h)
      )
      block_given? ? hash.to_h(&) : hash
    end

    # JSON-ready hash: only strings, numbers, booleans, nil, arrays and
    # hashes (amount as "50.00", symbols and dates as strings).
    def as_json(*)
      to_h.transform_keys(&:to_s).merge(
        "amount" => formatted_amount,
        "creditor" => creditor&.as_json,
        "ultimate_creditor" => ultimate_creditor&.as_json,
        "debtor" => debtor&.as_json,
        "reference_type" => reference_type&.to_s,
        "bill_information" => bill_information&.as_json,
        "errors" => errors.map(&:as_json),
        "warnings" => warnings.map(&:as_json)
      )
    end

    def to_json(*args)
      require "json"
      as_json.to_json(*args)
    end
  end
end
