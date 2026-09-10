require "set"
require "fileutils"

module Cybort
  class InstanceRunStatus
    attr_reader :instance_id, :status, :source_fetched, :item_count, :error, :metadata,
                :series_count, :observation_count

    def initialize(instance_id:, status:, source_fetched:, item_count:, error: nil, metadata: {},
                   series_count: 0, observation_count: 0)
      @instance_id = instance_id
      @status = status
      @source_fetched = source_fetched
      @item_count = item_count
      @error = error
      @metadata = metadata || {}
      @series_count = series_count
      @observation_count = observation_count
    end

    def to_h
      {
        id: instance_id,
        status: status,
        source_fetched: source_fetched,
        item_count: item_count,
        series_count: series_count,
        observation_count: observation_count,
        error: error && "#{error.class}: #{error.message}",
        metadata: metadata
      }
    end
  end

  class RunResult
    attr_reader :instances, :overall_status, :unavailable_dependencies

    def initialize(instances, unavailable_dependencies: [])
      @instances = instances
      @unavailable_dependencies = unavailable_dependencies
      @overall_status = if instances.all? { |status| status.status == :success || status.status == :cached }
        :success
      elsif instances.all? { |status| status.status == :failure }
        :failure
      else
        :partial_failure
      end
    end
  end

  class Orchestrator
    CLEANUP_FAILURE_LIMIT = 8
    CLEANUP_FAILURE_FIELD_BYTES = 128

    def initialize(configuration:, persistence:, registry:, http_client:, clock: -> { Time.now.utc },
                   command_runner: nil, dependency_checker: nil,
                   monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                   progress: nil, time_series_reader: nil,
                   time_series_persistence_factory: nil, time_series_spool_factory: nil)
      @configuration = configuration
      @persistence = persistence
      @registry = registry
      @http_client = http_client
      @clock = clock
      @command_runner = command_runner || CommandRunner.new(monotonic_clock: monotonic_clock)
      @dependency_checker = dependency_checker || DependencyChecker.new(command_runner: @command_runner)
      @monotonic_clock = monotonic_clock
      @progress = progress
      @time_series_reader = time_series_reader
      @time_series_persistence_factory = time_series_persistence_factory
      @time_series_spool_factory = time_series_spool_factory
    end

    def run(force_fetch: false)
      threads = {}
      completions = Queue.new
      instances = @configuration.instances
      @registry.validate_configuration!(instances)
      result_kinds = instances.values.to_h do |instance|
        [instance.id, @registry.result_kind_for(instance)]
      end.freeze
      time_series_writer, recovery = prepare_time_series(result_kinds, completions)
      results = {}
      recovery.fetch(:errors).each do |instance_id, error|
        next unless instances.key?(instance_id)

        results[instance_id] = failure_result(
          result_kind: result_kinds.fetch(instance_id),
          instance_id: instance_id,
          error: error,
          started_at: @clock.call,
          finished_at: @clock.call,
          metadata: { "recovery" => "blocked" }
        )
      end
      retention_ttl_minutes_by_instance_id = instances.values.to_h do |instance|
        [instance.id, instance.retention_ttl_minutes]
      end.freeze
      hard_expired_items_by_instance_id = instances.values.to_h do |instance|
        count = if result_kinds.fetch(instance.id) == :items && instance.hard_expiry_ttl_minutes &&
                   !recovery.fetch(:errors).key?(instance.id)
          @persistence.expire_items(
            instance_id: instance.id,
            hard_expiry_ttl_minutes: instance.hard_expiry_ttl_minutes
          )
        else
          0
        end
        [instance.id, count]
      end.freeze
      contexts = instances.transform_values do |instance|
        context = if @persistence.respond_to?(:planning_context_for)
          @persistence.planning_context_for(instance_id: instance.id)
        else
          @persistence.context_for(instance_id: instance.id)
        end
        if result_kinds.fetch(instance.id) == :time_series
          context.merge(time_series_context_for(instance.id))
        else
          context
        end
      end

      planned_at = @clock.call
      plans = instances.values.to_h do |instance|
        next [instance.id, { plan: nil }] if results.key?(instance.id)

        plan = @registry.plan(
          instance: instance,
          context: contexts.fetch(instance.id),
          force_fetch: force_fetch,
          planned_at: planned_at
        )
        [instance.id, { plan: plan }]
      end

      plans.each do |instance_id, entry|
        next unless entry.fetch(:plan) && entry.fetch(:plan).fetch_mode == :cached

        unless result_kinds.fetch(instance_id) == :time_series
          entry[:plan] = entry.fetch(:plan).with(
            context: @persistence.context_for(instance_id: instance_id)
          )
        end
      end

      dependency_groups = Hash.new { |groups, executable| groups[executable] = [] }
      plans.each_value do |entry|
        plan = entry.fetch(:plan)
        next unless plan
        next unless plan.fetch_mode == :remote

        @registry.dependencies_for(plan.instance).each do |dependency|
          dependency_groups[dependency.executable] << dependency
        end
      end
      resolution_cache = dependency_groups.transform_values do |dependencies|
        canonical = dependencies.find(&:version_requirement) || dependencies.first
        @dependency_checker.resolve(canonical)
      end
      unavailable = {}
      plans.each_value do |entry|
        plan = entry.fetch(:plan)
        next unless plan
        instance = plan.instance
        dependencies = plan.fetch_mode == :remote ? @registry.dependencies_for(instance) : []
        resolutions = {}
        dependency_failures = []
        dependencies.each do |dependency|
          resolution = @dependency_checker.validate_version!(dependency, resolution_cache.fetch(dependency.executable))
          resolutions[dependency.executable] = resolution
          dependency_failures << resolution unless resolution.available?
        end

        entry[:plan] = plan.with(dependency_requirements: dependencies, resolutions: resolutions)
        next if dependency_failures.empty?

        results[instance.id] = dependency_failure_result(instance, dependency_failures, result_kind: result_kinds.fetch(instance.id))
        dependency_failures.each do |failure|
          guidance = dependency_guidance(failure)
          key = guidance.values_at(:tool, :category, :purpose, :install_hint, :auth_hint)
          unavailable[key] ||= guidance.merge(instances: [])
          unavailable[key][:instances] << instance.id
        end
      end

      plans.each_value do |entry|
        next if results.key?(entry.fetch(:plan)&.instance&.id)

        plan = entry.fetch(:plan)
        next unless plan
        entry[:adapter] = @registry.build(
          instance: plan.instance,
          context: plan.context,
          http_client: @http_client,
          clock: @clock,
          command_runner: @command_runner,
          dependency_resolutions: plan.resolutions,
          monotonic_clock: @monotonic_clock,
          spool_factory: @time_series_spool_factory
        )
      end

      instances.each_value { |instance| @persistence.register_instance(instance) }
      results.each do |instance_id, result|
        completions << [:result, instance_id, result]
      end

      statuses_by_instance_id = {}
      pending_writer_commands = {}
      cleanup_error = nil
      begin
        plans.each do |instance_id, entry|
          next if results.key?(instance_id)

          plan = entry.fetch(:plan)
          adapter = entry.fetch(:adapter)
          progress_puts(fetch_start_message(plan)) if @progress && plan.fetch_mode == :remote
          threads[instance_id] = start_worker do
            Thread.current.report_on_exception = false
            begin
              adapter.fetch(
                force_fetch: force_fetch,
                fetch_mode: plan.fetch_mode,
                planned_at: plan.planned_at
              )
            rescue StandardError => error
              failure_result(
                result_kind: result_kinds.fetch(instance_id),
                instance_id: instance_id,
                error: error,
                started_at: @clock.call,
                finished_at: @clock.call,
                metadata: error.respond_to?(:safe_metadata) ? error.safe_metadata : {}
              )
            ensure
              completions << [:thread, instance_id, Thread.current]
            end
          end
        end

        while statuses_by_instance_id.length < instances.length
          event = completions.pop
          if event.is_a?(TimeSeriesWriterEvent)
            status = handle_writer_event(
              event,
              pending_writer_commands: pending_writer_commands,
              instances: instances,
              time_series_writer: time_series_writer
            )
            statuses_by_instance_id[status.instance_id] = status if status
            next
          end

          kind, instance_id, payload = event
          result = kind == :thread ? payload.value : payload
          instance = instances.fetch(instance_id)
          plan = plans.fetch(instance_id).fetch(:plan)
          status = persist_result(
            instance: instance,
            result: result,
            result_kind: result_kinds.fetch(instance_id),
            planned_fetch_mode: plan&.fetch_mode,
            retention_ttl_minutes: retention_ttl_minutes_by_instance_id.fetch(instance_id),
            context: contexts.fetch(instance_id),
            hard_expired_items: hard_expired_items_by_instance_id.fetch(instance_id),
            time_series_writer: time_series_writer,
            pending_writer_commands: pending_writer_commands
          )
          statuses_by_instance_id[instance_id] = status if status
        end
      end

      statuses = instances.values.map do |instance|
        statuses_by_instance_id.fetch(instance.id) do
          raise RuntimeError, "missing terminal status for #{instance.id}"
        end
      end
      guidance = unavailable.values.map { |value| value.merge(instances: value.fetch(:instances).sort) }
      RunResult.new(statuses, unavailable_dependencies: guidance.sort_by { |value| [value.fetch(:tool), value.fetch(:instances)] })
    ensure
      active_error = $!
      artifacts = []
      threads.each_value do |thread|
        begin
          result = thread.value
          artifacts << result.artifact if result.is_a?(TimeSeriesFetchResult) && result.artifact
        rescue Exception => error # rubocop:disable Lint/RescueException -- observe every worker before propagating
          cleanup_error ||= error
        end
      end
      if time_series_writer
        begin
          time_series_writer.close_and_join
        rescue Exception => error # rubocop:disable Lint/RescueException -- observe writer without masking the active error
          cleanup_error ||= error
        end
      end
      # Workers may finish with spools after a launch or caller error stopped
      # event consumption. Reclaim those only after the writer has stopped.
      artifacts.each { |artifact| cleanup_time_series_artifact(artifact) }
      startup_failure_handled = recovery && recovery[:writer_failure]
      raise cleanup_error if active_error.nil? && cleanup_error && !startup_failure_handled
    end

    private

    def start_worker(&block)
      Thread.new(&block)
    end

    def prepare_time_series(result_kinds, completions)
      pending_purge_rows = if @persistence.respond_to?(:pending_time_series_purges)
        Array(@persistence.pending_time_series_purges)
      else
        []
      end
      pending_receipt_rows = @time_series_reader ? Array(@time_series_reader.pending_receipts) : []
      recovery_instance_ids = (pending_purge_rows.filter_map { |row| recovery_instance_id(row) } +
        pending_receipt_rows.filter_map { |receipt| recovery_instance_id(receipt) }).uniq
      required = result_kinds.value?(:time_series) || !pending_purge_rows.empty? || !pending_receipt_rows.empty?
      return [nil, { blocked_instances: [], errors: {} }] unless required

      unless @time_series_reader && @time_series_persistence_factory
        raise ConfigurationError, "time-series collection or recovery requires a reader and persistence factory"
      end

      writer = TimeSeriesWriter.new(
        time_series_persistence_factory: @time_series_persistence_factory,
        event_queue: completions
      ).start
      if (startup_error = writer.wait_until_ready)
        blocked_ids = (result_kinds.filter_map do |instance_id, result_kind|
          instance_id if result_kind == :time_series
        end + recovery_instance_ids).uniq.sort
        errors = blocked_ids.each_with_object({}) do |instance_id, blocked|
          blocked[instance_id] = startup_error
        end
        return [writer, { blocked_instances: errors.keys.sort.freeze, errors: errors.freeze,
                          writer_failure: startup_error }]
      end
      recovery = TimeSeriesReconciler.new(
        main_persistence: @persistence, time_series_reader: @time_series_reader, writer: writer
      ).run
      # Recovery consumes command-specific waiters. Its terminal events are
      # already observed and must not be confused with new source commands.
      completions.pop(true) until completions.empty?
      [writer, recovery.merge(writer_failure: nil)]
    rescue Exception # rubocop:disable Lint/RescueException -- startup owns the writer until it returns
      begin
        writer&.close_and_join
      rescue Exception # preserve the startup error
        nil
      end
      raise
    end

    def time_series_context_for(instance_id)
      @time_series_reader.context_for(instance_id: instance_id)
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

    def failure_result(result_kind:, **attributes)
      result_class = result_kind == :time_series ? TimeSeriesFetchResult : FetchResult
      result_class.failure(**attributes)
    end

    def typed_fetch_result?(result)
      result.is_a?(FetchResult) || result.is_a?(TimeSeriesFetchResult)
    end

    def typed_failure_result?(result)
      typed_fetch_result?(result) && result.failure?
    end

    def failure_metadata_for(result, error)
      return result.metadata if typed_failure_result?(result)

      error.respond_to?(:safe_metadata) ? error.safe_metadata : {}
    end

    def persist_time_series_result(instance:, result:, writer:, pending_writer_commands:)
      if result.failure?
        return record_time_series_failure(instance, result, result.error)
      end
      unless result.source_fetched
        return time_series_status(instance, result, status: :cached)
      end

      command_id = writer.submit_import(result.artifact)
      pending_writer_commands[command_id] = {
        phase: :import, instance_id: instance.id,
        import_key: result.artifact.import_key, result: result,
        import_command_id: command_id
      }
      nil
    end

    def handle_writer_event(event, pending_writer_commands:, instances:, time_series_writer:)
      command = pending_writer_commands.delete(event.command_id)
      raise ValidationError, "unknown time-series writer command" unless command
      unless event.phase == command.fetch(:phase) && event.instance_id == command.fetch(:instance_id) &&
             event.import_key == command.fetch(:import_key)
        raise ValidationError, "time-series writer event correlation mismatch"
      end

      instance = instances.fetch(command.fetch(:instance_id))
      result = command.fetch(:result)
      if event.phase == :acknowledgement
        metadata = merge_time_series_cleanup_metadata(
          result.metadata, time_series_writer, command.fetch(:import_command_id)
        )
        metadata = metadata.merge(receipt_acknowledgement_pending: true) if event.result == :failure
        return time_series_status(instance, result, status: :success, metadata: metadata)
      end
      if event.result == :failure
        return record_time_series_failure(
          instance, result, event.error,
          metadata: time_series_failure_metadata(
            result, event.error, time_series_writer, command.fetch(:import_command_id)
          )
        )
      end

      begin
        @persistence.acknowledge_time_series_import(event.receipt)
      rescue StandardError => error
        return record_time_series_failure(
          instance, result, error,
          metadata: time_series_failure_metadata(
            result, error, time_series_writer, command.fetch(:import_command_id)
          )
        )
      end

      begin
        command_id = time_series_writer.submit_acknowledgement(event.receipt)
        pending_writer_commands[command_id] = command.merge(phase: :acknowledgement)
      rescue StandardError
        # Main success is durable; an advisory marker failure must never add
        # a contradictory failed fetch-history row.
        return time_series_status(
          instance, result, status: :success,
          metadata: merge_time_series_cleanup_metadata(
            result.metadata, time_series_writer, command.fetch(:import_command_id)
          ).merge(receipt_acknowledgement_pending: true)
        )
      end
      nil
    end

    def time_series_failure_metadata(result, error, writer, import_command_id, cleanup_failures: [])
      metadata = if typed_failure_result?(result)
        result.metadata
      elsif error.respond_to?(:safe_metadata)
        error.safe_metadata
      else
        {}
      end
      merge_time_series_cleanup_metadata(
        metadata, writer, import_command_id, error: error, cleanup_failures: cleanup_failures
      )
    end

    def merge_time_series_cleanup_metadata(metadata, writer, import_command_id, error: nil, cleanup_failures: [])
      failures = []
      if writer.respond_to?(:cleanup_failures)
        failures.concat(Array(writer.cleanup_failures.fetch(import_command_id, nil)))
      end
      failures.concat(Array(error.cleanup_failures)) if error&.respond_to?(:cleanup_failures)
      failures.concat(Array(cleanup_failures))
      return metadata if failures.empty?

      bounded_failures = bounded_cleanup_failures(failures)
      return metadata if bounded_failures.empty?

      (metadata || {}).merge(cleanup_failures: bounded_failures)
    end

    def record_time_series_failure(instance, result, error, metadata: nil)
      # Main persistence owns item-shaped fetch history and its insert path
      # reads result.items.length. Keep the typed result at the orchestration
      # boundary, but normalize failures before crossing into that API.
      typed_result = typed_fetch_result?(result)
      typed_failure = typed_failure_result?(result)
      started_at = typed_result ? result.started_at : @clock.call
      failure = FetchResult.failure(
        instance_id: instance.id, error: error, started_at: started_at,
        finished_at: typed_failure ? result.finished_at : [@clock.call, started_at].max,
        metadata: metadata || failure_metadata_for(result, error)
      )
      @persistence.record_fetch_failure(failure)
      status = InstanceRunStatus.new(
        instance_id: instance.id, status: :failure, source_fetched: false,
        item_count: 0, error: error, metadata: failure.metadata
      )
      progress_puts(progress_message(instance, status, result))
      status
    end

    def time_series_status(instance, result, status:, metadata: result.metadata)
      run_status = InstanceRunStatus.new(
        instance_id: instance.id, status: status, source_fetched: result.source_fetched,
        item_count: 0, series_count: result.series_count,
        observation_count: result.observation_count, metadata: metadata
      )
      progress_puts(progress_message(instance, run_status, result))
      run_status
    end

    def persist_result(instance:, result:, result_kind:, planned_fetch_mode:, retention_ttl_minutes:, context:, hard_expired_items:,
                       time_series_writer:, pending_writer_commands:)
      expected_class = result_kind == :time_series ? TimeSeriesFetchResult : FetchResult
      unless result.is_a?(expected_class)
        raise ValidationError, "adapter returned the wrong result kind for configured instance #{instance.id.inspect}"
      end
      unless result.instance_id == instance.id
        raise ValidationError,
              "adapter result instance_id #{result.instance_id.inspect} does not match configured instance #{instance.id.inspect}"
      end

      if !result.failure? && planned_fetch_mode &&
         result.source_fetched != (planned_fetch_mode == :remote)
        raise ValidationError,
              "successful result source_fetched does not match planned #{planned_fetch_mode} fetch mode"
      end

      if result_kind == :time_series
        return persist_time_series_result(
          instance: instance, result: result, writer: time_series_writer,
          pending_writer_commands: pending_writer_commands
        )
      end

      if result.failure?
        failure = FetchResult.failure(
          instance_id: instance.id,
          error: result.error,
          started_at: result.started_at,
          finished_at: result.finished_at,
          metadata: expiry_metadata(result.metadata, hard_expired_items)
        )
        @persistence.record_fetch_failure(failure)
        run_status = InstanceRunStatus.new(
          instance_id: instance.id,
          status: :failure,
          source_fetched: false,
          item_count: 0,
          error: result.error,
          metadata: expiry_metadata(result.metadata, hard_expired_items)
        )
        progress_puts(progress_message(instance, run_status, result))
        return run_status
      end

      if result.source_fetched
        pruned_count = @persistence.write_fetch_result(
          result,
          retention_ttl_minutes: retention_ttl_minutes
        )
        pruned_count ||= 0
        existing_ids = context.fetch(:item_ids, Set.new)
        metadata = (result.metadata || {}).merge(
          items_found: result.items.length,
          new_items: result.items.count { |item| !existing_ids.include?(item.canonical_id) },
          cached_items: result.items.count { |item| existing_ids.include?(item.canonical_id) },
          items_pruned: pruned_count,
          items_expired: hard_expired_items
        )
      else
        metadata = (result.metadata || {}).merge(items_expired: hard_expired_items)
      end
      status = result.source_fetched ? :success : :cached
      run_status = InstanceRunStatus.new(instance_id: instance.id, status: status, source_fetched: result.source_fetched, item_count: result.items.length, metadata: metadata)
      progress_puts(progress_message(instance, run_status, result))
      run_status
    rescue StandardError => error
      cleanup_failures = if result.is_a?(TimeSeriesFetchResult) && result.artifact
        cleanup_time_series_artifact(result.artifact)
      else
        []
      end
      if result_kind == :time_series
        return record_time_series_failure(
          instance, result, error,
          metadata: time_series_failure_metadata(
            result, error, time_series_writer, nil, cleanup_failures: cleanup_failures
          )
        )
      end

      failure = failure_result(
        result_kind: result_kind,
        instance_id: instance.id,
        error: error,
        started_at: typed_fetch_result?(result) ? result.started_at : @clock.call,
        finished_at: typed_failure_result?(result) ? result.finished_at : @clock.call,
        metadata: merge_time_series_cleanup_metadata(
          expiry_metadata(failure_metadata_for(result, error), hard_expired_items),
          nil, nil, error: error, cleanup_failures: cleanup_failures
        )
      )
      @persistence.record_fetch_failure(failure)
      run_status = InstanceRunStatus.new(
        instance_id: instance.id, status: :failure,
        source_fetched: typed_fetch_result?(result) && result.source_fetched,
        item_count: 0, error: error, metadata: failure.metadata
      )
      progress_puts(progress_message(instance, run_status, result))
      run_status
    end

    def progress_puts(message)
      @progress&.puts(message)
    end

    def cleanup_time_series_artifact(artifact)
      failures = []
      [artifact.path, "#{artifact.path}-journal", "#{artifact.path}-wal", "#{artifact.path}-shm"].each do |path|
        FileUtils.rm_f(path)
      rescue Exception => error # rubocop:disable Lint/RescueException -- cleanup must not mask the primary result error
        failures.concat(cleanup_failure_details(error, phase: "artifact_cleanup"))
      end
      bounded_cleanup_failures(failures)
    end

    def cleanup_failure_details(error, phase:)
      [{
        phase: cleanup_failure_field(phase),
        error_class: cleanup_failure_field(error.class.name.to_s)
      }.freeze]
    end

    def bounded_cleanup_failures(failures)
      Array(failures).first(CLEANUP_FAILURE_LIMIT).filter_map do |failure|
        next unless failure.respond_to?(:key?)

        phase = cleanup_failure_field(failure[:phase] || failure["phase"])
        error_class = cleanup_failure_field(failure[:error_class] || failure["error_class"])
        next unless phase && error_class

        { phase: phase, error_class: error_class }.freeze
      end.freeze
    end

    def cleanup_failure_field(value)
      return unless value.is_a?(String)

      field = value.dup.force_encoding(Encoding::UTF_8)
      return unless field.valid_encoding?

      bounded = +""
      field.each_char do |character|
        candidate = bounded + character
        break if candidate.bytesize > CLEANUP_FAILURE_FIELD_BYTES

        bounded << character
      end
      bounded.freeze
    end

    def expiry_metadata(metadata, count)
      return metadata if count.zero?

      (metadata || {}).merge(items_expired: count)
    end

    def fetch_start_message(plan)
      instance = plan.instance
      source = @registry.display_name_for(instance)
      source = "#{source} messages" if instance.adapter == "gmail"
      source = if instance.adapter == "rss"
        url = instance.options.fetch(:url, nil)
        url ? "#{source} from #{url}" : source
      else
        source
      end
      "#{instance.name}: Fetching #{source}..."
    end

    def progress_message(instance, status, result)
      if status.status == :failure
        return "#{instance.name}: Error: #{single_line(status.error)}"
      end
      if result.is_a?(TimeSeriesFetchResult)
        action = status.status == :cached ? "Using cached data" : "Fetched"
        return "#{instance.name}: #{action} (#{status.series_count} series, #{status.observation_count} observations)."
      end
      return "#{instance.name}: Using cached data (#{status.item_count} items)." if status.status == :cached

      noun = @registry.item_noun_for(instance)
      metadata = status.metadata
      "#{instance.name}: #{metadata.fetch(:items_found, result.items.length)} #{noun} found, " \
        "#{metadata.fetch(:new_items, 0)} new, #{metadata.fetch(:cached_items, 0)} already cached, " \
        "#{metadata.fetch(:items_pruned, 0)} expired #{noun} purged."
    end

    def single_line(error)
      "#{error.class}: #{error.message}".gsub(/\s+/, " ").strip
    end

    def dependency_failure_result(instance, resolutions, result_kind: :items)
      first = resolutions.first
      metadata = {
        tool: first.dependency.executable,
        category: first.error.fetch(:category),
        tools: resolutions.map { |resolution| resolution.dependency.executable }.uniq
      }
      failure_result(
        result_kind: result_kind,
        instance_id: instance.id,
        error: SourceError.new(dependency_error_message(resolutions)),
        started_at: @clock.call,
        finished_at: @clock.call,
        metadata: metadata
      )
    end

    def dependency_error_message(resolutions)
      resolutions.map do |resolution|
        dependency = resolution.dependency
        hints = [
          dependency.install_hint && "install: #{dependency.install_hint}",
          dependency.auth_hint && "auth: #{dependency.auth_hint}"
        ].compact
        detail = hints.empty? ? "" : " (#{hints.join('; ')})"
        "#{dependency.executable} unavailable#{detail}"
      end.join("; ")
    end

    def dependency_guidance(resolution)
      dependency = resolution.dependency
      {
        tool: dependency.executable,
        category: resolution.error.fetch(:category),
        purpose: dependency.purpose,
        install_hint: dependency.install_hint,
        auth_hint: dependency.auth_hint
      }.compact
    end
  end
end
