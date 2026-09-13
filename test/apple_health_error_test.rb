require "test_helper"

class AppleHealthErrorTest < Minitest::Test
  def test_safe_metadata_is_closed_and_bounded
    error = Cybort::AppleHealthError.new(
      phase: :parse, category: :invalid_record, candidate_ordinal: 2,
      limit_name: :record_bytes,
      counts: {
        candidate_count: 3, imported_record_count: 4,
        "PATH_SENTINEL" => 5, record_count: 6, negative: -1
      }
    )

    assert_equal({
      source: "apple_health", phase: :parse, category: :invalid_record,
      candidate_ordinal: 2, limit_name: :record_bytes,
      counts: { candidate_count: 3, imported_record_count: 4 }
    }, error.safe_metadata)
    refute_includes error.message, "PATH_SENTINEL"
    assert error.safe_metadata.frozen?
  end

  def test_rejects_unknown_taxonomy_values
    assert_raises(ArgumentError) { Cybort::AppleHealthError.new(phase: :unknown, category: :invalid_record) }
    assert_raises(ArgumentError) { Cybort::AppleHealthError.new(phase: :parse, category: :unknown) }
    assert_raises(ArgumentError) { Cybort::AppleHealthError.new(phase: :parse, category: :invalid_record, limit_name: :unknown) }
  end
end
