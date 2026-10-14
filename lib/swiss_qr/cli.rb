# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../swiss_qr"

module SwissQr
  # The +swiss_qr+ command: reads QR-bills from images/PDFs (or a payload
  # from standard input) and prints them as JSON. Not loaded by
  # <tt>require "swiss_qr"</tt>.
  #
  # Exit status: 0 when every input held at least one QR-bill and all of
  # them were valid, 1 when an input held no QR-bill or an invalid one, 2 on
  # usage errors, unreadable files or a missing QR code reader.
  class CLI
    OK = 0
    INVALID = 1
    FAILURE = 2

    def initialize(stdin: $stdin, stdout: $stdout, stderr: $stderr)
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
      @strict = true
      @text = false
      @lines = false
      @status = OK
    end

    # Runs the command with the given arguments; returns the exit status.
    def run(argv)
      catch(:exit) do
        files = parser.parse(argv)
        next usage_error("--text reads the payload from standard input; give no files") if @text && files.any?
        next usage_error("no input given") if !@text && files.empty?

        print_json(@text ? read_text : files.flat_map { |file| read_file(file) })
        @status
      end
    rescue OptionParser::ParseError => e
      usage_error(e.message)
    rescue ReaderUnavailable => e
      @stderr.puts "swiss_qr: #{e.message}"
      FAILURE
    end

    private

    def parser
      OptionParser.new do |opts|
        opts.banner = <<~BANNER
          Usage: swiss_qr [options] FILE...
                 swiss_qr --text [options] < payload.txt

          Prints the Swiss QR-bills found in images or PDFs (FILE "-" reads the
          image from standard input) as a JSON array, one object per bill.
        BANNER
        opts.separator ""
        opts.on("-t", "--text", "Parse a QR-bill payload (text) from standard input") { @text = true }
        opts.on("--[no-]strict", "With --no-strict invalid bills are printed with their errors (exit status stays 1)") do |value|
          @strict = value
        end
        opts.on("-l", "--lines", "Print one compact JSON object per line instead of an array") { @lines = true }
        opts.on("-v", "--version", "Print the version") do
          @stdout.puts "swiss_qr #{VERSION}"
          throw :exit, OK
        end
        opts.on("-h", "--help", "Print this help") do
          @stdout.puts opts
          throw :exit, OK
        end
      end
    end

    def read_text
      [parse("-", @stdin.binmode.read.force_encoding(Encoding::UTF_8))].compact
    end

    def read_file(file)
      input = file == "-" ? @stdin.binmode : file
      texts = Reader.adapt(SwissQr.reader).decode_all(input).select { |text| SwissQr.looks_like_qr_bill?(text) }
      problem(INVALID, file, "no QR-bill found") if texts.empty?
      texts.filter_map { |text| parse(file, text) }
    rescue ReaderUnavailable
      raise
    rescue StandardError => e
      problem(FAILURE, file, "#{e.message} (#{e.class})")
      []
    end

    # The bill as a JSON-ready hash, or nil when it is not printed.
    def parse(file, text)
      bill = SwissQr.parse(text, strict: false)
      unless bill.valid?
        problem(INVALID, file, "invalid QR-bill: #{bill.errors.join("; ")}")
        return if @strict
      end
      { "file" => file }.merge(bill.as_json)
    rescue InvalidPayload => e
      problem(INVALID, file, e.message)
      nil
    end

    def print_json(bills)
      if @lines
        bills.each { |bill| @stdout.puts JSON.generate(bill) }
      else
        @stdout.puts JSON.pretty_generate(bills)
      end
    end

    def problem(status, file, message)
      @stderr.puts "swiss_qr: #{file}: #{message}"
      @status = [@status, status].max
    end

    def usage_error(message)
      @stderr.puts "swiss_qr: #{message}"
      @stderr.puts parser.banner.lines.first(2).join
      FAILURE
    end
  end
end
