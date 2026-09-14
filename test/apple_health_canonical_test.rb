require "test_helper"
require "time"

class AppleHealthCanonicalTest < Minitest::Test
  def test_equivalent_decimal_spellings_share_identity
    first = Cybort::AppleHealthCanonical.parse_decimal("1.0")
    second = Cybort::AppleHealthCanonical.parse_decimal("01e0")

    assert_equal first.identity, second.identity
    assert_equal 1.0, first.numeric_value
  end

  def test_timestamp_preserves_offset_and_floors_to_microseconds
    timestamp = Cybort::AppleHealthCanonical.parse_timestamp(
      "2026-03-08 01:59:59.123456789 -0500", field: :start_date
    )

    assert_equal(-300, timestamp.offset_minutes)
    assert_equal 123_456, timestamp.utc_microseconds % 1_000_000
  end

  def test_record_identity_is_independent_of_attribute_and_metadata_order
    attributes = {
      "type" => "HKQuantityTypeIdentifierStepCount", "value_type" => :numeric,
      "unit" => "count", "value" => "1.0", "creationDate" => "2026-09-10 09:00:00 -0400",
      "startDate" => "2026-09-10 08:00:00 -0400", "endDate" => "2026-09-10 08:01:00 -0400",
      "sourceName" => "Watch"
    }
    first = Cybort::AppleHealthCanonical.normalize_record(
      attributes: attributes, metadata_entries: [["custom", "value"], ["HKWasUserEntered", "1"]]
    )
    second = Cybort::AppleHealthCanonical.normalize_record(
      attributes: attributes.to_a.reverse.to_h, metadata_entries: [["HKWasUserEntered", "true"], ["custom", "value"]]
    )

    assert_equal first.source_record_key, second.source_record_key
    assert_match(/\Aapple-health-record-v1:/, first.source_record_key)
    assert_match(/\Aapple-health-record-v1:/, first.series_key)
    assert_equal "HKQuantityTypeIdentifierStepCount", first.metric_key
    assert_equal({ "user_entered" => true, "start_offset_minutes" => -240,
                   "creation_offset_minutes" => -240, "end_offset_minutes" => -240 }, first.metadata)
    refute_includes first.metadata.keys, "custom"
  end

  def test_invalid_decimal_and_timestamp_are_rejected
    assert_raises(ArgumentError) { Cybort::AppleHealthCanonical.parse_decimal("NaN") }
    assert_raises(ArgumentError) { Cybort::AppleHealthCanonical.parse_timestamp("2026-01-01T00:00:00", field: :start_date) }
    assert_raises(Cybort::AppleHealthCanonical::InvalidTimestampError) do
      Cybort::AppleHealthCanonical.parse_timestamp("2026-02-30T00:00:00Z", field: :start_date)
    end
  end
end
