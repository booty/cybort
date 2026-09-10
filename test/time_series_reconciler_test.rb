require "test_helper"

class TimeSeriesReconcilerTest < Minitest::Test
  def test_pending_receipt_is_acknowledged_before_marker_is_submitted
    receipt = receipt_for("batch-1")
    main = MainSpy.new(receipt)
    reader = ReaderSpy.new([receipt])
    writer = WriterSpy.new

    result = Cybort::TimeSeriesReconciler.new(
      main_persistence: main, time_series_reader: reader, writer: writer
    ).run

    assert_equal [receipt], main.acknowledgements
    assert_equal [receipt], writer.acknowledgements
    assert_empty result.fetch(:blocked_instances)
  end

  class MainSpy
    attr_reader :acknowledgements

    def initialize(receipt)
      @receipt = receipt
      @acknowledgements = []
    end

    def time_series_import_acknowledged?(instance_id:, import_key:)
      false
    end

    def acknowledge_time_series_import(receipt)
      @acknowledgements << receipt
      true
    end

    def pending_time_series_purges
      []
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
    attr_reader :acknowledgements

    def initialize
      @acknowledgements = []
      @command_id = 0
    end

    def submit_acknowledgement(receipt)
      @acknowledgements << receipt
      @command_id += 1
      @command_id
    end

    def event_for(command_id)
      Cybort::TimeSeriesWriterEvent.new(
        command_id: command_id, phase: :acknowledgement,
        instance_id: "sensor", import_key: "batch-1", result: :success,
        receipt: @acknowledgements.last, error: nil
      )
    end
  end

  private

  def receipt_for(import_key)
    Cybort::TimeSeriesImportReceipt.new(
      instance_id: "sensor", import_key: import_key, artifact_digest: "a" * 64,
      import_mode: :append, source_started_at: Time.utc(2026, 9, 9, 11),
      source_finished_at: Time.utc(2026, 9, 9, 12), committed_at: Time.utc(2026, 9, 9, 12),
      imported_series_count: 0, imported_observation_count: 0, stored_series_count: 0,
      stored_observation_count: 0, sync_state: {}, metadata: {}
    )
  end
end
