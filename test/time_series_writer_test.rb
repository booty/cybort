require "test_helper"

class TimeSeriesWriterTest < Minitest::Test
  FakePersistence = Struct.new(:imports, :acknowledgements, :deletions, :closed) do
    def import(artifact)
      imports << artifact
      Cybort::TimeSeriesImportReceipt.new(
        instance_id: artifact.instance_id, import_key: artifact.import_key,
        artifact_digest: artifact.digest, import_mode: artifact.import_mode,
        source_started_at: artifact.source_started_at, source_finished_at: artifact.source_finished_at,
        committed_at: artifact.source_finished_at, acknowledged_at: nil,
        imported_series_count: artifact.series_count, imported_observation_count: artifact.observation_count,
        stored_series_count: artifact.series_count, stored_observation_count: artifact.observation_count,
        sync_state: artifact.sync_state, metadata: artifact.metadata
      )
    end

    def mark_acknowledged(receipt)
      acknowledgements << receipt
      receipt
    end

    def delete_instance(instance_id:)
      deletions << instance_id
      true
    end

    def close
      self.closed = true
    end
  end

  def setup
    @events = Queue.new
    @persistence = FakePersistence.new([], [], [], false)
    @writer = Cybort::TimeSeriesWriter.new(
      time_series_persistence_factory: -> { @persistence }, event_queue: @events
    )
  end

  def teardown
    @writer&.close_and_join
  rescue StandardError
    nil
  end

  def test_import_is_serialized_and_publishes_a_frozen_receipt_event
    artifact = fake_artifact("batch-1")
    @writer.start
    command_id = @writer.submit_import(artifact)

    event = @events.pop
    assert_equal command_id, event.command_id
    assert_equal :import, event.phase
    assert_equal "sensor", event.instance_id
    assert_equal "batch-1", event.import_key
    assert event.receipt
    assert_nil event.error
    assert event.frozen?
    assert_equal [artifact], @persistence.imports
  end

  def test_acknowledgement_and_purge_have_correlated_terminal_events
    receipt = fake_receipt("batch-1")
    @writer.start

    acknowledgement_id = @writer.submit_acknowledgement(receipt)
    acknowledgement = @events.pop
    assert_equal acknowledgement_id, acknowledgement.command_id
    assert_equal :acknowledgement, acknowledgement.phase
    assert_equal receipt, acknowledgement.receipt

    purge_id = @writer.submit_delete_instance(instance_id: "sensor")
    purge = @events.pop
    assert_equal purge_id, purge.command_id
    assert_equal :purge, purge.phase
    assert_equal :success, purge.result
    assert_equal ["sensor"], @persistence.deletions
  end

  def test_failed_factory_rejects_late_submissions_and_waits_are_bounded
    failing_writer = Cybort::TimeSeriesWriter.new(
      time_series_persistence_factory: -> { raise "factory failed" }, event_queue: @events
    )
    @writer = failing_writer
    failing_writer.start

    failure = assert_raises(RuntimeError) do
      Timeout.timeout(1) { failing_writer.close_and_join }
    end
    assert_equal "factory failed", failure.message

    submission_failure = assert_raises(RuntimeError) do
      Timeout.timeout(1) { failing_writer.submit_delete_instance(instance_id: "sensor") }
    end
    assert_match(/worker has failed/, submission_failure.message)

    Timeout.timeout(1) do
      assert_raises(ArgumentError) { failing_writer.event_for(1) }
    end
  end

  def test_successful_import_remains_success_when_artifact_cleanup_fails
    cleanup_error = RuntimeError.new("cleanup failed")
    writer = Cybort::TimeSeriesWriter.new(
      time_series_persistence_factory: -> { @persistence }, event_queue: @events,
      artifact_cleanup: ->(_artifact) { raise cleanup_error }
    )
    @writer = writer
    writer.start
    command_id = writer.submit_import(fake_artifact("cleanup-warning"))

    event = @events.pop

    assert_equal command_id, event.command_id
    assert_equal :success, event.result
    assert_nil event.error
    assert_equal [
      { phase: "artifact_cleanup", error_class: "RuntimeError" }
    ], writer.cleanup_failures.fetch(command_id)
  end

  def test_import_error_remains_primary_when_artifact_cleanup_also_fails
    import_error = ArgumentError.new("import failed")
    cleanup_error = RuntimeError.new("cleanup failed")
    persistence = Object.new
    persistence.define_singleton_method(:import) { |_artifact| raise import_error }
    writer = Cybort::TimeSeriesWriter.new(
      time_series_persistence_factory: -> { persistence }, event_queue: @events,
      artifact_cleanup: ->(_artifact) { raise cleanup_error }
    )
    @writer = writer
    writer.start
    command_id = writer.submit_import(fake_artifact("import-error"))

    event = @events.pop

    assert_equal command_id, event.command_id
    assert_equal :failure, event.result
    assert_same import_error, event.error
    assert_equal [
      { phase: "artifact_cleanup", error_class: "RuntimeError" }
    ], event.error.cleanup_failures
    refute_includes event.error.cleanup_failures.first.keys, :message
  end

  private

  def fake_artifact(import_key)
    path = Tempfile.new(["cybort-time-series", ".sqlite3"])
    path.close
    Cybort::TimeSeriesSpoolArtifact.new(
      path: path.path, instance_id: "sensor", import_key: import_key, import_mode: :append,
      digest: Digest::SHA256.file(path.path).hexdigest, series_count: 0, observation_count: 0,
      sync_state: {}, source_started_at: Time.utc(2026, 9, 9, 11),
      source_finished_at: Time.utc(2026, 9, 9, 12), metadata: {}
    )
  end

  def fake_receipt(import_key)
    artifact = fake_artifact(import_key)
    Cybort::TimeSeriesImportReceipt.new(
      instance_id: artifact.instance_id, import_key: artifact.import_key,
      artifact_digest: artifact.digest, import_mode: artifact.import_mode,
      source_started_at: artifact.source_started_at, source_finished_at: artifact.source_finished_at,
      committed_at: artifact.source_finished_at, imported_series_count: 0,
      imported_observation_count: 0, stored_series_count: 0, stored_observation_count: 0,
      sync_state: {}, metadata: {}
    )
  end
end
