require "test_helper"
require "timeout"

class OrchestratorTest < Minitest::Test
  WAIT_SECONDS = 2

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
    attr_reader :writes, :failures, :registered, :retention_writes,
                :planning_context_calls, :hydrated_context_calls, :expiry_calls

    def initialize
      @writes = []
      @failures = []
      @registered = []
      @retention_writes = []
      @planning_context_calls = []
      @hydrated_context_calls = []
      @expiry_calls = []
    end

    def register_instance(instance)
      @registered << instance
    end

    def context_for(instance_id:)
      @hydrated_context_calls << instance_id
      { items: [], last_successful_fetch: nil, sync_state: nil }
    end

    def planning_context_for(instance_id:)
      @planning_context_calls << instance_id
      { items: [], last_successful_fetch: nil, sync_state: nil }
    end

    def expire_items(instance_id:, hard_expiry_ttl_minutes:)
      @expiry_calls << [instance_id, hard_expiry_ttl_minutes]
      0
    end

    def write_fetch_result(result, retention_ttl_minutes: nil)
      @writes << result
      @retention_writes << [result.instance_id, retention_ttl_minutes]
      0
    end

    def record_fetch_failure(result)
      @failures << result
    end
  end

  class ProgressSpy
    attr_reader :events

    def initialize
      @events = Queue.new
    end

    def puts(message)
      @events << message
    end
  end

  class TimeSeriesMainSpy < PersistenceSpy
    attr_reader :acknowledgements

    def initialize
      super
      @acknowledgements = []
    end

    def pending_time_series_purges
      []
    end

    def acknowledge_time_series_import(receipt)
      @acknowledgements << [receipt, Thread.current]
    end
  end

  class TimeSeriesReaderSpy
    def pending_receipts
      []
    end

    def context_for(instance_id:)
      { series_count: 2, observation_count: 7, sync_state: { cursor: "stored" } }
    end
  end

  class TimeSeriesImportSpy
    attr_reader :imports, :markers, :closed

    def initialize(main:, marker_error: nil)
      @main = main
      @marker_error = marker_error
      @imports = []
      @markers = []
    end

    def import(artifact)
      @imports << [artifact, Thread.current]
      Cybort::TimeSeriesImportReceipt.new(
        instance_id: artifact.instance_id, import_key: artifact.import_key,
        artifact_digest: artifact.digest, import_mode: artifact.import_mode,
        source_started_at: artifact.source_started_at, source_finished_at: artifact.source_finished_at,
        committed_at: artifact.source_finished_at, imported_series_count: artifact.series_count,
        imported_observation_count: artifact.observation_count, stored_series_count: artifact.series_count,
        stored_observation_count: artifact.observation_count, sync_state: artifact.sync_state,
        metadata: artifact.metadata
      )
    end

    def mark_acknowledged(receipt)
      raise "main acknowledgement must precede marker" if @main.acknowledgements.empty?
      @markers << receipt
      raise @marker_error if @marker_error
      receipt
    end

    def close
      @closed = true
    end
  end

  class SignalingPersistenceSpy < PersistenceSpy
    attr_reader :events

    def initialize
      super
      @events = Queue.new
    end

    def write_fetch_result(result, retention_ttl_minutes: nil)
      pruned_count = super
      @events << [:successful, result.instance_id, Thread.current]
      pruned_count
    end

    def record_fetch_failure(result)
      super
      @events << [:failed, result.instance_id, Thread.current]
      nil
    end
  end

  class EscapingPersistenceSpy < PersistenceSpy
    attr_reader :attempts

    def initialize
      super
      @attempts = Queue.new
    end

    def write_fetch_result(result, retention_ttl_minutes: nil)
      @attempts << [result.instance_id, Thread.current]
      raise "write failed"
    end

    def record_fetch_failure(_result)
      raise "failure history failed"
    end
  end

  class PersistenceSpyWithContexts < PersistenceSpy
    def initialize(contexts)
      super()
      @contexts = contexts
    end

    def context_for(instance_id:)
      @hydrated_context_calls << instance_id
      @contexts.fetch(instance_id)
    end

    def planning_context_for(instance_id:)
      @planning_context_calls << instance_id
      @contexts.fetch(instance_id).merge(items: [])
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

  class FixedResultAdapter
    def initialize(result:, **)
      @result = result
    end

    def fetch(force_fetch: false, fetch_mode: nil, planned_at: nil)
      @result
    end
  end

  class BrokenSafeMetadataError < StandardError
    def safe_metadata
      raise "safe metadata failed"
    end
  end

  class WorkerLaunchError < RuntimeError; end

  class SecondWorkerLaunchFailsOrchestrator < Cybort::Orchestrator
    private

    def start_worker(&block)
      @worker_starts = @worker_starts.to_i + 1
      raise WorkerLaunchError, "worker launch failed" if @worker_starts == 2

      super
    end
  end

  class RaisingAdapter
    def initialize(error:, **)
      @error = error
    end

    def fetch(force_fetch: false, fetch_mode: nil, planned_at: nil)
      raise @error
    end
  end

  class ThreadReportingGateAdapter < GateAdapter
    def initialize(worker_threads:, **kwargs)
      super(**kwargs)
      @worker_threads = worker_threads
    end

    def fetch(**options)
      @worker_threads << [@instance.id, Thread.current]
      super
    end
  end

  class GatedRaisingAdapter
    def initialize(instance:, started:, release:, worker_threads:, error:, **)
      @instance = instance
      @started = started
      @release = release
      @worker_threads = worker_threads
      @error = error
    end

    def fetch(force_fetch: false, fetch_mode: nil, planned_at: nil)
      @started << @instance.id
      @worker_threads << [@instance.id, Thread.current]
      @release.pop
      raise @error
    end
  end

  class RetentionMutatingAdapter
    def initialize(instance:, **)
      @instance = instance
    end

    def fetch(force_fetch: false, fetch_mode: nil, planned_at: nil)
      @instance.retention_ttl_minutes = nil
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

  def instance(id, retention_ttl_minutes: nil, hard_expiry_ttl_minutes: nil)
    Cybort::Configuration::Instance.new(
      id: id,
      name: id.capitalize,
      adapter: "gate",
      ttl_minutes: 30,
      retention_ttl_minutes: retention_ttl_minutes,
      hard_expiry_ttl_minutes: hard_expiry_ttl_minutes,
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

  def test_persists_each_adapter_when_it_finishes_and_preserves_result_order
    started = Queue.new
    releases = { "one" => Queue.new, "two" => Queue.new }
    registry = Cybort::AdapterRegistry.new
    registry.register("gate", lambda { |**kwargs|
      GateAdapter.new(
        **kwargs,
        started: started,
        release: releases.fetch(kwargs.fetch(:instance).id)
      )
    })
    configuration = Struct.new(:instances).new({ "one" => instance("one"), "two" => instance("two") })
    persistence = SignalingPersistenceSpy.new
    progress = ProgressSpy.new
    orchestrator = Cybort::Orchestrator.new(
      configuration: configuration, persistence: persistence, registry: registry,
      http_client: nil, progress: progress
    )

    run_thread = start_run { orchestrator.run }
    assert_equal %w[one two], [await(started), await(started)].sort
    2.times { await(progress.events) }

    releases.fetch("two") << true
    assert_equal [:successful, "two", run_thread], await(persistence.events)
    await(progress.events)
    assert_equal ["two"], persistence.writes.map(&:instance_id)
    assert run_thread.alive?

    releases.fetch("one") << true
    assert_equal [:successful, "one", run_thread], await(persistence.events)
    await(progress.events)
    result = await_value(run_thread)

    assert_equal :success, result.overall_status
    assert_equal %w[one two], result.instances.map(&:instance_id)
    assert_equal %w[two one], persistence.writes.map(&:instance_id)
    assert_empty persistence.failures
  ensure
    release_and_stop(run_thread, releases)
  end

  def test_records_preflight_failure_while_another_adapter_is_blocked
    dependency = Cybort::Dependency.new(executable: "fixture-tool", purpose: "test fixture")
    started = Queue.new
    release = Queue.new
    registry = Cybort::AdapterRegistry.new
    registry.register(
      "blocked", ->(**kwargs) { PlanningAdapter.new(**kwargs, modes: []) },
      dependencies: [dependency], validate_configuration: ->(_instance) {}
    )
    registry.register(
      "gate", ->(**kwargs) { GateAdapter.new(**kwargs, started: started, release: release) }
    )
    blocked = instance("blocked").tap { |value| value.adapter = "blocked" }
    gate = instance("gate")
    configuration = Struct.new(:instances).new({ "blocked" => blocked, "gate" => gate })
    persistence = SignalingPersistenceSpy.new
    orchestrator = Cybort::Orchestrator.new(
      configuration: configuration, persistence: persistence, registry: registry,
      http_client: nil, dependency_checker: CheckerSpy.new(unavailable_resolution(dependency))
    )

    run_thread = start_run { orchestrator.run }
    assert_equal "gate", await(started)
    assert_equal [:failed, "blocked", run_thread], await(persistence.events)
    assert run_thread.alive?

    release << true
    assert_equal [:successful, "gate", run_thread], await(persistence.events)
    result = await_value(run_thread)
    assert_equal %i[failure success], result.instances.map(&:status)
  ensure
    release_and_stop(run_thread, { "gate" => release })
  end

  def test_propagates_failure_during_adapter_error_conversion_without_hanging
    registry = Cybort::AdapterRegistry.new
    error = BrokenSafeMetadataError.new("adapter failed")
    registry.register("raising", ->(**kwargs) { RaisingAdapter.new(**kwargs, error: error) })
    configured = instance("raising").tap { |value| value.adapter = "raising" }
    configuration = Struct.new(:instances).new({ "raising" => configured })
    orchestrator = Cybort::Orchestrator.new(
      configuration: configuration, persistence: PersistenceSpy.new,
      registry: registry, http_client: nil
    )

    run_thread = start_run { orchestrator.run }
    raised = assert_raises(RuntimeError) { await_value(run_thread) }
    assert_equal "safe metadata failed", raised.message
  ensure
    release_and_stop(run_thread, {})
  end

  def test_preserves_persistence_error_while_observing_every_worker
    started = Queue.new
    worker_threads = Queue.new
    releases = { "one" => Queue.new, "two" => Queue.new }
    registry = Cybort::AdapterRegistry.new
    registry.register("gate", lambda { |**kwargs|
      id = kwargs.fetch(:instance).id
      if id == "one"
        GatedRaisingAdapter.new(
          **kwargs, started: started, release: releases.fetch(id),
          worker_threads: worker_threads,
          error: BrokenSafeMetadataError.new("secondary worker failed")
        )
      else
        ThreadReportingGateAdapter.new(
          **kwargs, started: started, release: releases.fetch(id),
          worker_threads: worker_threads
        )
      end
    })
    configuration = Struct.new(:instances).new({ "one" => instance("one"), "two" => instance("two") })
    persistence = EscapingPersistenceSpy.new
    orchestrator = Cybort::Orchestrator.new(
      configuration: configuration, persistence: persistence,
      registry: registry, http_client: nil
    )

    run_thread = start_run { orchestrator.run }
    assert_equal %w[one two], [await(started), await(started)].sort
    workers = 2.times.to_h { await(worker_threads) }

    releases.fetch("two") << true
    assert_equal ["two", run_thread], await(persistence.attempts)
    assert run_thread.alive?

    releases.fetch("one") << true
    raised = assert_raises(RuntimeError) { await_value(run_thread) }
    assert_equal "failure history failed", raised.message
    refute workers.fetch("one").alive?
    refute workers.fetch("two").alive?
  ensure
    release_and_stop(run_thread, releases)
  end

  def test_preserves_launch_error_while_observing_an_earlier_failed_worker
    started = Queue.new
    worker_threads = Queue.new
    releases = { "one" => Queue.new, "two" => Queue.new }
    registry = Cybort::AdapterRegistry.new
    registry.register("gate", lambda { |**kwargs|
      id = kwargs.fetch(:instance).id
      if id == "one"
        GatedRaisingAdapter.new(
          **kwargs, started: started, release: releases.fetch(id),
          worker_threads: worker_threads,
          error: BrokenSafeMetadataError.new("secondary worker failed")
        )
      else
        GateAdapter.new(**kwargs, started: started, release: releases.fetch(id))
      end
    })
    configuration = Struct.new(:instances).new({ "one" => instance("one"), "two" => instance("two") })
    orchestrator = SecondWorkerLaunchFailsOrchestrator.new(
      configuration: configuration, persistence: PersistenceSpy.new,
      registry: registry, http_client: nil
    )

    run_thread = start_run { orchestrator.run }
    assert_equal "one", await(started)
    _instance_id, worker = await(worker_threads)
    assert run_thread.alive?

    releases.fetch("one") << true
    raised = assert_raises(WorkerLaunchError) { await_value(run_thread) }
    assert_equal "worker launch failed", raised.message
    refute worker.alive?
  ensure
    release_and_stop(run_thread, releases)
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

  def test_passes_each_instances_retention_to_persistence
    calls = []
    registry = Cybort::AdapterRegistry.new
    registry.register(
      "force",
      ->(**kwargs) { ForceRecordingAdapter.new(**kwargs, calls: calls) }
    )
    retained = instance("retained", retention_ttl_minutes: 120).tap do |value|
      value.adapter = "force"
    end
    forever = instance("forever").tap { |value| value.adapter = "force" }
    configuration = Struct.new(:instances).new(
      { "retained" => retained, "forever" => forever }
    )
    persistence = PersistenceSpy.new
    orchestrator = Cybort::Orchestrator.new(
      configuration: configuration,
      persistence: persistence,
      registry: registry,
      http_client: nil
    )

    orchestrator.run(force_fetch: true)

    assert_equal({ "retained" => 120, "forever" => nil },
                 persistence.retention_writes.to_h)
  end

  def test_expires_hard_bound_items_before_planning
    registry = Cybort::AdapterRegistry.new
    registry.register("force", ->(**kwargs) { ForceRecordingAdapter.new(**kwargs, calls: []) })
    configured = instance("retained", hard_expiry_ttl_minutes: 1).tap { |value| value.adapter = "force" }
    configuration = Struct.new(:instances).new({ "retained" => configured })
    persistence = PersistenceSpy.new
    orchestrator = Cybort::Orchestrator.new(
      configuration: configuration,
      persistence: persistence,
      registry: registry,
      http_client: nil
    )

    orchestrator.run(force_fetch: true)

    assert_equal [["retained", 1]], persistence.expiry_calls
    assert_equal ["retained"], persistence.planning_context_calls
  end

  def test_remote_planning_does_not_hydrate_cached_items
    registry = Cybort::AdapterRegistry.new
    registry.register("force", ->(**kwargs) { ForceRecordingAdapter.new(**kwargs, calls: []) })
    configured = instance("remote").tap { |value| value.adapter = "force" }
    configuration = Struct.new(:instances).new({ "remote" => configured })
    persistence = PersistenceSpy.new
    orchestrator = Cybort::Orchestrator.new(
      configuration: configuration,
      persistence: persistence,
      registry: registry,
      http_client: nil
    )

    orchestrator.run(force_fetch: true)

    assert_equal ["remote"], persistence.planning_context_calls
    assert_empty persistence.hydrated_context_calls
  end

  def test_uses_retention_policy_snapshotted_after_configuration_validation
    registry = Cybort::AdapterRegistry.new
    registry.register("mutating", RetentionMutatingAdapter)
    configured = instance("mutable", retention_ttl_minutes: 120).tap do |value|
      value.adapter = "mutating"
    end
    configuration = Struct.new(:instances).new({ "mutable" => configured })
    persistence = PersistenceSpy.new
    orchestrator = Cybort::Orchestrator.new(
      configuration: configuration,
      persistence: persistence,
      registry: registry,
      http_client: nil
    )

    orchestrator.run(force_fetch: true)

    assert_nil configured.retention_ttl_minutes
    assert_equal [["mutable", 120]], persistence.retention_writes
  end

  def test_success_result_with_wrong_instance_id_records_failure_for_configured_instance
    with_database do |path|
      persistence = Cybort::Persistence.new(path).setup!
      wrong_result = Cybort::FetchResult.success(
        instance_id: "supplied",
        items: [Cybort::Item.new(instance_id: "supplied", canonical_id: "wrong", fetched_at: Time.utc(2026, 8, 16, 12), title: "Wrong")],
        sync_state: { cursor: "wrong" },
        started_at: Time.utc(2026, 8, 16, 12),
        finished_at: Time.utc(2026, 8, 16, 12, 1),
        source_fetched: true
      )
      run = run_fixed_result(instance("configured"), wrong_result, persistence)

      assert_equal :failure, run.instances.first.status
      assert_equal "configured", run.instances.first.instance_id
      assert_empty persistence.items_for(instance_id: "supplied")
      assert_nil persistence.context_for(instance_id: "supplied").fetch(:sync_state)
      assert_nil persistence.context_for(instance_id: "supplied").fetch(:last_successful_fetch)
      assert_empty persistence.fetch_runs_for(instance_id: "supplied")
      assert_nil persistence.instance_record("supplied")
      assert_equal ["failed"], persistence.fetch_runs_for(instance_id: "configured").map { |row| row.fetch("status") }
    end
  end

  def test_failure_result_with_wrong_instance_id_records_failure_for_configured_instance
    with_database do |path|
      persistence = Cybort::Persistence.new(path).setup!
      wrong_result = Cybort::FetchResult.failure(
        instance_id: "supplied",
        error: Cybort::SourceError.new("wrong source failed"),
        started_at: Time.utc(2026, 8, 16, 12),
        finished_at: Time.utc(2026, 8, 16, 12, 1)
      )
      run = run_fixed_result(instance("configured"), wrong_result, persistence)

      assert_equal :failure, run.instances.first.status
      assert_equal "configured", run.instances.first.instance_id
      assert_empty persistence.items_for(instance_id: "supplied")
      assert_nil persistence.context_for(instance_id: "supplied").fetch(:sync_state)
      assert_nil persistence.context_for(instance_id: "supplied").fetch(:last_successful_fetch)
      assert_empty persistence.fetch_runs_for(instance_id: "supplied")
      assert_nil persistence.instance_record("supplied")
      assert_equal ["failed"], persistence.fetch_runs_for(instance_id: "configured").map { |row| row.fetch("status") }
    end
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
    dependency = Cybort::Dependency.new(executable: "fixture-tool", purpose: "test fixture")
    registry = Cybort::AdapterRegistry.new
    modes = []
    registry.register("command_fixture", ->(**kwargs) { PlanningAdapter.new(**kwargs, modes: modes) }, dependencies: [dependency], validate_configuration: ->(_instance) {})
    configured = instance("mail", retention_ttl_minutes: 60).tap { |value| value.adapter = "command_fixture" }
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
    assert_empty persistence.retention_writes
  end

  def test_stale_missing_dependency_fails_only_that_instance_and_groups_guidance
    dependency = Cybort::Dependency.new(
      executable: "fixture-tool", purpose: "test fixture", install_hint: "brew install fixture-tool"
    )
    registry = Cybort::AdapterRegistry.new
    modes = []
    registry.register("command_fixture", ->(**kwargs) { PlanningAdapter.new(**kwargs, modes: modes) }, dependencies: [dependency], validate_configuration: ->(_instance) {})
    registry.register("rss", ->(**kwargs) { PlanningAdapter.new(**kwargs, modes: modes) }, validate_configuration: ->(_instance) {})
    mail = instance("mail").tap { |value| value.adapter = "command_fixture" }
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
    assert_equal ["fixture-tool"], checker.calls
    assert_equal ["mail"], result.unavailable_dependencies.first.fetch(:instances)
    assert_equal ["feed"], persistence.writes.map(&:instance_id)
  end

  def test_two_remote_instances_resolve_one_unique_executable
    dependency = Cybort::Dependency.new(executable: "fixture-tool", purpose: "test fixture")
    registry = Cybort::AdapterRegistry.new
    modes = []
    registry.register("command_fixture", ->(**kwargs) { PlanningAdapter.new(**kwargs, modes: modes) }, dependencies: [dependency], validate_configuration: ->(_instance) {})
    first = instance("one").tap { |value| value.adapter = "command_fixture" }
    second = instance("two").tap { |value| value.adapter = "command_fixture" }
    configuration = Struct.new(:instances).new({ "one" => first, "two" => second })
    persistence = PersistenceSpyWithContexts.new("one" => empty_context, "two" => empty_context)
    checker = CheckerSpy.new(unavailable_resolution(dependency))
    orchestrator = Cybort::Orchestrator.new(configuration: configuration, persistence: persistence, registry: registry, http_client: nil, dependency_checker: checker)

    result = orchestrator.run

    assert_equal ["fixture-tool"], checker.calls
    assert_equal %w[one two], result.unavailable_dependencies.first.fetch(:instances)
  end

  def test_resolves_all_dependencies_for_an_instance_before_reporting_failures
    first_dependency = Cybort::Dependency.new(executable: "fixture-tool", purpose: "test fixture")
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
      "fixture-tool" => unavailable_resolution(first_dependency),
      "jq" => unavailable_resolution(second_dependency)
    )
    orchestrator = Cybort::Orchestrator.new(configuration: configuration, persistence: persistence, registry: registry, http_client: nil, dependency_checker: checker)

    result = orchestrator.run

    assert_equal %w[fixture-tool jq], checker.calls
    assert_equal %w[fixture-tool jq], result.unavailable_dependencies.map { |value| value.fetch(:tool) }
    assert_equal 0, factory_calls
  end

  def test_unavailable_dependency_does_not_construct_runtime_factory
    dependency = Cybort::Dependency.new(executable: "fixture-tool", purpose: "test fixture")
    registry = Cybort::AdapterRegistry.new
    factory_calls = 0
    registry.register(
      "command_fixture",
      ->(**_kwargs) { factory_calls += 1; raise "runtime factory must not run" },
      dependencies: [dependency],
      validate_configuration: ->(_instance) {}
    )
    configured = instance("mail").tap { |value| value.adapter = "command_fixture" }
    configuration = Struct.new(:instances).new({ "mail" => configured })
    persistence = PersistenceSpyWithContexts.new("mail" => empty_context)
    checker = CheckerSpy.new(unavailable_resolution(dependency))
    orchestrator = Cybort::Orchestrator.new(configuration: configuration, persistence: persistence, registry: registry, http_client: nil, dependency_checker: checker)

    result = orchestrator.run

    assert_equal :failure, result.instances.first.status
    assert_equal 0, factory_calls
  end

  def test_time_series_cache_and_failure_never_submit_imports
    now = Time.utc(2026, 9, 9, 12)
    results = [
      Cybort::TimeSeriesFetchResult.cached(
        instance_id: "sensor", sync_state: {}, started_at: now, finished_at: now,
        series_count: 2, observation_count: 7
      ),
      Cybort::TimeSeriesFetchResult.failure(
        instance_id: "sensor", error: RuntimeError.new("source unavailable"),
        started_at: now, finished_at: now
      )
    ]
    results.each do |source_result|
      main = TimeSeriesMainSpy.new
      canonical = TimeSeriesImportSpy.new(main: main)
      run = run_time_series_result(source_result, main, canonical)

      assert_empty canonical.imports
      assert_empty canonical.markers
      assert canonical.closed
      assert_equal source_result.failure? ? :failure : :cached, run.instances.first.status
      assert_equal source_result.observation_count, run.instances.first.observation_count
      assert_equal 0, run.instances.first.item_count
      assert_instance_of Cybort::FetchResult, main.failures.first if source_result.failure?
    end
  end

  def test_time_series_import_acknowledges_on_caller_before_writer_marker
    with_time_series_result do |source_result|
      main = TimeSeriesMainSpy.new
      canonical = TimeSeriesImportSpy.new(main: main)
      run = run_time_series_result(source_result, main, canonical)

      assert_equal :success, run.overall_status
      assert_equal 1, canonical.imports.length
      refute_equal Thread.current, canonical.imports.first.last
      assert_equal Thread.current, main.acknowledgements.first.last
      assert_equal 1, canonical.markers.length
      assert_empty main.failures
      refute File.exist?(source_result.artifact.path)
      assert canonical.closed
    end
  end

  def test_time_series_marker_failure_preserves_main_success
    with_time_series_result do |source_result|
      main = TimeSeriesMainSpy.new
      canonical = TimeSeriesImportSpy.new(main: main, marker_error: RuntimeError.new("marker failed"))
      run = run_time_series_result(source_result, main, canonical)

      assert_equal :success, run.overall_status
      assert_equal true, run.instances.first.metadata.fetch(:receipt_acknowledgement_pending)
      assert_equal 1, main.acknowledgements.length
      assert_empty main.failures
    end
  end

  def test_time_series_registration_rejects_an_item_result_at_persistence_boundary
    now = Time.utc(2026, 9, 9, 12)
    source_result = Cybort::FetchResult.success(
      instance_id: "sensor", items: [], sync_state: {}, started_at: now,
      finished_at: now, source_fetched: true
    )
    main = TimeSeriesMainSpy.new
    canonical = TimeSeriesImportSpy.new(main: main)
    run = run_time_series_result(source_result, main, canonical)

    assert_equal :failure, run.overall_status
    assert_instance_of Cybort::ValidationError, run.instances.first.error
    assert_instance_of Cybort::FetchResult, main.failures.first
    assert_empty canonical.imports
    assert_empty main.writes
  end

  private

  def run_time_series_result(source_result, main, canonical)
    registry = Cybort::AdapterRegistry.new
    spool_factory = Object.new
    registry.register("series_fixture", ->(context:, spool_factory:, **) {
      assert_equal 7, context.fetch(:observation_count)
      assert_equal({ cursor: "stored" }, context.fetch(:sync_state))
      refute_nil spool_factory
      FixedResultAdapter.new(result: source_result)
    }, result_kind: :time_series)
    configured = instance("sensor").tap { |value| value.adapter = "series_fixture" }
    Cybort::Orchestrator.new(
      configuration: Struct.new(:instances).new({ "sensor" => configured }),
      persistence: main, registry: registry, http_client: nil,
      clock: -> { Time.utc(2026, 9, 9, 13) }, time_series_reader: TimeSeriesReaderSpy.new,
      time_series_persistence_factory: -> { canonical }, time_series_spool_factory: spool_factory
    ).run(force_fetch: true)
  end

  def with_time_series_result
    Tempfile.create(["cybort-orchestrator-spool", ".sqlite3"]) do |file|
      file.close
      now = Time.utc(2026, 9, 9, 12)
      artifact = Cybort::TimeSeriesSpoolArtifact.new(
        path: file.path, instance_id: "sensor", import_key: "batch-1", import_mode: :append,
        digest: Digest::SHA256.file(file.path).hexdigest, series_count: 0, observation_count: 0,
        sync_state: {}, source_started_at: now, source_finished_at: now, metadata: {}
      )
      yield Cybort::TimeSeriesFetchResult.success(
        instance_id: "sensor", artifact: artifact, sync_state: {},
        started_at: now, finished_at: now, source_fetched: true
      )
    end
  end

  def start_run(&block)
    Thread.new do
      Thread.current.report_on_exception = false
      block.call
    end
  end

  def await(queue)
    Timeout.timeout(WAIT_SECONDS) { queue.pop }
  end

  def await_value(thread)
    Timeout.timeout(WAIT_SECONDS) { thread.value }
  end

  def release_and_stop(run_thread, releases)
    releases&.each_value { |release| release << true }
    return unless run_thread

    begin
      run_thread.join(WAIT_SECONDS)
    rescue Exception # rubocop:disable Lint/RescueException -- expected failures are asserted before cleanup
      nil
    end
    return unless run_thread.alive?

    run_thread.kill
    begin
      run_thread.join(WAIT_SECONDS)
    rescue Exception # rubocop:disable Lint/RescueException -- cleanup must not mask the test assertion
      nil
    end
  end

  def with_database
    Tempfile.create(["cybort", ".sqlite3"]) do |file|
      file.close
      yield file.path
    end
  end

  def run_fixed_result(configured, result, persistence)
    registry = Cybort::AdapterRegistry.new
    registry.register(
      "fixed",
      ->(**kwargs) { FixedResultAdapter.new(**kwargs, result: result) }
    )
    configured.adapter = "fixed"
    configuration = Struct.new(:instances).new({ configured.id => configured })
    Cybort::Orchestrator.new(
      configuration: configuration,
      persistence: persistence,
      registry: registry,
      http_client: nil
    ).run(force_fetch: true)
  end

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
