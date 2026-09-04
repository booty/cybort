require "test_helper"

class OrchestratorTest < Minitest::Test
  class GateAdapter
    def initialize(instance:, started:, release:, **)
      @instance = instance
      @started = started
      @release = release
    end

    def fetch(force_fetch: false, fetch_mode: nil, planned_at: nil)
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
    attr_reader :writes, :failures, :registered

    def initialize
      @writes = []
      @failures = []
      @registered = []
    end

    def register_instance(instance)
      @registered << instance
    end

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

  class PersistenceSpyWithContexts < PersistenceSpy
    def initialize(contexts)
      super()
      @contexts = contexts
    end

    def context_for(instance_id:)
      @contexts.fetch(instance_id)
    end
  end

  class ForceRecordingAdapter
    def initialize(instance:, calls:, **)
      @instance = instance
      @calls = calls
    end

    def fetch(force_fetch: false, fetch_mode: nil, planned_at: nil)
      @calls << force_fetch
      Cybort::FetchResult.success(
        instance_id: @instance.id,
        items: [],
        sync_state: {},
        started_at: Time.utc(2026, 8, 16, 12),
        finished_at: Time.utc(2026, 8, 16, 12, 1),
        source_fetched: true
      )
    end
  end

  class PlanningAdapter < Cybort::Adapters::Base
    attr_reader :modes

    def initialize(modes:, **kwargs)
      @modes = modes
      super(**kwargs)
    end

    def fetch(force_fetch: false, fetch_mode: nil, planned_at: nil)
      @modes << [instance.id, fetch_mode]
      if fetch_mode == :cached
        Cybort::FetchResult.success(
          instance_id: instance.id, items: context.fetch(:items, []), sync_state: context[:sync_state],
          started_at: clock.call, finished_at: clock.call, source_fetched: false
        )
      else
        Cybort::FetchResult.success(
          instance_id: instance.id, items: [], sync_state: {},
          started_at: clock.call, finished_at: clock.call, source_fetched: true
        )
      end
    end
  end

  class CheckerSpy
    attr_reader :calls

    def initialize(resolution)
      @resolution = resolution
      @calls = []
    end

    def resolve(dependency, env: ENV.to_h)
      @calls << dependency.executable
      @resolution
    end

    def validate_version!(dependency, resolution)
      resolution
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

  def test_force_fetch_is_passed_to_every_adapter
    calls = []
    registry = Cybort::AdapterRegistry.new
    registry.register("force", ->(**kwargs) { ForceRecordingAdapter.new(**kwargs, calls: calls) })
    configuration = Struct.new(:instances).new({ "one" => instance("one").tap { |value| value.adapter = "force" } })
    persistence = PersistenceSpy.new
    orchestrator = Cybort::Orchestrator.new(configuration: configuration, persistence: persistence, registry: registry, http_client: nil)

    orchestrator.run(force_fetch: true)

    assert_equal [true], calls
  end

  def test_configuration_validation_happens_before_persistence_registration
    registry = Cybort::AdapterRegistry.new
    registry.register("invalid", ->(**_kwargs) { Object.new }, validate_configuration: ->(_instance) {
      raise Cybort::ConfigurationError, "bad source"
    })
    configured = instance("invalid").tap { |value| value.adapter = "invalid" }
    configuration = Struct.new(:instances).new({ "invalid" => configured })
    persistence = PersistenceSpy.new
    orchestrator = Cybort::Orchestrator.new(configuration: configuration, persistence: persistence, registry: registry, http_client: nil)

    assert_raises(Cybort::ConfigurationError) { orchestrator.run }
    assert_empty persistence.registered
  end

  def test_fresh_cache_skips_dependency_preflight
    dependency = Cybort::Dependency.new(executable: "gws", purpose: "gmail")
    registry = Cybort::AdapterRegistry.new
    modes = []
    registry.register("gmail", ->(**kwargs) { PlanningAdapter.new(**kwargs, modes: modes) }, dependencies: [dependency], validate_configuration: ->(_instance) {})
    configured = instance("mail").tap { |value| value.adapter = "gmail" }
    configuration = Struct.new(:instances).new({ "mail" => configured })
    persistence = PersistenceSpyWithContexts.new(
      "mail" => { items: [], last_successful_fetch: Time.utc(2026, 8, 16, 12), sync_state: {} }
    )
    checker = CheckerSpy.new(unavailable_resolution(dependency))
    orchestrator = Cybort::Orchestrator.new(
      configuration: configuration, persistence: persistence, registry: registry, http_client: nil,
      clock: -> { Time.utc(2026, 8, 16, 12, 1) }, dependency_checker: checker
    )

    result = orchestrator.run

    assert_equal :cached, result.instances.first.status
    assert_empty checker.calls
    assert_equal [["mail", :cached]], modes
  end

  def test_stale_missing_dependency_fails_only_that_instance_and_groups_guidance
    dependency = Cybort::Dependency.new(
      executable: "gws", purpose: "gmail", install_hint: "brew install googleworkspace-cli"
    )
    registry = Cybort::AdapterRegistry.new
    modes = []
    registry.register("gmail", ->(**kwargs) { PlanningAdapter.new(**kwargs, modes: modes) }, dependencies: [dependency], validate_configuration: ->(_instance) {})
    registry.register("rss", ->(**kwargs) { PlanningAdapter.new(**kwargs, modes: modes) }, validate_configuration: ->(_instance) {})
    mail = instance("mail").tap { |value| value.adapter = "gmail" }
    feed = instance("feed").tap { |value| value.adapter = "rss" }
    configuration = Struct.new(:instances).new({ "mail" => mail, "feed" => feed })
    persistence = PersistenceSpyWithContexts.new("mail" => empty_context, "feed" => empty_context)
    checker = CheckerSpy.new(unavailable_resolution(dependency))
    orchestrator = Cybort::Orchestrator.new(
      configuration: configuration, persistence: persistence, registry: registry, http_client: nil,
      dependency_checker: checker
    )

    result = orchestrator.run

    assert_equal %i[failure success], result.instances.map(&:status)
    assert_equal ["gws"], checker.calls
    assert_equal ["mail"], result.unavailable_dependencies.first.fetch(:instances)
    assert_equal ["feed"], persistence.writes.map(&:instance_id)
  end

  def test_two_remote_instances_resolve_one_unique_executable
    dependency = Cybort::Dependency.new(executable: "gws", purpose: "gmail")
    registry = Cybort::AdapterRegistry.new
    modes = []
    registry.register("gmail", ->(**kwargs) { PlanningAdapter.new(**kwargs, modes: modes) }, dependencies: [dependency], validate_configuration: ->(_instance) {})
    first = instance("one").tap { |value| value.adapter = "gmail" }
    second = instance("two").tap { |value| value.adapter = "gmail" }
    configuration = Struct.new(:instances).new({ "one" => first, "two" => second })
    persistence = PersistenceSpyWithContexts.new("one" => empty_context, "two" => empty_context)
    checker = CheckerSpy.new(unavailable_resolution(dependency))
    orchestrator = Cybort::Orchestrator.new(configuration: configuration, persistence: persistence, registry: registry, http_client: nil, dependency_checker: checker)

    result = orchestrator.run

    assert_equal ["gws"], checker.calls
    assert_equal %w[one two], result.unavailable_dependencies.first.fetch(:instances)
  end

  def test_resolves_all_dependencies_for_an_instance_before_reporting_failures
    first_dependency = Cybort::Dependency.new(executable: "gws", purpose: "gmail")
    second_dependency = Cybort::Dependency.new(executable: "jq", purpose: "json")
    registry = Cybort::AdapterRegistry.new
    factory_calls = 0
    registry.register(
      "multi",
      ->(**kwargs) { factory_calls += 1; PlanningAdapter.new(**kwargs, modes: []) },
      dependencies: [first_dependency, second_dependency],
      validate_configuration: ->(_instance) {}
    )
    configured = instance("multi").tap { |value| value.adapter = "multi" }
    configuration = Struct.new(:instances).new({ "multi" => configured })
    persistence = PersistenceSpyWithContexts.new("multi" => empty_context)
    checker = Class.new do
      attr_reader :calls

      define_method(:initialize) { |resolutions| @resolutions = resolutions; @calls = [] }
      define_method(:resolve) do |dependency, env: ENV.to_h|
        @calls << dependency.executable
        @resolutions.fetch(dependency.executable)
      end
      define_method(:validate_version!) { |_dependency, resolution| resolution }
    end.new(
      "gws" => unavailable_resolution(first_dependency),
      "jq" => unavailable_resolution(second_dependency)
    )
    orchestrator = Cybort::Orchestrator.new(configuration: configuration, persistence: persistence, registry: registry, http_client: nil, dependency_checker: checker)

    result = orchestrator.run

    assert_equal %w[gws jq], checker.calls
    assert_equal %w[gws jq], result.unavailable_dependencies.map { |value| value.fetch(:tool) }
    assert_equal 0, factory_calls
  end

  def test_unavailable_dependency_does_not_construct_runtime_factory
    dependency = Cybort::Dependency.new(executable: "gws", purpose: "gmail")
    registry = Cybort::AdapterRegistry.new
    factory_calls = 0
    registry.register(
      "gmail",
      ->(**_kwargs) { factory_calls += 1; raise "runtime factory must not run" },
      dependencies: [dependency],
      validate_configuration: ->(_instance) {}
    )
    configured = instance("mail").tap { |value| value.adapter = "gmail" }
    configuration = Struct.new(:instances).new({ "mail" => configured })
    persistence = PersistenceSpyWithContexts.new("mail" => empty_context)
    checker = CheckerSpy.new(unavailable_resolution(dependency))
    orchestrator = Cybort::Orchestrator.new(configuration: configuration, persistence: persistence, registry: registry, http_client: nil, dependency_checker: checker)

    result = orchestrator.run

    assert_equal :failure, result.instances.first.status
    assert_equal 0, factory_calls
  end

  private

  def empty_context
    { items: [], last_successful_fetch: nil, sync_state: nil }
  end

  def unavailable_resolution(dependency)
    Cybort::DependencyResolution.new(
      dependency: dependency,
      path: nil,
      version: nil,
      error: { category: "missing", executable: dependency.executable, purpose: dependency.purpose, install_hint: dependency.install_hint }
    )
  end
end
