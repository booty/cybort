require "test_helper"

class TimeSeriesJSONTest < Minitest::Test
  def test_dimensions_are_copied_and_frozen
    input = { "room" => "office", "enabled" => true, "value" => 2.5 }
    result = Cybort::TimeSeriesJSON.validate_dimensions!(input)
    input["room"] << "!"
    refute_same input, result
    assert result.frozen?
    assert result["room"].frozen?
  end

  def test_dimensions_reject_nested_values_and_nonfinite_floats
    assert_raises(ArgumentError) { Cybort::TimeSeriesJSON.validate_dimensions!({ "x" => [] }) }
    assert_raises(ArgumentError) { Cybort::TimeSeriesJSON.validate_dimensions!({ "x" => Float::NAN }) }
  end

  def test_metadata_enforces_depth_and_encoded_size
    nested = value = {}
    9.times { nested["x"] = {}; nested = nested["x"] }
    assert_raises(ArgumentError) { Cybort::TimeSeriesJSON.validate_metadata!(value) }
    assert_raises(ArgumentError) { Cybort::TimeSeriesJSON.validate_metadata!({ "x" => "a" * (64 * 1024) }) }
  end

  def test_metadata_rejects_symbol_keys_and_unsupported_values
    assert_raises(ArgumentError) { Cybort::TimeSeriesJSON.validate_metadata!({ x: 1 }) }
    assert_raises(ArgumentError) { Cybort::TimeSeriesJSON.validate_metadata!({ "x" => :symbol }) }
  end
end
