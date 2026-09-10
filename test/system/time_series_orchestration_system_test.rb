require "test_helper"
require "set"
require "timeout"

class TimeSeriesOrchestrationSystemTest < Minitest::Test
  WAIT_SECONDS = 2

  class MainPersistenceSpy
    attr_reader :writes, :failures, :acknowledgements

    def initialize(item_commit_events)
      @item_commit_events = item_commit_events
      @writes = []
      @failures = []
      @acknowledgements = []
    end

    def register_instance(_instance); end

    def planning_context_for(instance_id:)
      { items: [], item_ids: Set.new, last_successful_fetch: nil, sync_state: nil }
    end

    def expire_items(instance_id:, hard_expiry_ttl_minutes:)
      0
    end

    def write_fetch_result(result, retention_ttl_minutes: nil)
      @writes << [result.instance_id, Thread.current]
      @item_commit_events << result.instance_id
      0
    end

    def record_fetch_failure(result)
      @failures << result
    end

    def pending_time_series_purges
      []
    end

    def acknowledge_time_series_import(receipt)
      @acknowledgements << [receipt, Thread.current]
      true
    end
  end

  class ReaderSpy
    def pending_receipts
      []
    end

    def context_for(instance_id:)
      { series_count: 0, observation_count: 0, last_successful_fetch: nil, sync_state: {} }
    end
  end

  class BlockingTimeSeriesPersistence
    attr_reader :imports, :acknowledgements

    def initialize(import_started, release_import)
      @import_started = import_started
      @release_import = release_import
      @imports = []
      @acknowledgements = []
    end

    def import(artifact)
      @import_started << artifact.import_key
      @release_import.pop
      @imports << artifact
      receipt_for(artifact)
    end

    def mark_acknowledged(receipt)
      @acknowledgements << receipt
      receipt
    end

    def delete_instance(instance_id:)
      true
    end

    def close
      nil
    end

    private

    def receipt_for(artifact)
      Cybort::TimeSeriesImportReceipt.new(
        instance_id: artifact.instance_id, import_key: artifact.import_key,
        artifact_digest: artifact.digest, import_mode: artifact.import_mode,
        source_started_at: artifact.source_started_at, source_finished_at: artifact.source_finished_at,
        committed_at: artifact.source_finished_at, acknowledged_at: nil,
        imported_series_count: artifact.series_count, imported_observation_count: artifact.observation_count,
        stored_series_count: artifact.series_count, stored_observation_count: artifact.observation_count,
        sync_state: artifact.sync_state, metadata: artifact.metadata
      )
    end
  end

  class ItemAdapter
    def initialize(instance:)
      @instance = instance
    end

    def fetch(force_fetch: false, fetch_mode: nil, planned_at: nil)
      now = Time.utc(2026, 9, 10, 12)
      Cybort::FetchResult.success(
        instance_id: @instance.id,
        items: [Cybort::Item.new(
          instance_id: @instance.id, canonical_id: "item-1", fetched_at: now, title: "Item"
        )],
        sync_state: {}, started_at: now, finished_at: now, source_fetched: true
      )
    end
  end

  class TimeSeriesAdapter
    def initialize(instance:, result:)
      @instance = instance
      @result = result
    end

    def fetch(force_fetch: false, fetch_mode: nil, planned_at: nil)
      @result
    end
  end

  def test_item_commit_overlaps_a_blocked_time_series_import
    import_started = Queue.new
    release_import = Queue.new
    item_commit_events = Queue.new
    item = instance("item", adapter: "item_fixture")
    series = instance("series", adapter: "series_fixture")

    with_artifact do |source_result|
      registry = Cybort::AdapterRegistry.new
      registry.register("item_fixture", ->(instance:, **) { ItemAdapter.new(instance: instance) })
      registry.register(
        "series_fixture",
        ->(instance:, spool_factory:, **) { TimeSeriesAdapter.new(instance: instance, result: source_result) },
        result_kind: :time_series
      )
      main = MainPersistenceSpy.new(item_commit_events)
      canonical = BlockingTimeSeriesPersistence.new(import_started, release_import)
      orchestrator = Cybort::Orchestrator.new(
        configuration: Struct.new(:instances).new({ series.id => series, item.id => item }),
        persistence: main, registry: registry, http_client: nil,
        time_series_reader: ReaderSpy.new,
        time_series_persistence_factory: -> { canonical },
        time_series_spool_factory: Object.new
      )

      run_thread = Thread.new do
        Thread.current.report_on_exception = false
        orchestrator.run(force_fetch: true)
      end

      assert_equal "batch-1", await(import_started)
      assert_equal "item", await(item_commit_events)
      assert run_thread.alive?
      assert_equal [], canonical.acknowledgements

      release_import << true
      result = await_value(run_thread)
      assert_equal :success, result.overall_status
      assert_equal %i[success success], result.instances.map(&:status)
      assert_equal ["item"], main.writes.map(&:first)
      assert_equal ["batch-1"], canonical.imports.map(&:import_key)
      assert_equal ["batch-1"], canonical.acknowledgements.map(&:import_key)
    ensure
      release_import << true if run_thread&.alive?
      run_thread&.join(WAIT_SECONDS)
    end
  end

  private

  def instance(id, adapter:)
    Cybort::Configuration::Instance.new(
      id: id, name: id.capitalize, adapter: adapter, ttl_minutes: 30,
      retention_ttl_minutes: nil, hard_expiry_ttl_minutes: nil,
      num_items_to_fetch: 5, options: {}
    )
  end

  def await(queue)
    Timeout.timeout(WAIT_SECONDS) { queue.pop }
  end

  def await_value(thread)
    Timeout.timeout(WAIT_SECONDS) { thread.value }
  end

  def with_artifact
    Tempfile.create(["cybort-time-series-system", ".sqlite3"]) do |file|
      file.close
      now = Time.utc(2026, 9, 10, 12)
      artifact = Cybort::TimeSeriesSpoolArtifact.new(
        path: file.path, instance_id: "series", import_key: "batch-1", import_mode: :append,
        digest: Digest::SHA256.file(file.path).hexdigest, series_count: 0, observation_count: 0,
        sync_state: {}, source_started_at: now, source_finished_at: now, metadata: {}
      )
      yield Cybort::TimeSeriesFetchResult.success(
        instance_id: "series", artifact: artifact, sync_state: {},
        started_at: now, finished_at: now, source_fetched: true
      )
    end
  end
end
