# frozen_string_literal: true

require_relative "lib/swiss_qr/version"

Gem::Specification.new do |spec|
  spec.name = "swiss_qr"
  spec.version = SwissQr::VERSION
  spec.authors = ["Andi Idogawa"]
  spec.email = ["web@idogawa.com"]

  spec.summary = "Parse and validate Swiss QR-bill payloads (QR-Rechnung, QR-facture, QR-fattura)"
  spec.description = <<~DESC.tr("\n", " ").strip
    Parses the payload of the Swiss QR Code on a Swiss QR-bill (QR-Rechnung, QR-facture,
    QR-fattura; Switzerland and Liechtenstein) per the SIX Swiss Implementation
    Guidelines for the QR-bill ("SPC"/"0200") into immutable value objects: account and
    QR-IBAN, creditor and debtor addresses, amount, currency, QR/creditor reference,
    message, Swico S1 billing information and alternative procedures. Validates every
    rule of the guidelines, including IBAN, QR reference and ISO 11649 check digits.
    Optionally reads the QR codes from images and PDFs with the qr_reader gem.
  DESC
  spec.homepage = "https://github.com/largo/swiss_qr"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3.0"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/ .rubocop.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Bill#amount is a BigDecimal (a bundled, no longer default, gem since Ruby 3.4).
  # The optional image/PDF reader, qr_reader, is not a runtime dependency.
  spec.add_dependency "bigdecimal", ">= 3.1"
end
