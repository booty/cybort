require "test_helper"

class TimeSeriesImportProjectionTest < Minitest::Test
  def test_projects_only_safe_import_counts
    receipt = Cybort::TimeSeriesImportReceipt.new(
      instance_id: "health", import_key: "archive-1", artifact_digest: "a" * 64,
      import_mode: :append, source_started_at: Time.utc(2026, 9, 9, 11),
      source_finished_at: Time.utc(2026, 9, 9, 12), committed_at: Time.utc(2026, 9, 9, 12),
      imported_series_count: 2, imported_observation_count: 3,
      inserted_observation_count: 2, duplicate_observation_count: 1,
      unchanged_observation_count: 1, changed_observation_count: 0,
      deleted_observation_count: 0, stored_series_count: 4,
      stored_observation_count: 8, sync_state: { "archive_sha256" => "private" },
      metadata: { "path" => "/private" }
    )

    projection = Cybort::TimeSeriesImportProjection.from_receipt(receipt)
    assert_equal({
      imported: 3, inserted: 2, duplicate: 1, unchanged: 1, changed: 0,
      deleted: 0, stored_series: 4, stored_observations: 8
    }, projection.to_h)
    refute projection.respond_to?(:artifact_digest)
    assert projection.frozen?
  end

  def test_rejects_inconsistent_or_negative_counts
    assert_raises(ArgumentError) do
      Cybort::TimeSeriesImportProjection.new(
        imported: 1, inserted: 1, duplicate: 0, unchanged: 1, changed: 0,
        deleted: 0, stored_series: 0, stored_observations: 0
      )
    end
    assert_raises(ArgumentError) do
      Cybort::TimeSeriesImportProjection.new(
        imported: -1, inserted: 0, duplicate: 0, unchanged: 0, changed: 0,
        deleted: 0, stored_series: 0, stored_observations: 0
      )
    end
  end
end
