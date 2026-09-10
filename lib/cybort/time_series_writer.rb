require "fileutils"
require "timeout"

module Cybort
  # The writer is the sole owner of a writable time-series persistence object
  # during a collection run. Commands are queued by callers, but all
  # persistence calls happen on the worker thread created here.
  class TimeSeriesWriter
    Command = Struct.new(:command_id, :phase, :instance_id, :import_key, :payload, keyword_init: true)
    SENTINEL = Object.new.freeze
    COMMAND_SEQUENCE_MUTEX = Mutex.new
    @command_sequence = 0

    attr_reader :event_queue

    def initialize(time_series_persistence_factory:, event_queue: Queue.new, artifact_cleanup: nil)
      unless time_series_persistence_factory.respond_to?(:call)
        raise ArgumentError, "time-series persistence factory must be callable"
      end
      unless event_queue.respond_to?(:<<)
        raise ArgumentError, "time-series writer event queue must accept events"
      end
      if artifact_cleanup && !artifact_cleanup.respond_to?(:call)
        raise ArgumentError, "artifact cleanup must be callable"
      end

      @time_series_persistence_factory = time_series_persistence_factory
      @event_queue = event_queue
      @artifact_cleanup = artifact_cleanup || method(:cleanup_artifact)
      @commands = Queue.new
      @state_mutex = Mutex.new
      @event_waiters = {}
      @events = {}
      @known_command_ids = {}
      @started = false
      @closing = false
      @closed = false
      @worker_failure = nil
      @thread = nil
    end

    # Start exactly one worker. The persistence factory is called inside the
    # worker, ensuring no SQLite-backed object crosses the thread boundary.
    def start
      @state_mutex.synchronize do
        raise RuntimeError, "time-series writer has already started" if @started

        @started = true
        begin
          @thread = Thread.new { worker_main }
          @thread.report_on_exception = false
        rescue Exception
          @started = false
          @thread = nil
          raise
        end
      end
      self
    end

    def submit_import(artifact)
      unless artifact.is_a?(TimeSeriesSpoolArtifact)
        raise ArgumentError, "expected a finalized time-series spool artifact"
      end

      enqueue(
        phase: :import,
        instance_id: artifact.instance_id,
        import_key: artifact.import_key,
        payload: artifact
      )
    end

    def submit_acknowledgement(receipt)
      unless receipt.is_a?(TimeSeriesImportReceipt)
        raise ArgumentError, "expected a time-series import receipt"
      end

      enqueue(
        phase: :acknowledgement,
        instance_id: receipt.instance_id,
        import_key: receipt.import_key,
        payload: receipt
      )
    end

    def submit_delete_instance(instance_id:)
      validate_identifier!(instance_id, "instance_id", 256)
      enqueue(phase: :purge, instance_id: instance_id, import_key: nil, payload: instance_id)
    end

    # Wait for one command's terminal event without consuming the shared event
    # queue. This lets a caller use the queue for its event loop while recovery
    # waits for a command it submitted synchronously.
    def event_for(command_id, timeout: nil)
      waiter = @state_mutex.synchronize do
        unless @known_command_ids.key?(command_id)
          raise ArgumentError, "unknown time-series writer command"
        end

        @event_waiters.fetch(command_id)
      end
      value = if timeout.nil?
        waiter.pop
      else
        waiter.pop(timeout: timeout)
      end
      raise Timeout::Error, "timed out waiting for time-series writer command" if value.nil?

      value
    end

    alias wait_for event_for

    # Enqueue a sentinel after all accepted commands. Thread#value both joins
    # and re-raises an abnormal worker exception. Repeated calls do not enqueue
    # another sentinel and therefore remain idempotent.
    def close_and_join
      thread = @state_mutex.synchronize do
        raise RuntimeError, "time-series writer has not started" unless @started

        unless @closing
          @closing = true
          @commands << SENTINEL
        end
        @thread
      end

      begin
        thread.value
      rescue Exception => error # rubocop:disable Lint/RescueException -- preserve abnormal worker termination
        @state_mutex.synchronize do
          @closed = true
          @worker_failure ||= error
        end
        raise
      else
        @state_mutex.synchronize { @closed = true }
        nil
      end
    end

    private

    def enqueue(phase:, instance_id:, import_key:, payload:)
      @state_mutex.synchronize do
        if !@started
          raise RuntimeError, "time-series writer has not started"
        elsif @closing || @closed
          raise RuntimeError, "time-series writer is closed"
        end

        command_id = self.class.next_command_id
        command = Command.new(
          command_id: command_id,
          phase: phase,
          instance_id: instance_id,
          import_key: import_key,
          payload: payload
        ).freeze
        @known_command_ids[command_id] = true
        @event_waiters[command_id] = Queue.new
        @commands << command
        command_id
      end
    end

    def worker_main
      persistence = nil
      active_error = nil
      begin
        persistence = @time_series_persistence_factory.call
        loop do
          command = @commands.pop
          break if command.equal?(SENTINEL)

          process(command, persistence)
        end
      rescue Exception => error # rubocop:disable Lint/RescueException -- Thread#value must observe abnormal worker termination
        active_error = error
        fail_pending_commands(error)
        raise
      ensure
        begin
          persistence.close if persistence && persistence.respond_to?(:close)
        rescue Exception => close_error # rubocop:disable Lint/RescueException -- preserve an earlier worker error
          if active_error
            attach_cleanup_failure(active_error, close_error, phase: "persistence_close")
          else
            active_error = close_error
            raise
          end
        ensure
          publish_worker_failure(active_error) if active_error
        end
      end
    end

    def process(command, persistence)
      case command.phase
      when :import
        process_import(command, persistence)
      when :acknowledgement
        process_acknowledgement(command, persistence)
      when :purge
        process_purge(command, persistence)
      else
        publish_failure(command, ArgumentError.new("invalid time-series writer phase"))
      end
    end

    def process_import(command, persistence)
      artifact = command.payload
      active_error = nil
      receipt = nil
      event = nil
      begin
        begin
          receipt = persistence.import(artifact)
          unless receipt.is_a?(TimeSeriesImportReceipt)
            raise ArgumentError, "time-series persistence returned an invalid import receipt"
          end
          event = TimeSeriesWriterEvent.new(
            command_id: command.command_id,
            phase: command.phase,
            instance_id: command.instance_id,
            import_key: command.import_key,
            result: :success,
            receipt: receipt,
            error: nil
          )
        rescue StandardError => error
          active_error = error
          event = failure_event(command, error)
        rescue Exception => error # rubocop:disable Lint/RescueException -- cleanup must precede abnormal propagation
          active_error = error
          event = failure_event(command, error)
        end
      ensure
        begin
          @artifact_cleanup.call(artifact)
        rescue Exception => cleanup_error # rubocop:disable Lint/RescueException -- cleanup must not mask persistence failure
          if active_error
            attach_cleanup_failure(active_error, cleanup_error, phase: "artifact_cleanup")
          else
            event = failure_event(command, cleanup_error)
          end
        end
        publish_event(event) if event
      end
      raise active_error if active_error && !active_error.is_a?(StandardError)
    end

    def process_acknowledgement(command, persistence)
      active_error = nil
      event = nil
      begin
        begin
          receipt = persistence.mark_acknowledged(command.payload)
          unless receipt.is_a?(TimeSeriesImportReceipt)
            raise ArgumentError, "time-series persistence returned an invalid acknowledgement receipt"
          end
          event = TimeSeriesWriterEvent.new(
            command_id: command.command_id,
            phase: command.phase,
            instance_id: command.instance_id,
            import_key: command.import_key,
            result: :success,
            receipt: receipt,
            error: nil
          )
        rescue StandardError => error
          event = failure_event(command, error)
        rescue Exception => error # rubocop:disable Lint/RescueException -- terminal event precedes abnormal propagation
          active_error = error
          event = failure_event(command, error)
        end
        publish_event(event)
      end
      raise active_error if active_error
    end

    def process_purge(command, persistence)
      active_error = nil
      event = nil
      begin
        begin
          persistence.delete_instance(instance_id: command.instance_id)
          event = TimeSeriesWriterEvent.new(
            command_id: command.command_id,
            phase: command.phase,
            instance_id: command.instance_id,
            import_key: nil,
            result: :success,
            receipt: nil,
            error: nil
          )
        rescue StandardError => error
          event = failure_event(command, error)
        rescue Exception => error # rubocop:disable Lint/RescueException -- terminal event precedes abnormal propagation
          active_error = error
          event = failure_event(command, error)
        end
        publish_event(event)
      end
      raise active_error if active_error
    end

    def publish_failure(command, error)
      publish_event(failure_event(command, error))
    end

    def failure_event(command, error)
      TimeSeriesWriterEvent.new(
        command_id: command.command_id,
        phase: command.phase,
        instance_id: command.instance_id,
        import_key: command.import_key,
        result: :failure,
        receipt: nil,
        error: error
      )
    end

    def publish_event(event)
      @state_mutex.synchronize do
        @events[event.command_id] = event
      end
      @event_queue << event
      @state_mutex.synchronize do
        @event_waiters.fetch(event.command_id) << event
      end
    end

    def publish_worker_failure(error)
      @state_mutex.synchronize do
        @worker_failure ||= error
      end
    end

    # A worker can fail before it reaches commands (for example while opening
    # persistence). Give each accepted command a correlated terminal event so
    # callers cannot wait forever, while Thread#value still exposes the
    # abnormal lifecycle error to the owner.
    def fail_pending_commands(error)
      loop do
        command = @commands.pop(true)
        break if command.equal?(SENTINEL)

        publish_event(failure_event(command, error))
      end
    rescue ThreadError
      nil
    end

    def cleanup_artifact(artifact)
      [artifact.path, "#{artifact.path}-journal", "#{artifact.path}-wal", "#{artifact.path}-shm"].each do |path|
        FileUtils.rm_f(path)
      end
      nil
    end

    def attach_cleanup_failure(error, cleanup_error, phase:)
      details = [{ phase: phase, error_class: cleanup_error.class.name.to_s[0, 128] }.freeze].freeze
      begin
        error.instance_variable_set(:@cleanup_failures, details)
        error.define_singleton_method(:cleanup_failures) { @cleanup_failures }
      rescue Exception # rubocop:disable Lint/RescueException -- preserve the active error if it cannot be annotated
        nil
      end
    end

    def validate_identifier!(value, label, max_bytes)
      value = value.dup.force_encoding(Encoding::UTF_8) if value.is_a?(String)
      valid = value.is_a?(String) && value.valid_encoding? && !value.strip.empty? &&
              value.bytesize <= max_bytes && !value.match?(/[\x00-\x1f\x7f]/)
      raise ArgumentError, "invalid #{label}" unless valid
    end

    class << self
      def next_command_id
        COMMAND_SEQUENCE_MUTEX.synchronize do
          @command_sequence += 1
        end
      end
    end
  end

  # Data supplies value semantics and immutability. The custom constructor
  # keeps invalid phase/correlation combinations from crossing a thread/event
  # boundary and makes every terminal event structurally self-describing.
  TimeSeriesWriterEvent = Data.define(
    :command_id, :phase, :instance_id, :import_key, :result, :receipt, :error
  ) do
    PHASES = %i[import acknowledgement purge].freeze
    RESULTS = %i[success failure].freeze

    def initialize(command_id:, phase:, instance_id:, import_key:, result:, receipt:, error:)
      validate_command_id!(command_id)
      raise ArgumentError, "invalid writer event phase" unless PHASES.include?(phase)
      validate_identifier!(instance_id, "instance_id", 256)
      validate_identifier!(import_key, "import_key", 256) if phase != :purge
      raise ArgumentError, "purge event cannot carry an import key" if phase == :purge && !import_key.nil?
      raise ArgumentError, "invalid writer event result" unless RESULTS.include?(result)

      if result == :success
        raise ArgumentError, "successful writer event cannot carry an error" unless error.nil?
        if phase == :purge
          raise ArgumentError, "purge event cannot carry a receipt" unless receipt.nil?
        else
          unless receipt.is_a?(TimeSeriesImportReceipt) &&
                 receipt.instance_id == instance_id && receipt.import_key == import_key
            raise ArgumentError, "writer receipt does not match event correlation"
          end
        end
      else
        raise ArgumentError, "failed writer event requires an error" unless error.is_a?(Exception)
        raise ArgumentError, "failed writer event cannot carry a receipt" unless receipt.nil?
      end

      super
    end

    private

    def validate_command_id!(value)
      raise ArgumentError, "command_id must be a positive integer" unless value.is_a?(Integer) && value.positive?
    end

    def validate_identifier!(value, label, max_bytes)
      value = value.dup.force_encoding(Encoding::UTF_8) if value.is_a?(String)
      valid = value.is_a?(String) && value.valid_encoding? && !value.strip.empty? &&
              value.bytesize <= max_bytes && !value.match?(/[\x00-\x1f\x7f]/)
      raise ArgumentError, "invalid #{label}" unless valid
    end
  end
end
