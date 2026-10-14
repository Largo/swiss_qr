# frozen_string_literal: true

require "test_helper"

class TestSwissQr < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::SwissQr::VERSION
  end

  def test_public_api
    assert_equal %i[payload strict], SwissQr.method(:parse).parameters.map(&:last)
    assert_respond_to SwissQr, :valid?
    assert_respond_to SwissQr, :looks_like_qr_bill?
    assert_equal %i[input reader strict], SwissQr.method(:read).parameters.map(&:last)
    assert_equal %i[input reader strict], SwissQr.method(:read_all).parameters.map(&:last)
    assert_respond_to SwissQr, :reader=
  end

  def test_error_hierarchy
    assert_operator SwissQr::InvalidPayload, :<, SwissQr::Error
    assert_operator SwissQr::ReaderUnavailable, :<, SwissQr::Error
    assert_operator SwissQr::Error, :<, StandardError
  end

  # Whether qr_reader stays unloaded until a read is checked in a subprocess
  # in test_reader.rb (other tests in this process load it).
  def test_gemspec_has_no_qr_reader_runtime_dependency
    spec = Gem::Specification.load(File.expand_path("../swiss_qr.gemspec", __dir__))
    assert_equal ["bigdecimal"], spec.runtime_dependencies.map(&:name)
    assert_includes spec.executables, "swiss_qr"
  end

  # The signatures use Date (stdlib), which consumers' rbs collection only
  # loads when sig/manifest.yaml declares it.
  def test_rbs_manifest_declares_stdlib_dependencies
    root = File.expand_path("..", __dir__)
    manifest = File.read(File.join(root, "sig/manifest.yaml"))
    assert_match(/^\s*- name: date$/, manifest) if File.read(File.join(root, "sig/swiss_qr.rbs")).match?(/\bDate\b/)
  end
end
