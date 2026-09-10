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
