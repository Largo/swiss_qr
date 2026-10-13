# frozen_string_literal: true

module SwissQr
  # A creditor, ultimate creditor or debtor address.
  #
  # +type+ is +:structured+ (address type "S", the only type allowed since IG
  # 2.3) or +:combined+ (legacy type "K"; +address_line1+/+address_line2+
  # instead of street, building number, postal code and town). It is +nil+
  # when the payload carries an unknown address type.
  Address = Data.define(
    :type, :name, :street, :building_number, :postal_code, :town,
    :address_line1, :address_line2, :country
  ) do
    def self.type_for(code)
      { "S" => :structured, "K" => :combined }[code]
    end

    # Builds an address from the seven payload lines of an address block
    # (type code, name, line 1, line 2, postal code, town, country). Lines
    # must already be stripped, with empty lines as +nil+.
    def self.from_lines(lines)
      code, name, line1, line2, postal_code, town, country = lines
      type = type_for(code)
      combined = type == :combined
      new(type: type, name: name,
          street: combined ? nil : line1, building_number: combined ? nil : line2,
          postal_code: postal_code, town: town,
          address_line1: combined ? line1 : nil, address_line2: combined ? line2 : nil,
          country: country)
    end

    def structured? = type == :structured

    def combined? = type == :combined

    # Postal lines for display, e.g.
    # ["Max Muster & Söhne", "Musterstrasse 123", "8000 Seldwyla"].
    # The country is added for addresses outside Switzerland.
    def lines
      result = [name]
      if combined?
        result << address_line1 << address_line2
      else
        result << [street, building_number].compact.join(" ")
        result << [postal_code, town].compact.join(" ")
      end
      result << country if country && country != "CH"
      result.reject { |line| line.nil? || line.empty? }
    end

    def to_s = lines.join("\n")

    def as_json(*)
      to_h.transform_keys(&:to_s).merge("type" => type&.to_s)
    end
  end
end
