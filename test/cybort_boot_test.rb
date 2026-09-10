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
end
