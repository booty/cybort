require "test_helper"

class TimeSeriesFetchResultTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "spool.sqlite3")
    File.write(@path, "fixture")
    File.chmod(0o600, @path)
    @started = Time.utc(2026, 9, 9, 11, 59)
    @finished = Time.utc(2026, 9, 9, 12)
    @artifact = Cybort::TimeSeriesSpoolArtifact.new(
      path: @path, instance_id: "sensor", import_key: "page-42", import_mode: :append,
      digest: "a" * 64, series_count: 1, observation_count: 2, sync_state: { "cursor" => "next" },
      source_started_at: @started, source_finished_at: @finished, metadata: {}
    )
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_success_requires_and_matches_artifact
    result = Cybort::TimeSeriesFetchResult.success(
      instance_id: "sensor", artifact: @artifact, sync_state: { "cursor" => "next" },
      started_at: @started, finished_at: @finished, metadata: {}, source_fetched: true
    )
    assert result.success?
    assert_same @artifact, result.artifact
    assert_equal 2, result.observation_count
    assert result.frozen?
  end

  def test_cached_and_failure_forbid_artifacts_and_failure_has_zero_counts
    assert_raises(ArgumentError) do
      Cybort::TimeSeriesFetchResult.cached(instance_id: "sensor", artifact: @artifact,
        sync_state: {}, started_at: @started, finished_at: @finished, observation_count: 2)
    end
    failure = Cybort::TimeSeriesFetchResult.failure(instance_id: "sensor", error: StandardError.new("x"),
      started_at: @started, finished_at: @finished)
    assert failure.failure?
    assert_equal 0, failure.observation_count
    assert_nil failure.sync_state
  end

  def test_artifact_rejects_broad_permissions_and_invalid_mode
    File.chmod(0o644, @path)
    assert_raises(ArgumentError) do
      Cybort::TimeSeriesSpoolArtifact.new(path: @path, instance_id: "sensor", import_key: "page-42",
        import_mode: :append, digest: "a" * 64, series_count: 1, observation_count: 2,
        sync_state: {}, source_started_at: @started, source_finished_at: @finished, metadata: {})
    end
  end
end
