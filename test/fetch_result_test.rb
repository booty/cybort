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
    refute result.replace_existing_items
  end

  def test_success_result_can_opt_into_current_snapshot_replacement
    result = Cybort::FetchResult.success(
      instance_id: "reddit",
      items: [],
      sync_state: {},
      started_at: Time.utc(2026, 8, 16, 12),
      finished_at: Time.utc(2026, 8, 16, 12, 1),
      source_fetched: true,
      replace_existing_items: true
    )

    assert result.replace_existing_items
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
    refute result.replace_existing_items
  end

  def test_failure_result_preserves_safe_metadata
    metadata = { tool: "gws", exit_category: "nonzero", exit_code: 1 }
    result = Cybort::FetchResult.failure(
      instance_id: "gmail",
      error: Cybort::CommandError.new("gws command failed", metadata: metadata),
      started_at: Time.utc(2026, 8, 16, 12),
      finished_at: Time.utc(2026, 8, 16, 12, 1),
      metadata: metadata
    )

    assert_equal metadata, result.metadata
  end

  def test_direct_construction_defaults_replacement_to_false
    result = Cybort::FetchResult.new(
      instance_id: "rss",
      items: [],
      sync_state: nil,
      started_at: Time.utc(2026, 8, 16, 12),
      finished_at: Time.utc(2026, 8, 16, 12, 1),
      source_fetched: true
    )

    refute result.replace_existing_items
  end

  [nil, 0, "true"].each do |invalid_value|
    define_method("test_direct_construction_rejects_#{invalid_value.inspect.gsub(/\W+/, "_")}_replacement") do
      assert_raises(ArgumentError) do
        Cybort::FetchResult.new(replace_existing_items: invalid_value)
      end
    end
  end

  def test_direct_construction_rejects_replacement_on_error_result
    assert_raises(ArgumentError) do
      Cybort::FetchResult.new(error: RuntimeError.new("boom"), replace_existing_items: true)
    end
  end
end
