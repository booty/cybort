module Cybort
  class InstanceRunStatus
    attr_reader :instance_id, :status, :source_fetched, :item_count, :error

    def initialize(instance_id:, status:, source_fetched:, item_count:, error: nil)
      @instance_id = instance_id
      @status = status
      @source_fetched = source_fetched
      @item_count = item_count
      @error = error
    end

    def to_h
      {
        id: instance_id,
        status: status,
        source_fetched: source_fetched,
        item_count: item_count,
        error: error && "#{error.class}: #{error.message}"
      }
    end
  end

  class RunResult
    attr_reader :instances, :overall_status

    def initialize(instances)
      @instances = instances
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
    def initialize(configuration:, persistence:, registry:, http_client:, clock: -> { Time.now.utc })
      @configuration = configuration
      @persistence = persistence
      @registry = registry
      @http_client = http_client
      @clock = clock
    end

    def run(force_fetch: false)
      instances = @configuration.instances
      @registry.validate!(instances)
      instances.each_value { |instance| @persistence.register_instance(instance) }
      contexts = instances.transform_values { |instance| @persistence.context_for(instance_id: instance.id) }

      threads = instances.values.map do |instance|
        Thread.new do
          adapter = @registry.build(
            instance: instance,
            context: contexts.fetch(instance.id),
            http_client: @http_client,
            clock: @clock
          )
          adapter.fetch(force_fetch: force_fetch)
        rescue StandardError => error
          FetchResult.failure(
            instance_id: instance.id,
            error: error,
            started_at: @clock.call,
            finished_at: @clock.call
          )
        end
      end

      results = threads.map(&:value)
      statuses = results.map { |result| persist_result(result) }
      RunResult.new(statuses)
    end

    private

    def persist_result(result)
      if result.failure?
        @persistence.record_fetch_failure(result)
        return InstanceRunStatus.new(instance_id: result.instance_id, status: :failure, source_fetched: false, item_count: 0, error: result.error)
      end

      @persistence.write_fetch_result(result) if result.source_fetched
      status = result.source_fetched ? :success : :cached
      InstanceRunStatus.new(instance_id: result.instance_id, status: status, source_fetched: result.source_fetched, item_count: result.items.length)
    rescue StandardError => error
      failure = FetchResult.failure(
        instance_id: result.instance_id,
        error: error,
        started_at: result.started_at,
        finished_at: @clock.call
      )
      @persistence.record_fetch_failure(failure)
      InstanceRunStatus.new(instance_id: result.instance_id, status: :failure, source_fetched: result.source_fetched, item_count: 0, error: error)
    end
  end
end

