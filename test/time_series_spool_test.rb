require "test_helper"

class TimeSeriesSpoolTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir
    @started = Time.utc(2026, 9, 9, 11, 59)
    @finished = Time.utc(2026, 9, 9, 12)
    @clock = -> { @finished }
    @factory = Cybort::TimeSeriesSpoolFactory.new(directory: @directory, clock: @clock)
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def open_writer(mode: :append)
    @factory.open(
      instance_id: "sensor", import_key: "batch-1", import_mode: mode,
      source_started_at: @started
    )
  end

  def register_numeric(writer, key: "office-temperature")
    writer.register_series(
      series_key: key, metric_key: "temperature", value_type: :numeric,
      canonical_unit: "Cel", dimensions: { "room" => "office" }
    )
  end

  def add_numeric(writer, key: "reading-1", value: 21.5, ended_at: nil)
    writer.add_observation(
      series_key: "office-temperature", source_record_key: key,
      observed_at: Time.utc(2026, 9, 9, 12), ended_at: ended_at,
      numeric_value: value, metadata: {}
    )
  end

  def test_finalize_writes_private_schema_manifest_and_streaming_artifact
    writer = open_writer
    register_numeric(writer)
    add_numeric(writer)

    artifact = writer.finalize(
      sync_state: { "cursor" => "reading-1" }, source_finished_at: @finished, metadata: {}
    )

    assert_equal 1, artifact.series_count
    assert_equal 1, artifact.observation_count
    assert_equal @started, artifact.source_started_at
    assert_equal @finished, artifact.source_finished_at
    assert_equal 0o400, File.stat(artifact.path).mode & 0o777
    refute File.exist?("#{artifact.path}-journal")
    assert_equal Digest::SHA256.file(artifact.path).hexdigest, artifact.digest

    database = SQLite3::Database.new(artifact.path)
    assert_equal ["spool_manifest", "spool_observations", "spool_series"],
                 database.execute("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").flatten
    assert_equal 1, database.get_first_value("SELECT COUNT(*) FROM spool_series")
    assert_equal 1, database.get_first_value("SELECT COUNT(*) FROM spool_observations")
    manifest = database.get_first_row("SELECT * FROM spool_manifest")
    assert_equal ([@started.to_r * 1_000_000].first).to_i, manifest[7]
    assert_equal ([@finished.to_r * 1_000_000].first).to_i, manifest[8]
  ensure
    database&.close
  end

  def test_duplicate_series_requires_the_same_definition
    writer = open_writer
    register_numeric(writer)
    writer.register_series(
      series_key: "office-temperature", metric_key: "temperature", value_type: :numeric,
      canonical_unit: "Cel", dimensions: { "room" => "office" }
    )
    assert_raises(ArgumentError) do
      writer.register_series(
        series_key: "office-temperature", metric_key: "temperature", value_type: :numeric,
        canonical_unit: "Fah", dimensions: { "room" => "office" }
      )
    end
  ensure
    writer&.abort
  end

  def test_observation_validation_rejects_unknown_duplicates_wrong_values_and_bad_interval
    writer = open_writer
    register_numeric(writer)
    assert_raises(ArgumentError) { add_numeric(writer, key: "missing", value: 1, ended_at: @started) }
    assert_raises(ArgumentError) do
      writer.add_observation(series_key: "unknown", source_record_key: "x", observed_at: @finished,
                            numeric_value: 1, metadata: {})
    end
    add_numeric(writer)
    assert_raises(ArgumentError) { add_numeric(writer) }
    assert_raises(ArgumentError) { add_numeric(writer, ended_at: @started) }
    assert_raises(ArgumentError) do
      writer.add_observation(series_key: "office-temperature", source_record_key: "both",
                            observed_at: @finished, numeric_value: 1, categorical_value: "hot", metadata: {})
    end
    assert_raises(ArgumentError) do
      writer.add_observation(series_key: "office-temperature", source_record_key: "neither",
                            observed_at: @finished, metadata: {})
    end
  ensure
    writer&.abort
  end

  def test_categorical_series_requires_nil_unit_and_categorical_value
    writer = open_writer
    writer.register_series(series_key: "state", metric_key: "state", value_type: :categorical,
                           canonical_unit: nil, dimensions: {})
    writer.add_observation(series_key: "state", source_record_key: "state-1", observed_at: @finished,
                           categorical_value: "ok", metadata: {})
    assert_raises(ArgumentError) do
      writer.add_observation(series_key: "state", source_record_key: "state-2", observed_at: @finished,
                             numeric_value: 1, metadata: {})
    end
    assert_raises(ArgumentError) do
      writer.register_series(series_key: "bad", metric_key: "state", value_type: :categorical,
                             canonical_unit: "unit", dimensions: {})
    end
  ensure
    writer&.abort
  end

  def test_finalized_writer_rejects_operations_and_abort_is_idempotent
    writer = open_writer
    register_numeric(writer)
    artifact = writer.finalize(sync_state: {}, source_finished_at: @finished, metadata: {})
    assert writer.finalized?
    assert_raises(ArgumentError) { register_numeric(writer, key: "other") }
    assert_raises(ArgumentError) { add_numeric(writer, key: "other") }
    assert_raises(ArgumentError) { writer.finalize(sync_state: {}, source_finished_at: @finished, metadata: {}) }
    writer.abort
    writer.abort
    assert File.exist?(artifact.path)
  end

  def test_time_conversion_and_finish_order_are_validated
    assert_equal(-1, Cybort::TimeSeriesSpoolWriter.utc_microseconds(Time.at(-0.000001).utc))
    writer = open_writer
    assert_raises(ArgumentError) do
      writer.finalize(sync_state: {}, source_finished_at: @started - 1, metadata: {})
    end
    refute File.exist?(writer.path)
  end

  def test_block_form_open_aborts_on_error_and_startup_cleans_only_regular_orphans
    orphan = File.join(@directory, "#{Cybort::TimeSeriesSpoolFactory::SPOOL_PREFIX}orphan")
    File.write(orphan, "stale")
    symlink = File.join(@directory, "#{Cybort::TimeSeriesSpoolFactory::SPOOL_PREFIX}link")
    File.symlink(orphan, symlink)
    @factory = Cybort::TimeSeriesSpoolFactory.new(directory: @directory, clock: @clock)
    refute File.exist?(orphan)
    assert File.symlink?(symlink)

    path = nil
    assert_raises(RuntimeError) do
      @factory.open(instance_id: "sensor", import_key: "batch-2", import_mode: :append,
                    source_started_at: @started) do |writer|
        path = writer.path
        raise "source failed"
      end
    end
    refute File.exist?(path)
    refute File.exist?("#{path}-journal")
  end
end
