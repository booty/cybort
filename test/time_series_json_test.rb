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

  def test_dimensions_cover_collection_key_string_and_encoded_boundaries
    assert_equal 32, Cybort::TimeSeriesJSON.validate_dimensions!(32.times.to_h { |i| [i.to_s, i] }).length
    assert_raises(ArgumentError) { Cybort::TimeSeriesJSON.validate_dimensions!(33.times.to_h { |i| [i.to_s, i] }) }
    assert_equal 128, Cybort::TimeSeriesJSON.validate_dimensions!({ "k" * 128 => true }).keys.first.bytesize
    assert_raises(ArgumentError) { Cybort::TimeSeriesJSON.validate_dimensions!({ "k" * 129 => true }) }
    assert_equal 512, Cybort::TimeSeriesJSON.validate_dimensions!({ "x" => "a" * 512 })["x"].bytesize
    assert_raises(ArgumentError) { Cybort::TimeSeriesJSON.validate_dimensions!({ "x" => "a" * 513 }) }
    assert_operator JSON.generate(Cybort::TimeSeriesJSON.validate_dimensions!(31.times.to_h { |i| [i.to_s, "a" * 512] })).bytesize, :<, 16 * 1024
    assert_raises(ArgumentError) { Cybort::TimeSeriesJSON.validate_dimensions!(32.times.to_h { |i| [i.to_s, "a" * 512] }) }
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

  def test_metadata_cover_collection_string_and_positive_scalar_boundaries
    assert_equal 256, Cybort::TimeSeriesJSON.validate_metadata!({ "x" => Array.new(256, true) })["x"].length
    assert_raises(ArgumentError) { Cybort::TimeSeriesJSON.validate_metadata!({ "x" => Array.new(257, true) }) }
    assert_equal 128, Cybort::TimeSeriesJSON.validate_metadata!({ "k" * 128 => 1 }).keys.first.bytesize
    assert_raises(ArgumentError) { Cybort::TimeSeriesJSON.validate_metadata!({ "k" * 129 => 1 }) }
    assert_equal 4096, Cybort::TimeSeriesJSON.validate_metadata!({ "x" => "a" * 4096 })["x"].bytesize
    assert_raises(ArgumentError) { Cybort::TimeSeriesJSON.validate_metadata!({ "x" => "a" * 4097 }) }
    assert_equal 1.5, Cybort::TimeSeriesJSON.validate_metadata!({ "x" => 1.5 })["x"]
    exact = Cybort::TimeSeriesJSON.validate_metadata!({ "x" => Array.new(27, "a" * 2424) })
    assert_equal 64 * 1024, JSON.generate(exact).bytesize
    assert_raises(ArgumentError) { Cybort::TimeSeriesJSON.validate_metadata!({ "x" => Array.new(27) { |i| i.zero? ? "a" * 2425 : "a" * 2424 } }) }
  end

  def test_rejects_non_utf8_strings
    assert_raises(ArgumentError) { Cybort::TimeSeriesJSON.validate_metadata!({ "x" => "\xFF".b }) }
  end
end
