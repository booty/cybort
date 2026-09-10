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

  def test_nested_state_and_metadata_are_defensively_copied_and_frozen
    state = { "nested" => { "cursor" => "next" } }
    metadata = { "details" => ["ok", { "count" => 1 }] }
    result = Cybort::TimeSeriesFetchResult.cached(instance_id: "sensor", sync_state: state,
      started_at: @started, finished_at: @finished, metadata: metadata, observation_count: 2)
    state["nested"]["cursor"] << "!"
    metadata["details"][1]["count"] = 2
    assert_equal "next", result.sync_state["nested"]["cursor"]
    assert_equal 1, result.metadata["details"][1]["count"]
    assert result.sync_state["nested"].frozen?
    assert result.metadata["details"].frozen?
  end

  def test_failure_requires_error_and_rejects_malformed_state
    assert_raises(ArgumentError) { Cybort::TimeSeriesFetchResult.failure(instance_id: "sensor", error: nil, started_at: @started, finished_at: @finished) }
    assert_raises(ArgumentError) do
      Cybort::TimeSeriesFetchResult.new(instance_id: "sensor", artifact: nil, sync_state: nil,
        started_at: @started, finished_at: @finished, metadata: {}, source_fetched: true,
        error: StandardError.new("bad"), series_count: 0, observation_count: 0)
    end
  end

  def test_success_rejects_manifest_mismatch
    assert_raises(ArgumentError) do
      Cybort::TimeSeriesFetchResult.success(instance_id: "sensor", artifact: @artifact,
        sync_state: { "cursor" => "other" }, started_at: @started, finished_at: @finished,
        metadata: {}, source_fetched: true)
    end
  end

  def test_artifact_rejects_broad_permissions_and_invalid_mode
    File.chmod(0o644, @path)
    assert_raises(ArgumentError) do
      Cybort::TimeSeriesSpoolArtifact.new(path: @path, instance_id: "sensor", import_key: "page-42",
        import_mode: :append, digest: "a" * 64, series_count: 1, observation_count: 2,
        sync_state: {}, source_started_at: @started, source_finished_at: @finished, metadata: {})
    end
    File.chmod(0o600, @path)
    assert_raises(ArgumentError) do
      Cybort::TimeSeriesSpoolArtifact.new(path: @path, instance_id: "sensor", import_key: "page-42",
        import_mode: :replace, digest: "a" * 64, series_count: 1, observation_count: 2,
        sync_state: {}, source_started_at: @started, source_finished_at: @finished, metadata: {})
    end
    assert_raises(ArgumentError) do
      Cybort::TimeSeriesSpoolArtifact.new(path: @path, instance_id: "sensor", import_key: " ",
        import_mode: :append, digest: "a" * 64, series_count: 1, observation_count: 2,
        sync_state: {}, source_started_at: @started, source_finished_at: @finished, metadata: {})
    end
  end

  def test_artifact_rejects_invalid_digest_counts_and_identifiers
    base = { path: @path, instance_id: "sensor", import_key: "page-42", import_mode: :append,
      digest: "a" * 64, series_count: 1, observation_count: 2, sync_state: {},
      source_started_at: @started, source_finished_at: @finished, metadata: {} }
    assert_raises(ArgumentError) { Cybort::TimeSeriesSpoolArtifact.new(**base.merge(digest: "A" * 64)) }
    assert_raises(ArgumentError) { Cybort::TimeSeriesSpoolArtifact.new(**base.merge(series_count: -1)) }
    assert_raises(ArgumentError) { Cybort::TimeSeriesSpoolArtifact.new(**base.merge(instance_id: "sensor\0")) }
  end
end
