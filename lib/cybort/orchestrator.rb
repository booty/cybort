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
                   monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @configuration = configuration
      @persistence = persistence
      @registry = registry
      @http_client = http_client
      @clock = clock
      @command_runner = command_runner || CommandRunner.new(monotonic_clock: monotonic_clock)
      @dependency_checker = dependency_checker || DependencyChecker.new(command_runner: @command_runner)
      @monotonic_clock = monotonic_clock
    end

    def run(force_fetch: false)
      instances = @configuration.instances
      @registry.validate!(instances)
      @registry.validate_configuration!(instances)
      contexts = instances.transform_values { |instance| @persistence.context_for(instance_id: instance.id) }

      planned_at = @clock.call
      plans = instances.values.to_h do |instance|
        adapter = @registry.build(
          instance: instance,
          context: contexts.fetch(instance.id),
          http_client: @http_client,
          clock: @clock,
          command_runner: @command_runner,
          dependency_resolutions: {},
          monotonic_clock: @monotonic_clock
        )
        plan = if adapter.respond_to?(:plan)
          adapter.plan(force_fetch: force_fetch, planned_at: planned_at)
        else
          AdapterPlan.new(
            instance: instance,
            context: contexts.fetch(instance.id),
            fetch_mode: :remote,
            planned_at: planned_at,
            dependency_requirements: [],
            resolutions: {}
          )
        end
        [instance.id, { adapter: adapter, plan: plan }]
      end

      resolution_cache = {}
      results = {}
      unavailable = {}
      plans.each_value do |entry|
        plan = entry.fetch(:plan)
        instance = plan.instance
        dependencies = plan.fetch_mode == :remote ? @registry.dependencies_for(instance) : []
        resolutions = {}
        dependency_failure = nil
        dependencies.each do |dependency|
          resolution = if resolution_cache.key?(dependency.executable)
            @dependency_checker.validate_version!(dependency, resolution_cache.fetch(dependency.executable))
          else
            @dependency_checker.resolve(dependency)
          end
          resolution_cache[dependency.executable] ||= resolution
          resolutions[dependency.executable] = resolution
          next if resolution.available?

          dependency_failure = resolution
          break
        end

        entry[:plan] = plan.with(dependency_requirements: dependencies, resolutions: resolutions)
        entry[:adapter].dependency_resolutions = resolutions if entry[:adapter].respond_to?(:dependency_resolutions=)
        next unless dependency_failure

        results[instance.id] = dependency_failure_result(instance, dependency_failure)
        guidance = dependency_guidance(dependency_failure)
        key = guidance.values_at(:tool, :category, :purpose, :install_hint, :auth_hint)
        unavailable[key] ||= guidance.merge(instances: [])
        unavailable[key][:instances] << instance.id
      end

      instances.each_value { |instance| @persistence.register_instance(instance) }
      threads = plans.each_with_object({}) do |(instance_id, entry), running|
        next if results.key?(instance_id)

        plan = entry.fetch(:plan)
        adapter = entry.fetch(:adapter)
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

      statuses = instances.keys.map { |instance_id| persist_result(results.fetch(instance_id)) }
      guidance = unavailable.values.map { |value| value.merge(instances: value.fetch(:instances).sort) }
      RunResult.new(statuses, unavailable_dependencies: guidance.sort_by { |value| [value.fetch(:tool), value.fetch(:instances)] })
    end

    private

    def persist_result(result)
      if result.failure?
        @persistence.record_fetch_failure(result)
        return InstanceRunStatus.new(instance_id: result.instance_id, status: :failure, source_fetched: false, item_count: 0, error: result.error, metadata: result.metadata)
      end

      @persistence.write_fetch_result(result) if result.source_fetched
      status = result.source_fetched ? :success : :cached
      InstanceRunStatus.new(instance_id: result.instance_id, status: status, source_fetched: result.source_fetched, item_count: result.items.length, metadata: result.metadata)
    rescue StandardError => error
      failure = FetchResult.failure(
        instance_id: result.instance_id,
        error: error,
        started_at: result.started_at,
        finished_at: @clock.call,
        metadata: error.respond_to?(:safe_metadata) ? error.safe_metadata : {}
      )
      @persistence.record_fetch_failure(failure)
      InstanceRunStatus.new(instance_id: result.instance_id, status: :failure, source_fetched: result.source_fetched, item_count: 0, error: error, metadata: failure.metadata)
    end

    def dependency_failure_result(instance, resolution)
      metadata = {
        tool: resolution.dependency.executable,
        category: resolution.error.fetch(:category)
      }
      FetchResult.failure(
        instance_id: instance.id,
        error: SourceError.new("dependency unavailable"),
        started_at: @clock.call,
        finished_at: @clock.call,
        metadata: metadata
      )
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
