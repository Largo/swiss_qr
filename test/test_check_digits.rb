# frozen_string_literal: true

require "test_helper"

class TestCheckDigits < Minitest::Test
  Iban = SwissQr::Iban
  Reference = SwissQr::Reference

  def test_mod10_recursive_spec_example
    # IG QR-bill Annex B
    assert_equal 7, SwissQr::Checksum.mod10_recursive("21000000000313947143000901")
    assert_equal 0, SwissQr::Checksum.mod10_recursive("0" * 26)
  end

  def test_mod97
    assert_equal 1, SwissQr::Checksum.mod97("CH4431999123000889012")
    assert_equal 1, SwissQr::Checksum.mod97("RF18539007547034")
    refute_equal 1, SwissQr::Checksum.mod97("RF720191230100405JSH0438")
  end

  def test_iban_valid
    assert Iban.valid?("CH4431999123000889012")
    assert Iban.valid?("CH44 3199 9123 0008 8901 2")
    assert Iban.valid?("ch4431999123000889012")
    assert Iban.valid?("LI21 0881 0000 2324 013A A")
    assert Iban.valid?("DE89 3704 0044 0532 0130 00")
    refute Iban.valid?("CH4431999123000889013")
    refute Iban.valid?("CH44")
    refute Iban.valid?("")
    refute Iban.valid?(nil)
  end

  def test_qr_bill_account_only_ch_and_li
    assert Iban.qr_bill_account?("CH9300762011623852957")
    assert Iban.qr_bill_account?("LI2108810000232401 3AA")
    refute Iban.qr_bill_account?("DE89370400440532013000")
  end

  def test_qr_iban
    assert Iban.qr_iban?("CH4431999123000889012")
    assert Iban.qr_iban?("CH64 3196 1000 0044 2155 7")
    refute Iban.qr_iban?("CH9300762011623852957")
    refute Iban.qr_iban?("CH4431999123000889013"), "wrong check digits"
    assert Iban.qr_iid?("CH4431999123000889013"), "qr_iid? ignores check digits"
    assert_equal "31999", Iban.iid("CH4431999123000889012")
    assert_nil Iban.iid("DE89370400440532013000")
  end

  def test_qr_iid_range_bounds
    refute Iban.qr_iid?("CH0029999000000000000")
    assert Iban.qr_iid?("CH0030000000000000000")
    assert Iban.qr_iid?("CH0031999000000000000")
    refute Iban.qr_iid?("CH0032000000000000000")
  end

  def test_iban_format_and_normalize
    assert_equal "CH44 3199 9123 0008 8901 2", Iban.format("CH4431999123000889012")
    assert_equal "CH44 3199 9123 0008 8901 2", Iban.format("ch44 3199 9123 0008 8901 2")
    assert_equal "CH4431999123000889012", Iban.normalize(" ch44 3199\t9123 0008 8901 2 ")
  end

  def test_valid_qrr
    assert Reference.valid_qrr?("210000000003139471430009017")
    assert Reference.valid_qrr?("21 00000 00003 13947 14300 09017")
    assert Reference.valid_qrr?("000008207791225857421286694")
    refute Reference.valid_qrr?("210000000003139471430009016")
    refute Reference.valid_qrr?("21000000000313947143000901")
    refute Reference.valid_qrr?("0" * 27), "all zeros are forbidden since IG 2.3"
    refute Reference.valid_qrr?("RF18539007547034")
    refute Reference.valid_qrr?(nil)
  end

  def test_valid_scor
    assert Reference.valid_scor?("RF18539007547034")
    assert Reference.valid_scor?("RF18 5390 0754 7034")
    assert Reference.valid_scor?("rf18539007547034"), "case-insensitive"
    assert Reference.valid_scor?("RF240191230100405JSH0438")
    refute Reference.valid_scor?("RF720191230100405JSH0438"), "SIX IG example 4 table typo"
    refute Reference.valid_scor?("RF18539007547035")
    refute Reference.valid_scor?("RF18"), "too short"
    refute Reference.valid_scor?("XX18539007547034")
    refute Reference.valid_scor?("RF#{"1" * 24}")
  end

  def test_build_references
    assert_equal "210000000003139471430009017", Reference.qrr("21000000000313947143000901")
    assert_equal "#{"0" * 22}1234", Reference.qrr("1234")[0, 26]
    assert Reference.valid_qrr?(Reference.qrr("1234"))
    assert_equal "RF18539007547034", Reference.scor("539007547034")
    assert_equal "RF240191230100405JSH0438", Reference.scor("0191230100405jsh0438")
    assert Reference.valid_scor?(Reference.scor("A"))
    assert_raises(ArgumentError) { Reference.qrr("1" * 27) }
    assert_raises(ArgumentError) { Reference.scor("not-alnum") }
  end

  def test_format_references
    assert_equal "21 00000 00003 13947 14300 09017", Reference.format_qrr("210000000003139471430009017")
    assert_equal "RF18 5390 0754 7034", Reference.format_scor("RF18539007547034")
    assert_equal "RF24 0191 2301 0040 5JSH 0438", Reference.format_scor("rf240191230100405jsh0438")
    assert_equal "21 00000 00003 13947 14300 09017", Reference.format("210000000003139471430009017")
    assert_equal "RF18 5390 0754 7034", Reference.format("RF18539007547034")
    assert_equal "RF18 5390 0754 7034", Reference.format("RF18539007547034", :scor)
    assert_nil Reference.format(nil)
  end
end
