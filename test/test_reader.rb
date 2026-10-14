# frozen_string_literal: true

require "test_helper"
require "open3"
require "pathname"
require "rbconfig"
require "stringio"
require "tmpdir"

# SwissQr.read / read_all / reader: the default qr_reader integration on the
# image fixtures, and custom readers.
class TestReader < Minitest::Test
  IMAGES = File.expand_path("fixtures/images", __dir__)
  EXPECTED = JSON.parse(File.read(File.join(IMAGES, "expected.json")))
  LIB = File.expand_path("../lib", __dir__)

  def teardown
    SwissQr.reader = nil
  end

  def image(name) = File.join(IMAGES, name)

  def bill_names(file) = EXPECTED.fetch(file).grep(String)

  def other_codes(file) = EXPECTED.fetch(file).grep(Hash).map { |code| code.fetch("not_a_bill") }

  # --- the default reader (qr_reader) on the image fixtures -------------------

  EXPECTED.each_key do |file|
    define_method(:"test_read_all_#{file.tr(".", "_")}") do
      bills = SwissQr.read_all(image(file))

      expected = bill_names(file).to_h { |name| [payload("valid", name), name] }
      assert_equal expected.keys.sort, bills.map(&:raw).sort, "QR-bills in #{file} (compared as sets)"
      bills.each do |bill|
        assert_predicate bill, :valid?
        assert_fixture_match expected_json("valid", expected.fetch(bill.raw)), bill.as_json
      end
    end
  end

  def test_unrelated_codes_are_decoded_but_skipped
    %w[bill_and_url.png invoice_two_pages.pdf url_only.png].each do |file|
      texts = QrReaderHelper.decode_all(image(file))
      other_codes(file).each { |text| assert_includes texts, text, file }
      assert_equal bill_names(file).size, SwissQr.read_all(image(file)).size, file
    end
  end

  def test_read_returns_the_first_bill
    assert_equal payload("valid", "six_ig_ex1_qrr"), SwissQr.read(image("six_ig_ex1_qrr.png")).raw
    assert_equal "iban_non_message_lf", fixture_for(SwissQr.read(image("bill_and_url.png")))
    assert_includes bill_names("invoice_two_pages.pdf"), fixture_for(SwissQr.read(image("invoice_two_pages.pdf")))
  end

  def test_read_without_a_bill
    assert_nil SwissQr.read(image("url_only.png"))
    assert_equal [], SwissQr.read_all(image("url_only.png"))
  end

  def test_legacy_combined_address_from_image_has_a_warning
    bill = SwissQr.read(image("combined_address_k_legacy.png"))
    assert_predicate bill.creditor, :combined?
    refute_empty bill.warnings
  end

  def test_inputs_other_than_paths
    path = image("iban_scor_eur.png")
    expected = payload("valid", "iban_scor_eur")

    assert_equal expected, SwissQr.read(Pathname(path)).raw
    assert_equal expected, File.open(path, "rb") { |io| SwissQr.read(io) }.raw
    assert_equal expected, SwissQr.read(StringIO.new(File.binread(path))).raw
    assert_equal expected, SwissQr.read_all(StringIO.new(File.binread(path))).first.raw
  end

  # A String is always a path. Image bytes in a String fail before any reader
  # sees them, so bytes from a client can never be taken for a server path.
  def test_image_bytes_in_a_string_are_refused
    called = false
    spy = ->(_) { called = true }
    %w[iban_scor_eur.png invoice_two_pages.pdf].each do |name|
      bytes = File.binread(image(name))
      [-> { SwissQr.read(bytes) }, -> { SwissQr.read_all(bytes) }, -> { SwissQr.read(bytes, reader: spy) }].each do |call|
        error = assert_raises(ArgumentError, name) { call.call }
        assert_match(/looks like image data.*StringIO/, error.message)
      end
    end
    refute called
    assert_raises(ArgumentError) { SwissQr.read("a\0b") }
    # A String that is not image data goes to the reader as a path.
    assert_raises(Errno::ENOENT) { SwissQr.read("/no/such/bill.png") }
  end

  def test_reader_errors_propagate
    assert_raises(Errno::ENOENT) { SwissQr.read(image("missing.png")) }
    truncated = File.binread(image("url_only.png")).byteslice(0, 100)
    assert_raises(QrReaderHelper.qr_reader::ImageError) { SwissQr.read(StringIO.new(truncated)) }
  end

  # qr_reader 0.0.2 raises UnsupportedImageError for such a PDF; the default
  # adapter turns that into "no codes".
  def test_pdf_without_any_image_or_code
    pdf = TestReader.text_only_pdf
    assert_nil SwissQr.read(StringIO.new(pdf))
    assert_equal [], SwissQr.read_all(StringIO.new(pdf))
    assert_equal [], SwissQr.reader.decode_all(StringIO.new(pdf))
  end

  # A one-page PDF with a line of text and a black square, nothing else.
  def self.text_only_pdf
    content = "BT /F1 12 Tf 72 720 Td (Invoice 4711) Tj ET\n0 0 0 rg 100 100 50 50 re f\n"
    objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
      "<< /Length #{content.bytesize} >>\nstream\n#{content}endstream",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    ]
    pdf = +"%PDF-1.4\n"
    offsets = objects.each_with_index.map do |object, index|
      pdf.bytesize.tap { pdf << "#{index + 1} 0 obj\n#{object}\nendobj\n" }
    end
    xref = pdf.bytesize
    pdf << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n"
    offsets.each { |offset| pdf << format("%010d 00000 n \n", offset) }
    pdf << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
  end

  def test_default_reader
    reader = SwissQr.reader
    assert_instance_of SwissQr::Reader::QrReaderAdapter, reader
    assert_same reader, SwissQr.reader
    assert_includes reader.inspect, "qr_reader"
    assert_equal QrReaderHelper.decode_all(image("bill_and_url.png")), reader.decode_all(image("bill_and_url.png"))
  end

  def test_qr_reader_module_itself_is_a_reader
    SwissQr.reader = QrReaderHelper.qr_reader
    assert_equal 2, SwissQr.read_all(image("invoice_two_pages.pdf")).size
  end

  # --- custom readers ---------------------------------------------------------

  # A reader object in the style of a zxing/zbar wrapper.
  class FakeReader
    attr_reader :inputs

    def initialize(*texts)
      @texts = texts
      @inputs = []
    end

    def decode_all(input)
      @inputs << input
      @texts
    end
  end

  Result = Data.define(:text)

  def test_object_with_decode_all
    text = payload("valid", "six_ig_ex1_qrr")
    fake = FakeReader.new("https://example.com", text, payload("valid", "iban_scor_eur"))
    SwissQr.reader = fake

    assert_same fake, SwissQr.reader
    assert_equal text, SwissQr.read("scan.tiff").raw
    assert_equal 2, SwissQr.read_all("scan.tiff").size
    assert_equal ["scan.tiff", "scan.tiff"], fake.inputs
  end

  def test_lambda_returning_a_string_an_array_or_nil
    text = payload("valid", "iban_scor_eur")

    assert_equal text, SwissQr.read(:input, reader: ->(_) { text }).raw
    assert_equal [text, text], SwissQr.read_all(:input, reader: ->(_) { [text, nil, "other", text] }).map(&:raw)
    assert_nil SwissQr.read(:input, reader: ->(_) {})
    assert_equal [], SwissQr.read_all(:input, reader: ->(_) {})
    assert_equal [], SwissQr.read_all(:input, reader: ->(_) { [] })
  end

  def test_callable_receives_the_input
    seen = nil
    SwissQr.read("page.png", reader: lambda { |input|
      seen = input
      nil
    })
    assert_equal "page.png", seen
  end

  def test_method_objects_and_result_objects
    text = payload("valid", "six_ig_ex1_qrr")
    results = [Result.new("not a bill"), Result.new(text)]
    reader = Object.new
    reader.define_singleton_method(:scan_page) { |_input| results }

    assert_equal text, SwissQr.read(:input, reader: reader.method(:scan_page)).raw
  end

  StructResult = Struct.new(:text, :score)

  # A single result object is one code, even when it splats (Struct#to_a).
  def test_single_result_object_from_a_callable
    text = payload("valid", "six_ig_ex1_qrr")
    [StructResult.new(text, 1), Result.new(text)].each do |result|
      assert_equal text, SwissQr.read(:input, reader: ->(_) { result }).raw, result.class.name
      assert_equal [text], SwissQr.read_all(:input, reader: ->(_) { result }).map(&:raw), result.class.name
    end
    assert_equal [text], SwissQr.read_all(:input, reader: ->(_) { [StructResult.new(text, 1)] }).map(&:raw)
  end

  def test_default_adapter_passes_options_to_qr_reader
    reader = SwissQr::Reader::QrReaderAdapter.new(try_harder: false, inverted: false)
    assert_equal({ try_harder: false, inverted: false }, reader.options)
    assert_includes reader.inspect, "try_harder"

    SwissQr.reader = reader
    assert_equal QrReaderHelper.qr_reader.decode_all(image("bill_and_url.png"), try_harder: false, inverted: false),
                 reader.decode_all(image("bill_and_url.png"))
    assert_equal 2, SwissQr.read_all(image("invoice_two_pages.pdf")).size
    assert_nil SwissQr.read(StringIO.new(TestReader.text_only_pdf)), "keeps the no-images tolerance"
    assert_raises(ArgumentError) { SwissQr.read(image("bill_and_url.png"), reader: SwissQr::Reader::QrReaderAdapter.new(bogus: 1)) }
  end

  def test_non_utf8_strings_from_a_reader
    text = payload("valid", "unicode_charset")
    assert_equal text, SwissQr.read(:input, reader: ->(_) { text.b }).raw
  end

  def test_reader_returning_garbage
    assert_raises(TypeError) { SwissQr.read(:input, reader: ->(_) { [42] }) }
  end

  def test_per_call_reader_does_not_change_the_global_one
    default = SwissQr.reader
    SwissQr.read(:input, reader: ->(_) {})
    assert_same default, SwissQr.reader
  end

  def test_reader_nil_means_the_global_reader
    text = payload("valid", "iban_scor_eur")
    SwissQr.reader = ->(_) { text }
    assert_equal text, SwissQr.read(:input, reader: nil).raw
  end

  def test_reader_assignment_is_checked
    assert_raises(ArgumentError) { SwissQr.reader = "zbarimg" }
    assert_raises(ArgumentError) { SwissQr.read(:input, reader: Object.new) }
    assert_instance_of SwissQr::Reader::QrReaderAdapter, SwissQr.reader
  end

  def test_reader_reset_to_default
    SwissQr.reader = ->(_) {}
    SwissQr.reader = nil
    assert_instance_of SwissQr::Reader::QrReaderAdapter, SwissQr.reader
  end

  def test_concurrent_access_to_the_default_reader
    SwissQr.instance_variable_set(:@reader, nil)
    readers = Array.new(8) { Thread.new { SwissQr.reader } }.map(&:value)
    assert_equal 1, readers.uniq(&:object_id).size
  end

  def test_strict_is_passed_on
    bad = build_payload(19 => "50,00")
    reader = ->(_) { ["https://example.com", bad] }

    error = assert_raises(SwissQr::InvalidPayload) { SwissQr.read(:input, reader: reader) }
    assert_problem error.errors, :amount
    assert_raises(SwissQr::InvalidPayload) { SwissQr.read_all(:input, reader: reader) }

    bill = SwissQr.read(:input, reader: reader, strict: false)
    refute_predicate bill, :valid?
    assert_equal 1, SwissQr.read_all(:input, reader: reader, strict: false).size
  end

  def test_structurally_broken_bill_raises_even_when_lenient
    reader = ->(_) { "SPC\n0200\n1\nCH4431999123000889012\nEPD" }
    assert_raises(SwissQr::InvalidPayload) { SwissQr.read(:input, reader: reader, strict: false) }
  end

  # The default reader yields codes page by page (QrReader.scan), so read
  # returns the bill on page 1 without decoding page 2.
  def test_read_stops_at_the_first_bill_with_the_default_reader
    texts = []
    SwissQr::Reader.adapt(nil).each_text(image("invoice_two_pages.pdf")) do |text|
      texts << text
      break if SwissQr.looks_like_qr_bill?(text)
    end
    assert_equal [payload("valid", "six_ig_ex2_qrr_swico_two_alt_procedures")], texts
    assert_equal texts.first, SwissQr.read(image("invoice_two_pages.pdf")).raw
  end

  # --- qr_reader is optional --------------------------------------------------

  def test_require_does_not_load_qr_reader_and_read_does
    script = <<~RUBY
      require "swiss_qr"
      loaded = -> { $LOADED_FEATURES.any? { |f| f.end_with?("/qr_reader.rb") } }
      abort "loaded by require" if loaded.call
      SwissQr.parse(File.binread(ARGV[0]).force_encoding("UTF-8"))
      SwissQr.reader
      abort "loaded by parse/reader" if loaded.call
      SwissQr.read(ARGV[1])
      abort "not loaded by read" unless loaded.call
      puts "ok"
    RUBY
    out, err, status = run_ruby(script, File.join(FIXTURES, "valid", "six_ig_ex1_qrr.txt"), image("six_ig_ex1_qrr.png"))
    assert status.success?, err
    assert_equal "ok\n", out
  end

  def test_reader_unavailable_without_qr_reader
    Dir.mktmpdir do |shadow|
      # Shadows the installed gem: `require "qr_reader"` fails as if it were missing.
      File.write(File.join(shadow, "qr_reader.rb"), 'raise LoadError, "cannot load such file -- qr_reader"')
      script = <<~RUBY
        $LOAD_PATH.unshift(ARGV.shift)
        require "swiss_qr"
        payload = File.binread(ARGV[0]).force_encoding("UTF-8")
        SwissQr.parse(payload)                   # the parser works without qr_reader
        SwissQr.reader                           # and so does asking for the reader
        begin
          SwissQr.read(ARGV[1])
          abort "no ReaderUnavailable"
        rescue SwissQr::ReaderUnavailable => e
          puts e.message
          puts e.cause.class
        end
        SwissQr.reader = ->(_input) { payload }  # a replacement reader works
        puts SwissQr.read(ARGV[1]).account
      RUBY
      out, err, status = run_ruby(script, shadow, File.join(FIXTURES, "valid", "six_ig_ex1_qrr.txt"), image("six_ig_ex1_qrr.png"))

      assert status.success?, err
      message, cause, account = out.lines(chomp: true)
      assert_includes message, "gem install qr_reader"
      assert_includes message, "bundle add qr_reader"
      assert_includes message, "SwissQr.reader ="
      assert_equal "LoadError", cause
      assert_equal "CH6431961000004421557", account
    end
  end

  private

  def fixture_for(bill)
    FixtureHelper.fixture_names("valid").find { |name| payload("valid", name) == bill.raw }
  end

  def run_ruby(script, *)
    Open3.capture3(RbConfig.ruby, "-I", LIB, "-e", script, "--", *)
  end
end

# Direct access to the qr_reader gem (a development dependency).
module QrReaderHelper
  module_function

  def qr_reader
    require "qr_reader"
    ::QrReader
  end

  def decode_all(input) = qr_reader.decode_all(input)
end
