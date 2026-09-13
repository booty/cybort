require "test_helper"

class CybortBootTest < Minitest::Test
  def test_cybort_loads_with_a_version
    assert_equal "0.1.0", Cybort::VERSION
  end

  def test_cybort_loads_time_series_contracts
    assert_respond_to Cybort::TimeSeriesJSON, :validate_dimensions!
    assert_respond_to Cybort::TimeSeriesFetchResult, :success
    assert_respond_to Cybort::TimeSeriesSpoolArtifact, :new
  end

  def test_pins_apple_health_parser_dependencies
    assert_equal "3.6.0", Gem.loaded_specs.fetch("rubyzip").version.to_s
    assert_equal "1.19.4", Gem.loaded_specs.fetch("nokogiri").version.to_s
    assert defined?(Zip::File)
    assert defined?(Nokogiri::XML::SAX::Parser)
  end
end
