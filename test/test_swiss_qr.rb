# frozen_string_literal: true

require "test_helper"

class TestSwissQr < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::SwissQr::VERSION
  end

  def test_public_api
    assert_equal %i[payload strict], SwissQr.method(:parse).parameters.map(&:last)
    assert_respond_to SwissQr, :valid?
    assert_respond_to SwissQr, :qr_bill?
  end

  def test_error_hierarchy
    assert_operator SwissQr::InvalidPayload, :<, SwissQr::Error
    assert_operator SwissQr::ReaderUnavailable, :<, SwissQr::Error
    assert_operator SwissQr::Error, :<, StandardError
  end

  def test_parser_has_no_runtime_dependency_on_qr_reader
    refute $LOADED_FEATURES.any? { |f| f.include?("qr_reader") }, "qr_reader must only be loaded on demand"
  end
end
