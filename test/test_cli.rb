# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require "stringio"
require "swiss_qr/cli"

# exe/swiss_qr, run as a subprocess (and SwissQr::CLI in-process where a
# custom reader is needed).
class TestCLI < Minitest::Test
  EXE = File.expand_path("../exe/swiss_qr", __dir__)
  IMAGES = File.expand_path("fixtures/images", __dir__)

  def image(name) = File.join(IMAGES, name)

  def swiss_qr(*, stdin: "")
    out, err, status = Open3.capture3(RbConfig.ruby, EXE, *, stdin_data: stdin, binmode: true)
    [out.force_encoding(Encoding::UTF_8), err, status.exitstatus]
  end

  def teardown
    SwissQr.reader = nil
  end

  def test_files_to_json
    out, err, status = swiss_qr(image("six_ig_ex1_qrr.png"), image("invoice_two_pages.pdf"))

    assert_equal 0, status, err
    assert_empty err
    bills = JSON.parse(out)
    assert_equal([image("six_ig_ex1_qrr.png"), image("invoice_two_pages.pdf"), image("invoice_two_pages.pdf")],
                 bills.map { |bill| bill["file"] })
    assert_fixture_match expected_json("valid", "six_ig_ex1_qrr"), bills.first
    assert_equal payload("valid", "six_ig_ex1_qrr"), bills.first["raw"]
    assert_equal %w[CH4431999123000889012 CH9300762011623852957], bills.drop(1).map { |bill| bill["account"] }.sort
  end

  def test_unrelated_codes_are_skipped
    out, err, status = swiss_qr(image("bill_and_url.png"))

    assert_equal 0, status, err
    assert_equal(["CH66083900350A1234567"], JSON.parse(out).map { |bill| bill["account"] })
  end

  def test_no_bill_found
    out, err, status = swiss_qr(image("url_only.png"), image("iban_scor_eur.png"))

    assert_equal 1, status
    assert_includes err, "url_only.png: no QR-bill found"
    assert_equal(["iban_scor_eur.png"], JSON.parse(out).map { |bill| File.basename(bill["file"]) })
  end

  def test_unreadable_file
    out, err, status = swiss_qr(image("missing.png"))

    assert_equal 2, status
    assert_includes err, "missing.png"
    assert_equal [], JSON.parse(out)
  end

  def test_image_from_stdin
    out, err, status = swiss_qr("-", stdin: File.binread(image("unicode_charset.png")))

    assert_equal 0, status, err
    bill = JSON.parse(out).first
    assert_equal "-", bill["file"]
    assert_equal payload("valid", "unicode_charset"), bill["raw"]
  end

  def test_text_from_stdin
    out, err, status = swiss_qr("--text", stdin: payload("valid", "six_ig_ex2_qrr_swico_two_alt_procedures"))

    assert_equal 0, status, err
    bills = JSON.parse(out)
    assert_equal 1, bills.size
    assert_fixture_match expected_json("valid", "six_ig_ex2_qrr_swico_two_alt_procedures"), bills.first
  end

  def test_invalid_text_strict
    out, err, status = swiss_qr("--text", stdin: payload("invalid", "amount_comma"))

    assert_equal 1, status
    assert_includes err, "invalid QR-bill: amount:"
    assert_equal [], JSON.parse(out)
  end

  def test_invalid_text_lenient
    out, err, status = swiss_qr("--no-strict", "--text", stdin: payload("invalid", "amount_comma"))

    assert_equal 1, status
    assert_includes err, "amount:"
    bill = JSON.parse(out).first
    assert_equal(["amount"], bill["errors"].map { |error| error["field"] })
    assert_equal "CHF", bill["currency"]
  end

  def test_not_a_qr_bill_on_stdin
    out, err, status = swiss_qr("--text", "--no-strict", stdin: "https://example.com\n")

    assert_equal 1, status
    assert_includes err, "invalid QR-bill payload"
    assert_equal [], JSON.parse(out)
  end

  def test_json_lines
    out, err, status = swiss_qr("--lines", image("invoice_two_pages.pdf"))

    assert_equal 0, status, err
    lines = out.lines
    assert_equal 2, lines.size
    lines.each { |line| assert_equal "EPD", JSON.parse(line)["trailer"] }
  end

  def test_version_and_help
    out, _err, status = swiss_qr("--version")
    assert_equal 0, status
    assert_equal "swiss_qr #{SwissQr::VERSION}\n", out

    out, _err, status = swiss_qr("--help")
    assert_equal 0, status
    assert_includes out, "Usage: swiss_qr"
    assert_includes out, "--no-strict"
  end

  def test_usage_errors
    [[], ["--bogus"], ["--text", image("url_only.png")]].each do |args|
      out, err, status = swiss_qr(*args)
      assert_equal 2, status, args.inspect
      assert_empty out
      assert_includes err, "Usage: swiss_qr"
    end
  end

  # In-process: SwissQr::CLI uses SwissQr.reader, so it can be replaced.

  def run_cli(*args, stdin: "")
    stdout = StringIO.new
    stderr = StringIO.new
    status = SwissQr::CLI.new(stdin: StringIO.new(stdin), stdout: stdout, stderr: stderr).run(args)
    [stdout.string, stderr.string, status]
  end

  def test_custom_reader
    SwissQr.reader = ->(input) { input == "scan.tiff" ? ["other", payload("valid", "iban_scor_eur")] : nil }

    out, err, status = run_cli("scan.tiff")
    assert_equal 0, status, err
    assert_equal(["scan.tiff"], JSON.parse(out).map { |bill| bill["file"] })

    _, err, status = run_cli("blank.tiff")
    assert_equal 1, status
    assert_includes err, "blank.tiff: no QR-bill found"
  end

  def test_reader_unavailable
    SwissQr.reader = ->(_) { raise SwissQr::ReaderUnavailable, "install qr_reader" }

    out, err, status = run_cli("scan.png")
    assert_equal 2, status
    assert_empty out
    assert_includes err, "install qr_reader"
  end

  def test_structurally_broken_bill_in_an_image
    SwissQr.reader = ->(_) { ["SPC\n0200\n1\nEPD", payload("valid", "six_ig_ex1_qrr")] }

    out, err, status = run_cli("scan.png")
    assert_equal 1, status
    assert_includes err, "scan.png: invalid QR-bill payload"
    assert_equal 1, JSON.parse(out).size
  end
end
