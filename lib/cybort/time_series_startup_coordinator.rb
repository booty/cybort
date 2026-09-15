module Cybort
  # Owns time-series writer startup and recovery coordination without taking
  # ownership of source planning, worker execution, or canonical persistence.
  class TimeSeriesStartupCoordinator
    def initialize(persistence:, reader:, persistence_factory:, startup_error: nil)
      @persistence = persistence
      @reader = reader
      @persistence_factory = persistence_factory
      @startup_error = startup_error
    end

    def prepare(result_kinds:, completions:)
      pending_purge_rows = if @persistence.respond_to?(:pending_time_series_purges)
        Array(@persistence.pending_time_series_purges)
      else
        []
      end
      pending_receipt_error = nil
      pending_receipt_rows = if @reader
        begin
          Array(@reader.pending_receipts)
        rescue StandardError
          # A partially initialized or unavailable reader must not prevent
          # item-only collection. Durable pending work remains for the next
          # run to reconcile after startup recovers.
          pending_receipt_error = TimeSeriesStartupError.new
          []
        end
      else
        []
      end
      recovery_instance_ids = (pending_purge_rows.filter_map { |row| recovery_instance_id(row) } +
        pending_receipt_rows.filter_map { |receipt| recovery_instance_id(receipt) }).uniq
      required = result_kinds.value?(:time_series) || !pending_purge_rows.empty? || !pending_receipt_rows.empty?
      return [nil, empty_recovery] unless required

      if pending_receipt_error
        return [nil, blocked_recovery(
          result_kinds, recovery_instance_ids, @startup_error || pending_receipt_error
        )]
      end

      if @startup_error
        return [nil, blocked_recovery(result_kinds, recovery_instance_ids, @startup_error)]
      end

      unless @reader && @persistence_factory
        raise ConfigurationError, "time-series collection or recovery requires a reader and persistence factory"
      end

      writer = TimeSeriesWriter.new(
        time_series_persistence_factory: @persistence_factory,
        event_queue: completions
      ).start
      if (writer_error = writer.wait_until_ready)
        return [writer, blocked_recovery(result_kinds, recovery_instance_ids, writer_error)]
      end

      recovery = begin
        TimeSeriesReconciler.new(
          main_persistence: @persistence, time_series_reader: @reader, writer: writer
        ).run
      rescue StandardError
        # Recovery reads the reader again after writer startup. A persistent
        # read/decode failure isolates recovery and time-series instances while
        # allowing item sources to continue.
        startup_error = TimeSeriesStartupError.new
        drain_recovery_events(completions)
        return [writer, blocked_recovery(result_kinds, recovery_instance_ids, startup_error)]
      end
      # Recovery consumes command-specific waiters. Its terminal events are
      # already observed and must not be confused with source commands.
      drain_recovery_events(completions)
      [writer, recovery.merge(writer_failure: nil)]
    rescue Exception # rubocop:disable Lint/RescueException -- startup owns the writer until it returns
      begin
        writer&.close_and_join
      rescue Exception # preserve the startup error
        nil
      end
      raise
    end

    private

    def empty_recovery
      { blocked_instances: [], errors: {} }
    end

    def drain_recovery_events(completions)
      completions.pop(true) until completions.empty?
    end

    def blocked_recovery(result_kinds, recovery_instance_ids, error)
      blocked_ids = (result_kinds.filter_map do |instance_id, result_kind|
        instance_id if result_kind == :time_series
      end + recovery_instance_ids).uniq.sort
      errors = blocked_ids.each_with_object({}) do |instance_id, blocked|
        blocked[instance_id] = error
      end
      { blocked_instances: errors.keys.sort.freeze, errors: errors.freeze,
        writer_failure: error }
    end

    def recovery_instance_id(value)
      if value.respond_to?(:key?) && value.key?(:instance_id)
        value[:instance_id]
      elsif value.respond_to?(:key?) && value.key?("instance_id")
        value["instance_id"]
      elsif value.respond_to?(:instance_id)
        value.instance_id
      end
    end
  end
end
