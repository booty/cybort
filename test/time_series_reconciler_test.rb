require "test_helper"
require "set"

class TimeSeriesReconcilerTest < Minitest::Test
  def test_pending_receipt_is_acknowledged_before_marker_is_submitted
    receipt = receipt_for("sensor", "batch-1")
    main = MainSpy.new
    reader = ReaderSpy.new([receipt])
    writer = WriterSpy.new

    result = Cybort::TimeSeriesReconciler.new(
      main_persistence: main, time_series_reader: reader, writer: writer
    ).run

    assert_equal [receipt], main.acknowledgements
    assert_equal [receipt], writer.acknowledgements
    assert_empty result.fetch(:blocked_instances)
  end

  def test_purges_run_first_in_instance_order_and_failures_are_isolated
    receipts = %w[d e].map { |instance_id| receipt_for(instance_id, "batch-1") }
    purge_error = RuntimeError.new("purge failed")
    marker_error = RuntimeError.new("marker failed")
    main = MainSpy.new(pending_purges: %w[c a b].map { |id| { "instance_id" => id } })
    reader = ReaderSpy.new(receipts)
    writer = WriterSpy.new(
      purge_errors: { "b" => purge_error },
      acknowledgement_errors: { "d" => marker_error }
    )

    result = Cybort::TimeSeriesReconciler.new(
      main_persistence: main, time_series_reader: reader, writer: writer
    ).run

    assert_equal [
      [:purge, "a"], [:purge, "b"], [:purge, "c"],
      [:acknowledgement, "d"], [:acknowledgement, "e"]
    ], writer.calls
    assert_equal %w[a c], main.purged
    assert_equal %w[b d], result.fetch(:blocked_instances)
    assert_equal receipts, main.acknowledgements
    assert_equal receipts, writer.acknowledgements
  end

  def test_marker_failure_rerun_is_idempotent_after_main_acknowledgement
    receipt = receipt_for("sensor", "batch-1")
    main = MainSpy.new
    first_writer = WriterSpy.new(acknowledgement_errors: { "sensor" => RuntimeError.new("marker failed") })

    first = Cybort::TimeSeriesReconciler.new(
      main_persistence: main, time_series_reader: ReaderSpy.new([receipt]), writer: first_writer
    ).run

    assert_equal ["sensor"], first.fetch(:blocked_instances)
    assert_equal [receipt], main.acknowledgements
    assert_equal [receipt], first_writer.acknowledgements

    second_writer = WriterSpy.new
    second = Cybort::TimeSeriesReconciler.new(
      main_persistence: main, time_series_reader: ReaderSpy.new([receipt]), writer: second_writer
    ).run

    assert_empty second.fetch(:blocked_instances)
    assert_equal [receipt], main.acknowledgements
    assert_equal [receipt], second_writer.acknowledgements
  end

  def test_pending_receipt_recovers_after_main_ack_and_canonical_marker_failure
    with_recovery_stores do |main, main_path, time_series_path, reader, receipt, clock|
      first = run_reconciliation(
        main: main, reader: reader,
        writer: actual_writer(time_series_path, clock, failure: :acknowledgement)
      )

      assert_equal ["sensor"], first.fetch(:blocked_instances)
      assert main.time_series_import_acknowledged?(instance_id: "sensor", import_key: "batch-1")
      assert_equal 1, main.fetch_runs_for(instance_id: "sensor").length
      assert_equal 1, sqlite_count(main_path, "time_series_acknowledgements")
      assert_equal ["batch-1"], reader.pending_receipts.map(&:import_key)
      assert_equal 1, sqlite_count(time_series_path, "time_series_imports")

      second = run_reconciliation(
        main: main, reader: reader,
        writer: actual_writer(time_series_path, clock)
      )

      assert_empty second.fetch(:blocked_instances)
      assert_empty reader.pending_receipts
      assert_equal 1, main.fetch_runs_for(instance_id: "sensor").length
      assert_equal 1, sqlite_count(main_path, "time_series_acknowledgements")
      assert_equal 1, sqlite_count(time_series_path, "time_series_imports")
    end
  end

  def test_pending_purge_recovers_after_canonical_delete_failure
    with_recovery_stores do |main, main_path, time_series_path, reader, _receipt, clock|
      assert main.begin_time_series_purge(instance_id: "sensor")
      refute main.begin_time_series_purge(instance_id: "sensor")

      first = run_reconciliation(
        main: main, reader: reader,
        writer: actual_writer(time_series_path, clock, failure: :purge)
      )

      assert_equal ["sensor"], first.fetch(:blocked_instances)
      assert_equal ["sensor"], main.pending_time_series_purges.map { |row| row.fetch("instance_id") }
      assert_equal 1, sqlite_count(time_series_path, "time_series_imports")

      second = run_reconciliation(
        main: main, reader: reader,
        writer: actual_writer(time_series_path, clock)
      )

      assert_empty second.fetch(:blocked_instances)
      assert_empty main.pending_time_series_purges
      assert_nil main.instance_record("sensor")
      assert_empty main.fetch_runs_for(instance_id: "sensor")
      assert_equal 0, sqlite_count(main_path, "time_series_acknowledgements")
      assert_empty reader.pending_receipts
      assert_equal 0, sqlite_count(time_series_path, "time_series_imports")
      assert_equal 0, sqlite_count(time_series_path, "time_series_instance_state")
      assert_equal 0, sqlite_count(time_series_path, "series")
      assert_equal 0, sqlite_count(time_series_path, "observations")
    end
  end

  class MainSpy
    attr_reader :acknowledgements

    attr_reader :purged

    def initialize(pending_purges: [])
      @acknowledgements = []
      @acknowledged = Set.new
      @pending_purges = pending_purges
      @purged = []
    end

    def time_series_import_acknowledged?(instance_id:, import_key:)
      @acknowledged.include?([instance_id, import_key])
    end

    def acknowledge_time_series_import(receipt)
      @acknowledgements << receipt
      @acknowledged << [receipt.instance_id, receipt.import_key]
      true
    end

    def pending_time_series_purges
      @pending_purges
    end

    def finish_time_series_purge(instance_id:)
      @purged << instance_id
    end
  end

  class ReaderSpy
    def initialize(receipts)
      @receipts = receipts
    end

    def pending_receipts
      @receipts
    end
  end

  class WriterSpy
    attr_reader :acknowledgements, :calls

    def initialize(purge_errors: {}, acknowledgement_errors: {})
      @acknowledgements = []
      @calls = []
      @purge_errors = purge_errors
      @acknowledgement_errors = acknowledgement_errors
      @command_id = 0
      @commands = {}
    end

    def submit_acknowledgement(receipt)
      @acknowledgements << receipt
      @calls << [:acknowledgement, receipt.instance_id]
      @command_id += 1
      @commands[@command_id] = [:acknowledgement, receipt]
      @command_id
    end

    def submit_delete_instance(instance_id:)
      @calls << [:purge, instance_id]
      @command_id += 1
      @commands[@command_id] = [:purge, instance_id]
      @command_id
    end

    def event_for(command_id)
      phase, payload = @commands.fetch(command_id)
      instance_id = phase == :purge ? payload : payload.instance_id
      import_key = phase == :purge ? nil : payload.import_key
      error = phase == :purge ? @purge_errors[instance_id] : @acknowledgement_errors[instance_id]
      event_receipt = if error || phase == :purge
        nil
      else
        payload
      end
      Cybort::TimeSeriesWriterEvent.new(
        command_id: command_id, phase: phase, instance_id: instance_id,
        import_key: import_key, result: error ? :failure : :success,
        receipt: event_receipt, error: error
      )
    end
  end

  private

  def with_recovery_stores
    directory = Dir.mktmpdir
    clock = -> { Time.utc(2026, 9, 9, 12) }
    main = Cybort::Persistence.new(File.join(directory, "cybort.sqlite3"), clock: clock)
    main.setup!
    main.register_instance(
      Cybort::Configuration::Instance.new(
        id: "sensor", name: "Sensor", adapter: "time_series", ttl_minutes: 30,
        num_items_to_fetch: 10, options: {}
      )
    )

    time_series_path = File.join(directory, "cybort-timeseries.sqlite3")
    factory = Cybort::TimeSeriesSpoolFactory.new(directory: directory, clock: clock)
    bootstrap = Cybort::TimeSeriesPersistence.new(time_series_path, clock: clock)
    bootstrap.setup!
    receipt = bootstrap.import(actual_artifact(factory, clock))
    bootstrap.close
    bootstrap = nil
    reader = Cybort::TimeSeriesReader.new(time_series_path)

    yield main, File.join(directory, "cybort.sqlite3"), time_series_path, reader, receipt, clock
  ensure
    reader&.close
    bootstrap&.close
    FileUtils.remove_entry(directory) if directory && File.exist?(directory)
  end

  def actual_artifact(factory, clock)
    finished_at = clock.call
    spool = factory.open(
      instance_id: "sensor", import_key: "batch-1", import_mode: :append,
      source_started_at: finished_at - 60
    )
    spool.register_series(
      series_key: "temperature", metric_key: "temperature", value_type: :numeric,
      canonical_unit: "Cel", dimensions: {}
    )
    spool.add_observation(
      series_key: "temperature", source_record_key: "reading-1", observed_at: finished_at,
      numeric_value: 21.5, metadata: {}
    )
    spool.finalize(
      sync_state: { "cursor" => "batch-1" }, source_finished_at: finished_at,
      metadata: { "fixture" => true }
    )
  end

  def actual_writer(time_series_path, clock, failure: nil)
    failure_error = RuntimeError.new("injected canonical #{failure} failure") if failure
    factory = lambda do
      persistence = Cybort::TimeSeriesPersistence.new(time_series_path, clock: clock).tap(&:setup!)
      case failure
      when :acknowledgement
        persistence.define_singleton_method(:mark_acknowledged) do |_receipt|
          raise failure_error
        end
      when :purge
        persistence.define_singleton_method(:delete_instance) do |instance_id:|
          raise failure_error
        end
      end
      persistence
    end
    Cybort::TimeSeriesWriter.new(time_series_persistence_factory: factory)
  end

  def run_reconciliation(main:, reader:, writer:)
    started = false
    writer.start
    started = true
    startup_error = writer.wait_until_ready
    raise startup_error if startup_error

    Cybort::TimeSeriesReconciler.new(
      main_persistence: main, time_series_reader: reader, writer: writer
    ).run
  ensure
    writer.close_and_join if started
  end

  def sqlite_count(path, table)
    database = SQLite3::Database.new(path)
    database.get_first_value("SELECT COUNT(*) FROM #{table}")
  ensure
    database&.close
  end

  def receipt_for(instance_id, import_key)
    Cybort::TimeSeriesImportReceipt.new(
      instance_id: instance_id, import_key: import_key, artifact_digest: "a" * 64,
      import_mode: :append, source_started_at: Time.utc(2026, 9, 9, 11),
      source_finished_at: Time.utc(2026, 9, 9, 12), committed_at: Time.utc(2026, 9, 9, 12),
      imported_series_count: 0, imported_observation_count: 0, stored_series_count: 0,
      stored_observation_count: 0, sync_state: {}, metadata: {}
    )
  end
end
