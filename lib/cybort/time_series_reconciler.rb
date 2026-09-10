require "set"

module Cybort
  # Repairs the cross-database commit windows before a source is planned. The
  # main database is acknowledged first; only then is the advisory canonical
  # receipt marker queued. Purges are deliberately processed before imports so
  # an old cursor cannot be acknowledged after its observations were deleted.
  class TimeSeriesReconciler
    def initialize(main_persistence:, time_series_reader:, writer:)
      @main_persistence = main_persistence
      @time_series_reader = time_series_reader
      @writer = writer
    end

    def run
      blocked = {}
      purged = Set.new
      acknowledged = []

      pending_purges.each do |instance_id|
        next if blocked.key?(instance_id)

        begin
          event = submit_and_wait_purge(instance_id)
          ensure_success!(event, phase: :purge, instance_id: instance_id)
          @main_persistence.finish_time_series_purge(instance_id: instance_id)
          purged << instance_id
        rescue StandardError => error
          blocked[instance_id] ||= error
        end
      end

      pending_receipts.each do |receipt|
        instance_id = receipt.instance_id
        next if purged.include?(instance_id) || blocked.key?(instance_id)

        begin
          unless @main_persistence.time_series_import_acknowledged?(
            instance_id: instance_id, import_key: receipt.import_key
          )
            @main_persistence.acknowledge_time_series_import(receipt)
          end
          event = submit_and_wait_acknowledgement(receipt)
          ensure_success!(
            event,
            phase: :acknowledgement,
            instance_id: instance_id,
            import_key: receipt.import_key
          )
          acknowledged << [instance_id, receipt.import_key]
        rescue StandardError => error
          blocked[instance_id] ||= error
        end
      end

      {
        blocked_instances: blocked.keys.sort.freeze,
        errors: blocked.freeze,
        purged_instances: purged.to_a.sort.freeze,
        acknowledged_imports: acknowledged.map(&:freeze).freeze
      }.freeze
    end

    private

    def pending_purges
      rows = @main_persistence.pending_time_series_purges
      Array(rows).filter_map { |row| row_value(row, :instance_id, "instance_id") }.uniq.sort
    end

    def pending_receipts
      Array(@time_series_reader.pending_receipts).sort_by do |receipt|
        [receipt.instance_id, receipt.source_finished_at, receipt.import_key]
      end
    end

    def submit_and_wait_purge(instance_id)
      command_id = @writer.submit_delete_instance(instance_id: instance_id)
      wait_for(command_id)
    end

    def submit_and_wait_acknowledgement(receipt)
      command_id = @writer.submit_acknowledgement(receipt)
      wait_for(command_id)
    end

    def wait_for(command_id)
      if @writer.respond_to?(:event_for)
        @writer.event_for(command_id)
      elsif @writer.respond_to?(:wait_for)
        @writer.wait_for(command_id)
      else
        raise RuntimeError, "time-series writer cannot await terminal events"
      end
    end

    def ensure_success!(event, phase:, instance_id:, import_key: nil)
      unless event.is_a?(TimeSeriesWriterEvent)
        raise RuntimeError, "time-series writer returned an invalid event"
      end
      unless event.phase == phase && event.instance_id == instance_id && event.import_key == import_key
        raise RuntimeError, "time-series writer event correlation mismatch"
      end
      raise event.error if event.result == :failure
      raise RuntimeError, "time-series writer returned an invalid result" unless event.result == :success
      event
    end

    def row_value(row, symbol_key, string_key)
      if row.respond_to?(:key?) && row.key?(symbol_key)
        row.fetch(symbol_key)
      elsif row.respond_to?(:key?) && row.key?(string_key)
        row.fetch(string_key)
      elsif row.respond_to?(symbol_key)
        row.public_send(symbol_key)
      else
        raise ArgumentError, "purge intent is missing its instance ID"
      end
    end
  end
end
