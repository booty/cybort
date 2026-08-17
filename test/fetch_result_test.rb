require "test_helper"

class FetchResultTest < Minitest::Test
  def test_success_result_preserves_items_state_and_source_fetch_flag
    result = Cybort::FetchResult.success(
      instance_id: "rss",
      items: [],
      sync_state: { cursor: "next" },
      started_at: Time.utc(2026, 8, 16, 12),
      finished_at: Time.utc(2026, 8, 16, 12, 1),
      metadata: { status: 200 },
      source_fetched: false
    )

    assert result.success?
    refute result.failure?
    assert_equal({ cursor: "next" }, result.sync_state)
    refute result.source_fetched
  end

  def test_failure_result_preserves_original_error
    error = RuntimeError.new("network unavailable")
    result = Cybort::FetchResult.failure(
      instance_id: "rss",
      error: error,
      started_at: Time.utc(2026, 8, 16, 12),
      finished_at: Time.utc(2026, 8, 16, 12, 1)
    )

    refute result.success?
    assert result.failure?
    assert_same error, result.error
  end
end

