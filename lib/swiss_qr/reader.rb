# frozen_string_literal: true

require "pathname"
require "stringio"

# QR code readers and SwissQr.read / SwissQr.read_all.
module SwissQr
  # Pluggable QR code readers: turn an image or PDF into the texts of the QR
  # codes on it. SwissQr.read and SwissQr.read_all use SwissQr.reader, which
  # defaults to the +qr_reader+ gem; any other decoder can be plugged in.
  #
  # A reader is either
  # - an object responding to <tt>decode_all(input)</tt> and returning an
  #   Array of Strings (the +QrReader+ module itself qualifies), or
  # - a callable (Proc, Method, any object with #call) returning a String,
  #   an Array of Strings, or nil when nothing was found.
  #
  # Elements may also be result objects with a #text method (such as
  # QrReader::Result); nil elements are dropped.
  #
  # The input handed to a reader is never image bytes in a String: a String
  # is a file path (image bytes come as an IO such as StringIO.new(bytes)).
  module Reader
    # Leading bytes of the image formats a String of image bytes most likely
    # has; together with NUL bytes (never in a path) they reveal image data
    # passed where a path belongs.
    IMAGE_MAGIC = ["\x89PNG".b, "\xFF\xD8\xFF".b, "GIF8".b, "%PDF-".b, "II*\0".b, "MM\0*".b,
                   "\0\0\0\x0CjP".b, "\xFF\x4F\xFF\x51".b].freeze

    INSTALL_HINT = <<~HINT.tr("\n", " ").strip
      Reading QR codes from images and PDFs needs the qr_reader gem: run
      "gem install qr_reader" or "bundle add qr_reader", or plug in another
      decoder with SwissQr.reader = ->(input) { ... } (or pass reader: to
      SwissQr.read).
    HINT

    # The default reader: the +qr_reader+ gem, required on first use (not
    # when swiss_qr is loaded). Raises ReaderUnavailable when it cannot be
    # loaded; the next call tries again.
    #
    # +options+ are passed on to qr_reader (<tt>try_harder:</tt>,
    # <tt>inverted:</tt>):
    #
    #   SwissQr.reader = SwissQr::Reader::QrReaderAdapter.new(try_harder: false)
    class QrReaderAdapter
      # qr_reader 0.0.2 raises this for a PDF with neither raster images nor
      # vector-drawn QR codes (e.g. a text-only invoice page) instead of
      # returning no codes.
      NO_IMAGES = "PDF contains no raster images"

      attr_reader :options

      def initialize(**options)
        @options = options.freeze
      end

      def decode_all(input)
        reader = qr_reader
        nothing_on_pdf { reader.decode_all(path_or_io(input), **options) }
      end

      # Yields the text of each code as soon as it is decoded, so that
      # SwissQr.read can stop at the first QR-bill of a long PDF.
      def each_text(input, &)
        reader = qr_reader
        nothing_on_pdf { reader.scan(path_or_io(input), **options) { |result| yield result.text } }
      end

      def inspect
        shown = options.empty? ? "" : " #{options.inspect}"
        "#<#{self.class.name}#{shown} (qr_reader gem, loaded on first use)>"
      end

      private

      # qr_reader 0.0.2 sniffs Strings (image bytes or path); a Pathname is
      # always read as a path. It also asks IOs for #to_path before reading
      # them, which every IO has since Ruby 3.2 ($stdin's is "<STDIN>"), so
      # IOs other than files are handed over as a StringIO.
      def path_or_io(input)
        return Pathname(input) if input.is_a?(String)
        return StringIO.new(input.read || "") if input.is_a?(IO) && !input.is_a?(File)

        input
      end

      def nothing_on_pdf
        yield
      rescue ::QrReader::UnsupportedImageError => e
        raise unless e.message == NO_IMAGES

        []
      end

      def qr_reader
        require "qr_reader"
        ::QrReader
      rescue LoadError => e
        raise ReaderUnavailable, "#{INSTALL_HINT} (#{e.message})"
      end
    end

    # Wraps any supported reader in an object answering #decode_all and
    # #each_text with plain Strings.
    class Adapter
      attr_reader :reader

      def initialize(reader)
        @reader = reader
      end

      def decode_all(input)
        texts = []
        each_text(input) { |text| texts << text }
        texts
      end

      def each_text(input, &)
        return reader.each_text(input, &) if reader.is_a?(QrReaderAdapter)

        result = reader.respond_to?(:decode_all) ? reader.decode_all(input) : reader.call(input)
        Reader.texts(result).each(&)
      end
    end

    module_function

    # Refuses image bytes passed as a String, where a path belongs: a String
    # input is always a file path. Without this, bytes from a client that
    # spell a path on the server would be read from disk.
    def check_input(input)
      return input unless input.is_a?(String)

      bytes = input.b
      return input if !bytes.include?("\0") && File.file?(input)
      if bytes.include?("\0") || IMAGE_MAGIC.any? { |magic| bytes.start_with?(magic) }
        raise ArgumentError, "expected a file path, got a String that looks like image data " \
                             "(#{bytes.bytesize} bytes); pass image bytes as an IO: StringIO.new(bytes)"
      end

      input
    end

    # True when +reader+ can be used as a reader.
    def reader?(reader)
      reader.respond_to?(:decode_all) || reader.respond_to?(:call)
    end

    # Wraps +reader+ (see Reader) in an Adapter; nil means SwissQr.reader.
    def adapt(reader)
      reader = SwissQr.reader if reader.nil?
      return reader if reader.is_a?(Adapter)
      raise ArgumentError, "a reader must respond to #decode_all or #call (got #{reader.inspect})" unless reader?(reader)

      Adapter.new(reader)
    end

    # Normalises what a reader returned into an Array of Strings. A single
    # String or result object (with #text) counts as one code; it is not
    # splatted with Array() (a Struct result would turn into its fields).
    def texts(result)
      items = result.respond_to?(:to_str) || result.respond_to?(:text) ? [result] : Array(result)
      items.filter_map { |item| text(item) }
    end

    def text(item)
      return if item.nil?
      return item.to_str if item.respond_to?(:to_str)
      return item.text&.to_s if item.respond_to?(:text)

      raise TypeError, "a reader must return Strings (or objects with #text), got #{item.class}"
    end
  end

  @reader = nil
  @reader_lock = Mutex.new

  class << self
    # The reader used by read and read_all: what was assigned with reader=,
    # or else a Reader::QrReaderAdapter for the +qr_reader+ gem (which is
    # only required when a code is actually read).
    def reader
      @reader || @reader_lock.synchronize { @reader ||= Reader::QrReaderAdapter.new }
    end

    # Replaces the reader for the whole process: an object with
    # <tt>decode_all(input)</tt> or a callable (see Reader). +nil+ restores
    # the default (+qr_reader+).
    #
    #   SwissQr.reader = ->(path) { `zbarimg --quiet --raw #{path}`.split("\n") }
    def reader=(reader)
      unless reader.nil? || Reader.reader?(reader)
        raise ArgumentError, "a reader must respond to #decode_all or #call (got #{reader.inspect})"
      end

      @reader_lock.synchronize { @reader = reader }
    end

    # Reads the QR codes in +input+ - a file path (String or Pathname), an
    # IO with the image or PDF (StringIO.new(bytes), an upload's Tempfile),
    # or whatever else the reader accepts, such as a ChunkyPNG image - and
    # returns the first QR-bill as a Bill, or nil when there is none. A
    # String is always a path: image bytes in a String raise ArgumentError.
    # Codes that are not QR-bills (see qr_bill?) are skipped. +strict+ is
    # passed on to parse.
    def read(input, reader: self.reader, strict: true)
      Reader.adapt(reader).each_text(Reader.check_input(input)) do |text|
        return parse(text, strict: strict) if qr_bill?(text)
      end
      nil
    end

    # Like read, but returns every QR-bill found (all pages), in the order
    # the reader reported them; an empty Array when there is none.
    def read_all(input, reader: self.reader, strict: true)
      texts = Reader.adapt(reader).decode_all(Reader.check_input(input))
      texts.select { |text| qr_bill?(text) }.map { |text| parse(text, strict: strict) }
    end
  end
end
