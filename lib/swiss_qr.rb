# frozen_string_literal: true

require_relative "swiss_qr/version"
require_relative "swiss_qr/errors"
require_relative "swiss_qr/checksum"
require_relative "swiss_qr/iban"
require_relative "swiss_qr/countries"
require_relative "swiss_qr/reference"
require_relative "swiss_qr/address"
require_relative "swiss_qr/billing_information"
require_relative "swiss_qr/bill"
require_relative "swiss_qr/validation"
require_relative "swiss_qr/parser"
# SwissQr.read, .read_all and .reader; does not load the qr_reader gem.
require_relative "swiss_qr/reader"

# Parser for the payload of Swiss QR-bills ("QR-Rechnung", SIX Swiss
# Implementation Guidelines for the QR-bill: header "SPC", version "0200",
# coding type "1", trailer "EPD").
#
#   bill = SwissQr.parse(payload)
#   bill.iban          # => "CH4431999123000889012"
#   bill.amount           # => 0.194975e4 (BigDecimal)
#   bill.creditor.name    # => "Max Muster & Söhne"
#   bill.billing_information&.invoice_number
#
#   SwissQr.read("invoice.pdf")      # first QR-bill in an image or PDF (needs a reader,
#                                    # by default the qr_reader gem)
module SwissQr
  module_function

  # Parses a QR-bill payload into a Bill.
  #
  # With <tt>strict: true</tt> (the default) any rule violation raises
  # InvalidPayload, whose #errors lists every Problem. With
  # <tt>strict: false</tt> the Bill is returned with its #errors filled in;
  # InvalidPayload is still raised when the text is not structurally a
  # QR-bill (QR type other than "SPC", fewer than 31 lines).
  def parse(payload, strict: true)
    Parser.parse(payload, strict: strict)
  end

  # True when +payload+ is a QR-bill without any rule violation (warnings
  # are allowed).
  def valid?(payload)
    parse(payload, strict: false).valid?
  rescue InvalidPayload, TypeError
    false
  end

  # Cheap check whether +text+ looks like a QR-bill payload at all, e.g. to
  # skip other QR codes on the same page. Does not validate.
  def looks_like_qr_bill?(text)
    Parser.looks_like_qr_bill?(text)
  end
end
