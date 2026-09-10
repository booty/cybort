require "test_helper"

class TimeSeriesPersistenceTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir
    @path = File.join(@directory, "cybort-timeseries.sqlite3")
    @started = Time.utc(2026, 9, 9, 11, 59)
    @finished = Time.utc(2026, 9, 9, 12)
    @clock = -> { @finished }
    @factory = Cybort::TimeSeriesSpoolFactory.new(directory: @directory, clock: @clock)
    @persistence = Cybort::TimeSeriesPersistence.new(@path, clock: @clock)
    @persistence.setup!
  end

  def teardown
    @reader&.close
    @persistence&.close
    FileUtils.remove_entry(@directory)
  end

  def artifact(instance_id: "sensor", import_key: "batch-1", mode: :append, value: 21.5,
               include_observation: true, key: "reading-1", source_finished_at: @finished,
               dimensions: { "room" => "office" }, metric_key: "temperature", unit: "Cel")
    writer = @factory.open(instance_id: instance_id, import_key: import_key,
                           import_mode: mode, source_started_at: @started)
    writer.register_series(series_key: "temperature", metric_key: metric_key,
                           value_type: :numeric, canonical_unit: unit, dimensions: dimensions)
    if include_observation
      writer.add_observation(series_key: "temperature", source_record_key: key,
                             observed_at: @finished, numeric_value: value, metadata: {})
    end
    writer.finalize(sync_state: { "cursor" => import_key }, source_finished_at: source_finished_at,
                    metadata: { "fixture" => true })
  end

  def second_series_artifact(import_key:, mode: :snapshot)
    writer = @factory.open(instance_id: "sensor", import_key: import_key,
                           import_mode: mode, source_started_at: @started)
    writer.register_series(series_key: "humidity", metric_key: "humidity",
                           value_type: :numeric, canonical_unit: "%", dimensions: {})
    writer.add_observation(series_key: "humidity", source_record_key: "reading-2",
                           observed_at: @finished + 1, numeric_value: 40, metadata: {})
    writer.finalize(sync_state: { "cursor" => import_key }, source_finished_at: @finished,
                    metadata: {})
  end

  def test_setup_uses_canonical_schema_wal_and_busy_timeout
    database = SQLite3::Database.new(@path)
    names = database.execute("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").flatten
    assert_equal %w[observations series time_series_imports time_series_instance_state time_series_schema_migrations], names
    assert_equal %w[idx_observations_series_time idx_observations_time_series],
                 database.execute("SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_autoindex%' ORDER BY name").flatten
    assert_equal "wal", database.get_first_value("PRAGMA journal_mode")
    assert_equal 5_000, writer_database.get_first_value("PRAGMA busy_timeout")
    assert_equal 1, writer_database.get_first_value("PRAGMA foreign_keys")
    assert_equal 0o600, File.stat(@path).mode & 0o777
  ensure
    database&.close
  end

  def test_append_upserts_stable_observations_and_preserves_absent_rows
    @persistence.import(artifact)
    @persistence.import(artifact(import_key: "additional", key: "reading-2"))
    replacement = artifact(import_key: "batch-2", value: 22.0, key: "reading-1")
    @persistence.import(replacement)
    rows = reader.observations_for(series_ids: [series_id], started_at: @started,
                                   ended_at: @finished + 10, limit: 10)
    assert_equal %w[reading-1 reading-2], rows.map(&:source_record_key)
    assert_equal 22.0, rows.first.numeric_value
  end

  def test_snapshot_replaces_only_the_instance_and_preserves_registered_empty_series
    @persistence.import(artifact)
    @persistence.import(second_series_artifact(import_key: "batch-2"))
    context = reader.context_for(instance_id: "sensor")
    assert_equal 1, context[:series_count]
    assert_equal 1, context[:observation_count]
    assert_equal ["humidity"], reader.series_for(instance_id: "sensor", limit: 10).map(&:series_key)

    empty = @factory.open(instance_id: "other", import_key: "empty", import_mode: :snapshot,
                          source_started_at: @started)
    empty.register_series(series_key: "state", metric_key: "state", value_type: :categorical,
                          canonical_unit: nil, dimensions: {})
    empty_artifact = empty.finalize(sync_state: {}, source_finished_at: @finished, metadata: {})
    @persistence.import(empty_artifact)
    @persistence.import(artifact(instance_id: "sensor", import_key: "batch-3", mode: :snapshot,
                                 include_observation: false))
    assert_equal 0, reader.context_for(instance_id: "sensor")[:observation_count]
    assert_equal ["temperature"], reader.series_for(instance_id: "sensor", limit: 10).map(&:series_key)
    assert_equal ["state"], reader.series_for(instance_id: "other", limit: 10).map(&:series_key)
  end

  def test_changed_artifact_is_rejected_before_replacing_the_prior_snapshot
    @persistence.import(artifact)
    invalid = artifact(import_key: "broken", mode: :snapshot)
    File.chmod(0o600, invalid.path)
    database = SQLite3::Database.new(invalid.path)
    database.execute("PRAGMA ignore_check_constraints = ON")
    database.execute("UPDATE spool_observations SET ended_at_us = observed_at_us - 1")
    database.close
    assert_raises(ArgumentError) { @persistence.import(invalid) }
    assert_equal ["reading-1"], reader.observations_for(series_ids: [series_id], started_at: @started,
                                                         ended_at: @finished + 10, limit: 10).map(&:source_record_key)
  end

  def test_import_key_is_idempotent_but_digest_conflicts_are_rejected
    original = artifact
    first = @persistence.import(original)
    @finished += 60
    second = @persistence.import(original)
    assert_equal first.import_key, second.import_key
    assert_equal first.committed_at, second.committed_at
    assert_equal first.committed_at, observations.first.ingested_at
    assert_raises(ArgumentError) { @persistence.import(artifact(import_key: "batch-1", value: 22.0)) }
  end

  def test_receipt_acknowledgement_is_pending_then_complete
    receipt = @persistence.import(artifact)
    assert_nil receipt.acknowledged_at
    assert_equal [receipt.import_key], reader.pending_receipts.map(&:import_key)
    acknowledged = @persistence.mark_acknowledged(receipt)
    assert_equal @finished, acknowledged.acknowledged_at
    assert_equal @finished, @persistence.mark_acknowledged(receipt).acknowledged_at
    assert_empty reader.pending_receipts
  end

  def test_writable_persistence_is_owned_by_its_creator_thread
    receipt = @persistence.import(artifact)
    calls = [-> { @persistence.setup! }, -> { @persistence.import(artifact) },
             -> { @persistence.mark_acknowledged(receipt) },
             -> { @persistence.delete_instance(instance_id: "sensor") },
             -> { @persistence.backup_to(File.join(@directory, "wrong-thread.sqlite3")) },
             -> { @persistence.close }]
    calls.each { |call| assert_instance_of RuntimeError, Thread.new { call.call rescue $! }.value }
    assert_equal 1, reader.context_for(instance_id: "sensor")[:observation_count]
  end

  def test_delete_instance_and_backup_to_are_set_oriented
    @persistence.import(artifact)
    backup = File.join(@directory, "backup.sqlite3")
    assert_equal backup, @persistence.backup_to(backup)
    assert File.file?(backup)
    assert_equal 0o600, File.stat(backup).mode & 0o777
    backup_reader = Cybort::TimeSeriesReader.new(backup)
    assert_equal 1, backup_reader.context_for(instance_id: "sensor")[:observation_count]
    assert_raises(Cybort::ValidationError) { @persistence.backup_to(backup) }
    assert @persistence.delete_instance(instance_id: "sensor")
    refute @persistence.delete_instance(instance_id: "sensor")
    assert_empty reader.pending_receipts
    assert_empty reader.series_for(instance_id: "sensor", limit: 10)
  ensure
    backup_reader&.close
  end

  def test_empty_snapshot_removes_only_its_instance
    @persistence.import(artifact)
    @persistence.import(artifact(instance_id: "other"))
    writer = @factory.open(instance_id: "sensor", import_key: "empty", import_mode: :snapshot, source_started_at: @started)
    receipt = @persistence.import(writer.finalize(sync_state: {}, source_finished_at: @finished, metadata: {}))
    assert_equal [0, 0], [receipt.stored_series_count, receipt.stored_observation_count]
    assert_empty reader.series_for(instance_id: "sensor", limit: 10)
    assert_equal 1, reader.context_for(instance_id: "other")[:observation_count]
  end

  def test_receipts_preserve_source_times_and_distinguish_imported_and_stored_counts
    @persistence.import(artifact)
    source_finished_at = @finished - 1
    @finished += 120
    receipt = @persistence.import(artifact(import_key: "next", key: "reading-2", source_finished_at: source_finished_at))
    assert_equal @started, receipt.source_started_at
    assert_equal source_finished_at, receipt.source_finished_at
    assert_equal @finished, receipt.committed_at
    assert_equal [1, 1, 1, 2], [receipt.imported_series_count, receipt.imported_observation_count,
                              receipt.stored_series_count, receipt.stored_observation_count]
    assert receipt.frozen?
    assert receipt.sync_state.frozen?
    assert_equal({ "cursor" => "next" }, reader.context_for(instance_id: "sensor")[:sync_state])
  end

  def test_only_changed_normalized_dimensions_advance_series_update_time
    @persistence.import(artifact(dimensions: { "room" => "office", "floor" => 1 }))
    original = reader.series_for(limit: 1).first
    @finished += 60
    @persistence.import(artifact(import_key: "reordered", dimensions: { "floor" => 1, "room" => "office" }))
    assert_equal original.updated_at, reader.series_for(limit: 1).first.updated_at
    @persistence.import(artifact(import_key: "changed", dimensions: { "floor" => 2, "room" => "office" }))
    changed = reader.series_for(limit: 1).first
    assert_equal @finished, changed.updated_at
    assert_equal original.created_at, changed.created_at
    assert_equal 2, changed.dimensions["floor"]
  end

  def test_existing_metric_value_type_and_unit_are_immutable
    @persistence.import(artifact)
    assert_raises(ArgumentError) { @persistence.import(artifact(import_key: "metric", metric_key: "different")) }
    assert_raises(ArgumentError) { @persistence.import(artifact(import_key: "unit", unit: "K")) }
    writer = @factory.open(instance_id: "sensor", import_key: "type", import_mode: :snapshot, source_started_at: @started)
    writer.register_series(series_key: "temperature", metric_key: "temperature", value_type: :categorical,
                           canonical_unit: nil, dimensions: {})
    assert_raises(ArgumentError) do
      @persistence.import(writer.finalize(sync_state: {}, source_finished_at: @finished, metadata: {}))
    end
    assert_equal 21.5, observations.first.numeric_value
    assert_equal ["batch-1"], reader.pending_receipts.map(&:import_key)
  end

  def test_canonical_constraint_failure_rolls_back_rows_state_and_receipts
    @persistence.import(artifact)
    writer_database.execute(<<~SQL)
      CREATE TRIGGER fail_receipt BEFORE INSERT ON time_series_imports
      BEGIN SELECT RAISE(ABORT, 'injected constraint failure'); END
    SQL
    assert_raises(SQLite3::ConstraintException) do
      @persistence.import(second_series_artifact(import_key: "broken"))
    end
    assert_equal ["temperature"], reader.series_for(limit: 10).map(&:series_key)
    assert_equal 21.5, observations.first.numeric_value
    assert_equal({ "cursor" => "batch-1" }, reader.context_for(instance_id: "sensor")[:sync_state])
    assert_equal ["batch-1"], reader.pending_receipts.map(&:import_key)
    refute_includes writer_database.execute("PRAGMA database_list").map { |row| row["name"] }, "incoming"
  end

  def test_independent_validation_rejects_resigned_invalid_spools
    mutations = [
      "UPDATE spool_observations SET numeric_value = NULL, categorical_value = 'bad'",
      "UPDATE spool_observations SET ended_at_us = observed_at_us - 1",
      "UPDATE spool_manifest SET instance_id = 'other'",
      "UPDATE spool_manifest SET source_finished_at_us = source_started_at_us - 1",
      "UPDATE spool_manifest SET observation_count = 99",
      "UPDATE spool_series SET dimensions_json = '{\"nested\":{}}'",
      "ALTER TABLE spool_series ADD COLUMN unexpected TEXT",
      "DROP TABLE spool_observations"
    ]
    mutations.each_with_index do |sql, index|
      invalid = mutate_artifact(artifact(import_key: "invalid-#{index}"), sql)
      assert_raises(ArgumentError) { @persistence.import(invalid) }
    end
    assert_empty reader.pending_receipts
    assert_empty reader.series_for(limit: 1)
  end

  def test_escaped_attachment_is_immutable_and_cannot_write
    incoming = artifact
    special_path = File.join(@directory, "spool ' % ? # ü.sqlite3")
    File.rename(incoming.path, special_path)
    incoming = copy_artifact(incoming, path: special_path)
    database = writer_database
    original_execute = database.method(:execute)
    writes_rejected = []
    database.define_singleton_method(:execute) do |sql, *binds, &block|
      result = original_execute.call(sql, *binds, &block)
      if sql == "ATTACH DATABASE ? AS incoming"
        begin
          original_execute.call("DELETE FROM incoming.spool_observations")
        rescue SQLite3::ReadOnlyException
          writes_rejected << true
        end
      end
      result
    end
    @persistence.import(incoming)
    assert_equal [true], writes_rejected
    assert_equal incoming.digest, Digest::SHA256.file(special_path).hexdigest
    assert_equal 1, observations.length
  ensure
    database&.define_singleton_method(:execute, original_execute) if original_execute
  end

  def test_detach_failure_preserves_active_error_and_bounded_cleanup_context
    incoming = artifact
    database = writer_database
    original_execute = database.method(:execute)
    primary = SQLite3::ConstraintException.new("primary")
    database.define_singleton_method(:execute) do |sql, *binds, &block|
      raise primary if sql.include?("INSERT INTO series")
      raise SQLite3::Exception, "private cleanup details" if sql == "DETACH DATABASE incoming"
      original_execute.call(sql, *binds, &block)
    end
    caught = assert_raises(SQLite3::ConstraintException) { @persistence.import(incoming) }
    assert_same primary, caught
    assert_equal [{ phase: "detach_incoming", error_class: "SQLite3::Exception" }], caught.cleanup_failures
    assert_empty reader.pending_receipts
  ensure
    database&.define_singleton_method(:execute, original_execute) if original_execute
    database&.execute("DETACH DATABASE incoming") if database
  end

  private

  def writer_database
    @persistence.instance_variable_get(:@database)
  end

  def observations
    reader.observations_for(series_ids: [series_id], started_at: @started,
                            ended_at: @finished + 10, limit: 10)
  end

  def copy_artifact(source, **overrides)
    keys = %i[path instance_id import_key import_mode digest series_count observation_count sync_state
              source_started_at source_finished_at metadata]
    Cybort::TimeSeriesSpoolArtifact.new(**keys.to_h { |key| [key, source.public_send(key)] }.merge(overrides))
  end

  def mutate_artifact(source, sql)
    File.chmod(0o600, source.path)
    database = SQLite3::Database.new(source.path)
    database.execute("PRAGMA ignore_check_constraints = ON")
    database.execute(sql)
    database.close
    File.chmod(0o400, source.path)
    copy_artifact(source, digest: Digest::SHA256.file(source.path).hexdigest)
  ensure
    database&.close unless database&.closed?
  end

  def reader
    @reader ||= Cybort::TimeSeriesReader.new(@path)
  end

  def series_id
    reader.series_for(instance_id: "sensor", limit: 10).first.id
  end
end
