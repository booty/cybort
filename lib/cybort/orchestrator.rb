module Cybort
  class InstanceRunStatus
    attr_reader :instance_id, :status, :source_fetched, :item_count, :error, :metadata

    def initialize(instance_id:, status:, source_fetched:, item_count:, error: nil, metadata: {})
      @instance_id = instance_id
      @status = status
      @source_fetched = source_fetched
      @item_count = item_count
      @error = error
      @metadata = metadata || {}
    end

    def to_h
      {
        id: instance_id,
        status: status,
        source_fetched: source_fetched,
        item_count: item_count,
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
    def initialize(configuration:, persistence:, registry:, http_client:, clock: -> { Time.now.utc },
                   command_runner: nil, dependency_checker: nil,
                   monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                   progress: nil)
      @configuration = configuration
      @persistence = persistence
      @registry = registry
      @http_client = http_client
      @clock = clock
      @command_runner = command_runner || CommandRunner.new(monotonic_clock: monotonic_clock)
      @dependency_checker = dependency_checker || DependencyChecker.new(command_runner: @command_runner)
      @monotonic_clock = monotonic_clock
      @progress = progress
    end

    def run(force_fetch: false)
      instances = @configuration.instances
      @registry.validate_configuration!(instances)
      retention_ttl_minutes_by_instance_id = instances.values.to_h do |instance|
        [instance.id, instance.retention_ttl_minutes]
      end.freeze
      contexts = instances.transform_values { |instance| @persistence.context_for(instance_id: instance.id) }

      planned_at = @clock.call
      plans = instances.values.to_h do |instance|
        plan = @registry.plan(
          instance: instance,
          context: contexts.fetch(instance.id),
          force_fetch: force_fetch,
          planned_at: planned_at
        )
        [instance.id, { plan: plan }]
      end

      dependency_groups = Hash.new { |groups, executable| groups[executable] = [] }
      plans.each_value do |entry|
        plan = entry.fetch(:plan)
        next unless plan.fetch_mode == :remote

        @registry.dependencies_for(plan.instance).each do |dependency|
          dependency_groups[dependency.executable] << dependency
        end
      end
      resolution_cache = dependency_groups.transform_values do |dependencies|
        canonical = dependencies.find(&:version_requirement) || dependencies.first
        @dependency_checker.resolve(canonical)
      end
      results = {}
      unavailable = {}
      plans.each_value do |entry|
        plan = entry.fetch(:plan)
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

        results[instance.id] = dependency_failure_result(instance, dependency_failures)
        dependency_failures.each do |failure|
          guidance = dependency_guidance(failure)
          key = guidance.values_at(:tool, :category, :purpose, :install_hint, :auth_hint)
          unavailable[key] ||= guidance.merge(instances: [])
          unavailable[key][:instances] << instance.id
        end
      end

      plans.each_value do |entry|
        next if results.key?(entry.fetch(:plan).instance.id)

        plan = entry.fetch(:plan)
        entry[:adapter] = @registry.build(
          instance: plan.instance,
          context: plan.context,
          http_client: @http_client,
          clock: @clock,
          command_runner: @command_runner,
          dependency_resolutions: plan.resolutions,
          monotonic_clock: @monotonic_clock
        )
      end

      instances.each_value { |instance| @persistence.register_instance(instance) }
      threads = plans.each_with_object({}) do |(instance_id, entry), running|
        next if results.key?(instance_id)

        plan = entry.fetch(:plan)
        adapter = entry.fetch(:adapter)
        progress_puts(fetch_start_message(plan)) if @progress && plan.fetch_mode == :remote
        running[instance_id] = Thread.new do
          adapter.fetch(force_fetch: force_fetch, fetch_mode: plan.fetch_mode, planned_at: plan.planned_at)
        rescue StandardError => error
          FetchResult.failure(
            instance_id: instance_id,
            error: error,
            started_at: @clock.call,
            finished_at: @clock.call,
            metadata: error.respond_to?(:safe_metadata) ? error.safe_metadata : {}
          )
        end
      end
      threads.each { |instance_id, thread| results[instance_id] = thread.value }

      statuses = instances.values.map do |instance|
        persist_result(
          instance: instance,
          result: results.fetch(instance.id),
          retention_ttl_minutes: retention_ttl_minutes_by_instance_id.fetch(instance.id),
          context: contexts.fetch(instance.id)
        )
      end
      guidance = unavailable.values.map { |value| value.merge(instances: value.fetch(:instances).sort) }
      RunResult.new(statuses, unavailable_dependencies: guidance.sort_by { |value| [value.fetch(:tool), value.fetch(:instances)] })
    end

    private

    def persist_result(instance:, result:, retention_ttl_minutes:, context:)
      unless result.instance_id == instance.id
        raise ValidationError,
              "adapter result instance_id #{result.instance_id.inspect} does not match configured instance #{instance.id.inspect}"
      end

      if result.failure?
        failure = FetchResult.failure(
          instance_id: instance.id,
          error: result.error,
          started_at: result.started_at,
          finished_at: result.finished_at,
          metadata: result.metadata
        )
        @persistence.record_fetch_failure(failure)
        run_status = InstanceRunStatus.new(
          instance_id: instance.id,
          status: :failure,
          source_fetched: false,
          item_count: 0,
          error: result.error,
          metadata: result.metadata
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
        existing_ids = context.fetch(:items, []).map(&:canonical_id)
        metadata = (result.metadata || {}).merge(
          items_found: result.items.length,
          new_items: result.items.count { |item| !existing_ids.include?(item.canonical_id) },
          cached_items: result.items.count { |item| existing_ids.include?(item.canonical_id) },
          items_pruned: pruned_count
        )
      else
        metadata = result.metadata
      end
      status = result.source_fetched ? :success : :cached
      run_status = InstanceRunStatus.new(instance_id: instance.id, status: status, source_fetched: result.source_fetched, item_count: result.items.length, metadata: metadata)
      progress_puts(progress_message(instance, run_status, result))
      run_status
    rescue StandardError => error
      failure = FetchResult.failure(
        instance_id: instance.id,
        error: error,
        started_at: result.started_at,
        finished_at: @clock.call,
        metadata: error.respond_to?(:safe_metadata) ? error.safe_metadata : {}
      )
      @persistence.record_fetch_failure(failure)
      run_status = InstanceRunStatus.new(instance_id: instance.id, status: :failure, source_fetched: result.source_fetched, item_count: 0, error: error, metadata: failure.metadata)
      progress_puts(progress_message(instance, run_status, result))
      run_status
    end

    def progress_puts(message)
      @progress&.puts(message)
    end

    def fetch_start_message(plan)
      instance = plan.instance
      source = if instance.adapter == "rss"
        url = instance.options.fetch(:url, nil)
        url ? "RSS from #{url}" : "RSS"
      else
        { "github" => "GitHub", "gmail" => "Gmail", "reddit" => "Reddit" }.fetch(instance.adapter, instance.adapter)
      end
      "#{instance.name}: Fetching #{source}..."
    end

    def progress_message(instance, status, result)
      return "#{instance.name}: Using cached data (#{status.item_count} items)." if status.status == :cached
      if status.status == :failure
        return "#{instance.name}: Error: #{single_line(status.error)}"
      end

      noun = { "rss" => "articles", "github" => "notifications", "gmail" => "messages", "reddit" => "items" }.fetch(instance.adapter, "items")
      metadata = status.metadata
      "#{instance.name}: #{metadata.fetch(:items_found, result.items.length)} #{noun} found, " \
        "#{metadata.fetch(:new_items, 0)} new, #{metadata.fetch(:cached_items, 0)} already cached, " \
        "#{metadata.fetch(:items_pruned, 0)} expired #{noun} purged."
    end

    def single_line(error)
      "#{error.class}: #{error.message}".gsub(/\s+/, " ").strip
    end

    def dependency_failure_result(instance, resolutions)
      first = resolutions.first
      metadata = {
        tool: first.dependency.executable,
        category: first.error.fetch(:category),
        tools: resolutions.map { |resolution| resolution.dependency.executable }.uniq
      }
      FetchResult.failure(
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
