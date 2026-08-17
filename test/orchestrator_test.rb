require "test_helper"

class OrchestratorTest < Minitest::Test
  class GateAdapter
    def initialize(instance:, started:, release:, **)
      @instance = instance
      @started = started
      @release = release
    end

    def fetch(force_fetch:)
      @started << @instance.id
      @release.pop
      Cybort::FetchResult.success(
        instance_id: @instance.id,
        items: [Cybort::Item.new(instance_id: @instance.id, canonical_id: "item-#{@instance.id}", fetched_at: Time.utc(2026, 8, 16, 12), title: @instance.name)],
        sync_state: { fetched: true },
        started_at: Time.utc(2026, 8, 16, 12),
        finished_at: Time.utc(2026, 8, 16, 12, 1),
        source_fetched: true
      )
    end
  end

  class PersistenceSpy
    attr_reader :writes, :failures

    def initialize
      @writes = []
      @failures = []
    end

    def register_instance(_instance); end

    def context_for(instance_id:)
      { items: [], last_successful_fetch: nil, sync_state: nil }
    end

    def write_fetch_result(result)
      @writes << result
    end

    def record_fetch_failure(result)
      @failures << result
    end
  end

  def instance(id)
    Cybort::Configuration::Instance.new(
      id: id,
      name: id.capitalize,
      adapter: "gate",
      ttl_minutes: 30,
      num_items_to_fetch: 5,
      options: {}
    )
  end

  def test_rejects_unknown_adapter_before_starting_threads
    configuration = Struct.new(:instances).new({ "unknown" => instance("unknown") })
    registry = Cybort::AdapterRegistry.new
    persistence = PersistenceSpy.new
    orchestrator = Cybort::Orchestrator.new(configuration: configuration, persistence: persistence, registry: registry, http_client: nil)

    assert_raises(Cybort::ConfigurationError) { orchestrator.run }
  end

  def test_fetches_adapter_instances_concurrently_then_persists_sequentially
    started = Queue.new
    release = Queue.new
    registry = Cybort::AdapterRegistry.new
    registry.register("gate", ->(**kwargs) { GateAdapter.new(**kwargs, started: started, release: release) })
    configuration = Struct.new(:instances).new({ "one" => instance("one"), "two" => instance("two") })
    persistence = PersistenceSpy.new
    orchestrator = Cybort::Orchestrator.new(configuration: configuration, persistence: persistence, registry: registry, http_client: nil)

    run_thread = Thread.new { orchestrator.run }
    assert_equal %w[one two], [started.pop, started.pop].sort
    assert_empty persistence.writes

    release << true
    release << true
    result = run_thread.value

    assert_equal :success, result.overall_status
    assert_equal %w[one two], persistence.writes.map(&:instance_id).sort
    assert_empty persistence.failures
  end
end
