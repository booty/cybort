require "test_helper"

class TimeSeriesReaderTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir
    @path = File.join(@directory, "cybort-timeseries.sqlite3")
    persistence = Cybort::TimeSeriesPersistence.new(@path, clock: -> { Time.utc(2026, 9, 9, 12) })
    persistence.setup!
    factory = Cybort::TimeSeriesSpoolFactory.new(directory: @directory)
    writer = factory.open(instance_id: "sensor", import_key: "batch-1", import_mode: :append,
                          source_started_at: Time.utc(2026, 9, 9, 11))
    writer.register_series(series_key: "temperature", metric_key: "temperature", value_type: :numeric,
                           canonical_unit: "Cel", dimensions: { "room" => "office" })
    writer.add_observation(series_key: "temperature", source_record_key: "b",
                           observed_at: Time.utc(2026, 9, 9, 12, 0, 0, 2), numeric_value: 2, metadata: {})
    writer.add_observation(series_key: "temperature", source_record_key: "a",
                           observed_at: Time.utc(2026, 9, 9, 12), numeric_value: 1, metadata: {})
    persistence.import(writer.finalize(sync_state: {}, source_finished_at: Time.utc(2026, 9, 9, 12), metadata: {}))
    persistence.close
    @reader = Cybort::TimeSeriesReader.new(@path)
  end

  def teardown
    @reader&.close
    FileUtils.remove_entry(@directory)
  end

  def test_reader_is_uri_read_only_and_query_only
    database = @reader.instance_variable_get(:@database)
    refute_respond_to @reader, :database
    assert_equal 1, database.get_first_value("PRAGMA query_only")
    ["CREATE TABLE forbidden (id INTEGER)", "UPDATE series SET metric_key = 'wrong'",
     "DELETE FROM observations", "PRAGMA user_version = 99"].each do |sql|
      assert_raises(SQLite3::ReadOnlyException) { database.execute(sql) }
    end
    database.execute("PRAGMA query_only = OFF")
    assert_raises(SQLite3::ReadOnlyException) { database.execute("DELETE FROM series") }
    # SQLite may report IOERR while trying to change the WAL file itself on a
    # read-only handle; ordinary DML above proves READONLY independently.
    assert_raises(SQLite3::ReadOnlyException, SQLite3::IOException) do
      database.execute("PRAGMA journal_mode = DELETE")
    end
    refute_respond_to @reader, :import
    refute_respond_to @reader, :delete_instance
  end

  def test_queries_are_immutable_and_deterministic_in_both_directions
    series = @reader.series_for(instance_id: "sensor", limit: 1).first
    assert series.frozen?
    rows = @reader.observations_for(series_ids: [series.id, series.id],
                                    started_at: Time.utc(2026, 9, 9, 11),
                                    ended_at: Time.utc(2026, 9, 9, 13), limit: 10)
    assert rows.all?(&:frozen?)
    assert rows.first.source_record_key.frozen?
    assert rows.first.observed_at.utc?
    assert rows.first.observed_at.frozen?
    assert rows.first.metadata.frozen?
    assert_equal %w[a b], rows.map(&:source_record_key)
    assert_equal %w[b a], @reader.observations_for(series_ids: [series.id],
                                                    started_at: Time.utc(2026, 9, 9, 11),
                                                    ended_at: Time.utc(2026, 9, 9, 13), limit: 10,
                                                    order: :descending).map(&:source_record_key)
    assert_equal Time.utc(2026, 9, 9, 12), rows.first.observed_at
    assert_equal 2, rows.last.observed_at.usec
    assert_equal ["a"], @reader.observations_for(series_ids: [series.id],
                                                 started_at: rows.first.observed_at,
                                                 ended_at: rows.last.observed_at, limit: 1).map(&:source_record_key)
  end

  def test_range_and_limit_validation_is_bounded
    series_id = @reader.series_for(instance_id: "sensor", limit: 1).first.id
    assert_raises(ArgumentError) { @reader.observations_for(series_ids: [], started_at: Time.now, ended_at: Time.now, limit: 1) }
    assert_raises(ArgumentError) { @reader.observations_for(series_ids: [series_id], started_at: Time.now, ended_at: Time.now - 1, limit: 1) }
    assert_raises(ArgumentError) { @reader.observations_for(series_ids: [series_id], started_at: nil, ended_at: Time.now, limit: 1) }
    assert_raises(ArgumentError) { @reader.observations_for(series_ids: [series_id], started_at: Time.now, ended_at: Time.now, limit: 0) }
    assert_raises(ArgumentError) { @reader.observations_for(series_ids: [series_id], started_at: Time.now, ended_at: Time.now, limit: 10_001) }
    assert_raises(ArgumentError) { @reader.observations_for(series_ids: [series_id], started_at: Time.now, ended_at: Time.now, limit: 1, order: :random) }
    assert_raises(ArgumentError) { @reader.series_for(limit: 0) }
    assert_raises(ArgumentError) { @reader.series_for(limit: 1_001) }
    assert_raises(ArgumentError) { @reader.series_for(after_id: "1", limit: 1) }
    ["1", 1.0, nil, 0, -1].each do |invalid_id|
      assert_raises(ArgumentError) do
        @reader.observations_for(series_ids: [invalid_id], started_at: Time.now, ended_at: Time.now, limit: 1)
      end
    end
    assert_raises(ArgumentError) do
      @reader.observations_for(series_ids: (1..501).to_a, started_at: Time.now, ended_at: Time.now, limit: 1)
    end
  end

  def test_pending_receipts_are_read_only_and_acknowledgement_is_reflected
    assert_equal ["batch-1"], @reader.pending_receipts.map(&:import_key)
  end

  def test_series_keyset_pagination_and_filters
    first = @reader.series_for(instance_id: "sensor", metric_key: "temperature", limit: 1).first
    assert_equal "temperature", first.series_key
    assert_empty @reader.series_for(after_id: first.id, limit: 1)
    assert_empty @reader.series_for(instance_id: "other", limit: 1)
    assert_empty @reader.series_for(metric_key: "other", limit: 1)
    assert_equal({ series_count: 0, observation_count: 0, sync_state: nil }, @reader.context_for(instance_id: "missing"))
  end

  def test_read_only_open_does_not_create_a_missing_database
    missing = File.join(@directory, "missing.sqlite3")
    assert_raises(SQLite3::CantOpenException) { Cybort::TimeSeriesReader.new(missing) }
    refute File.exist?(missing)
  end
end
