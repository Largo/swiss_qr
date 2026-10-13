# frozen_string_literal: true

module SwissQr
  # Country codes for the address checks. Addresses carry a "two-digit
  # country code according to ISO 3166-1" (IG 4.2.2, Ctry).
  module Countries
    # ISO 3166-1 alpha-2 (249 officially assigned codes, as in Debian's
    # iso-codes 3166-1 list), plus XK (Kosovo): user-assigned, but used by
    # SWIFT, the IBAN registry and the EU for Kosovo.
    ISO_3166_1 = <<~CODES.split.to_h { |code| [code.freeze, true] }.freeze
      AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE
      BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD
      CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM
      DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF
      GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU
      ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN
      KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME
      MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA
      NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM
      PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI
      SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK
      TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI
      VN VU WF WS YE YT ZA ZM ZW
      XK
    CODES

    # International vehicle codes that are not ISO alpha-2 codes but appear
    # as postal-code prefixes ("D-78462", "FL-9490", "A-6900").
    VEHICLE_CODES = {
      "A" => "AT", "B" => "BE", "D" => "DE", "E" => "ES", "F" => "FR", "H" => "HU", "I" => "IT",
      "L" => "LU", "M" => "MT", "N" => "NO", "P" => "PT", "S" => "SE", "V" => "VA",
      "FL" => "LI", "UK" => "GB", "AND" => "AD", "BIH" => "BA", "CDN" => "CA", "EST" => "EE",
      "FIN" => "FI", "IRL" => "IE", "MNE" => "ME", "NMK" => "MK", "RKS" => "XK", "RSM" => "SM",
      "RUS" => "RU", "SLO" => "SI", "SRB" => "RS", "USA" => "US"
    }.freeze

    # Countries whose official postal code format starts with the country
    # code ("LV-1050", "LT-01100", "MD-2001").
    PREFIXED_POSTAL_CODES = %w[LT LV MD].freeze

    module_function

    # True for an (upper-case) ISO 3166-1 alpha-2 code.
    def iso?(code)
      ISO_3166_1.key?(code)
    end
  end
end
