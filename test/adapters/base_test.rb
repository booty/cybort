require "test_helper"

class BaseAdapterTest < Minitest::Test
  class StubAdapter < Cybort::Adapters::Base
    attr_reader :source_calls

    def initialize(**kwargs)
      @source_calls = 0
      super
    end

    private

    def fetch_from_source
      @source_calls += 1
      {
        items: [item],
        sync_state: { cursor: "new" },
        metadata: { status: 200 },
        replace_existing_items: true
      }
    end

    def item
      Cybort::Item.new(
        instance_id: instance.id,
        canonical_id: "stub-1",
        fetched_at: clock.call,
        title: "Stub item"
      )
    end
  end

  def instance
    Cybort::Configuration::Instance.new(
      id: "stub",
      name: "Stub",
      adapter: "stub",
      ttl_minutes: 30,
      num_items_to_fetch: 5,
      options: {}
    )
  end

  def adapter(context:, now: Time.utc(2026, 8, 16, 12), clock: nil)
    StubAdapter.new(
      instance: instance,
      context: context,
      http_client: nil,
      clock: clock || -> { now }
    )
  end

  def test_fresh_context_returns_cached_items_without_fetching
    cached = Cybort::Item.new(instance_id: "stub", canonical_id: "cached", fetched_at: Time.utc(2026, 8, 16, 11), title: "Cached")
    result = adapter(
      context: {
        items: [cached],
        last_successful_fetch: Time.utc(2026, 8, 16, 11, 45),
        sync_state: { cursor: "old" }
      }
    ).fetch

    assert result.success?
    refute result.source_fetched
    refute result.replace_existing_items
    assert_equal ["cached"], result.items.map(&:canonical_id)
  end

  def test_stale_context_fetches_source
    adapter_instance = adapter(
      context: {
        items: [],
        last_successful_fetch: Time.utc(2026, 8, 16, 11),
        sync_state: { cursor: "old" }
      }
    )

    result = adapter_instance.fetch

    assert result.success?
    assert result.source_fetched
    assert result.replace_existing_items
    assert_equal 1, adapter_instance.source_calls
    assert_equal({ cursor: "new" }, result.sync_state)
  end

  def test_force_fetch_ignores_fresh_context
    adapter_instance = adapter(
      context: {
        items: [],
        last_successful_fetch: Time.utc(2026, 8, 16, 11, 45),
        sync_state: { cursor: "old" }
      }
    )

    result = adapter_instance.fetch(force_fetch: true)

    assert result.source_fetched
    assert_equal 1, adapter_instance.source_calls
  end

  def test_cache_at_exact_ttl_boundary_is_stale
    adapter_instance = adapter(
      context: {
        items: [],
        last_successful_fetch: Time.utc(2026, 8, 16, 11, 30),
        sync_state: { cursor: "old" }
      }
    )

    result = adapter_instance.fetch

    assert result.source_fetched
    assert_equal 1, adapter_instance.source_calls
  end

  def test_source_error_becomes_failure_result
    adapter_instance = adapter(context: { items: [], last_successful_fetch: nil, sync_state: nil })
    adapter_instance.define_singleton_method(:fetch_from_source) { raise "boom" }

    result = adapter_instance.fetch

    refute result.success?
    assert_equal "RuntimeError", result.error.class.name
    assert_equal [], result.items
    refute result.replace_existing_items
  end

  def test_plan_captures_stale_mode_once
    adapter_instance = adapter(
      context: {
        items: [],
        last_successful_fetch: Time.utc(2026, 8, 16, 11),
        sync_state: { cursor: "old" }
      }
    )

    plan = adapter_instance.plan(force_fetch: false, planned_at: Time.utc(2026, 8, 16, 12))

    assert_equal :remote, plan.fetch_mode
    assert_equal Time.utc(2026, 8, 16, 12), plan.planned_at
  end

  def test_fetch_uses_frozen_plan_after_clock_crosses_ttl_boundary
    current_time = [Time.utc(2026, 8, 16, 12, 29, 59)]
    adapter_instance = adapter(
      context: {
        items: [cached_item],
        last_successful_fetch: Time.utc(2026, 8, 16, 12),
        sync_state: { cursor: "old" }
      },
      clock: -> { current_time.fetch(0) }
    )
    plan = adapter_instance.plan(force_fetch: false, planned_at: current_time.fetch(0))
    current_time[0] = Time.utc(2026, 8, 16, 12, 30, 1)

    result = adapter_instance.fetch(fetch_mode: plan.fetch_mode, planned_at: plan.planned_at)

    refute result.source_fetched
    assert_equal 0, adapter_instance.source_calls
  end

  def test_plan_freezes_nested_context_collections
    plan = adapter(context: { items: [], last_successful_fetch: nil, sync_state: {} }).plan(
      force_fetch: false, planned_at: Time.utc(2026, 8, 16, 12)
    )

    assert_raises(FrozenError) { plan.context.fetch(:items) << cached_item }
    assert_raises(FrozenError) { plan.context.fetch(:sync_state)[:cursor] = "new" }
  end

  private

  def cached_item
    Cybort::Item.new(instance_id: "stub", canonical_id: "cached", fetched_at: Time.utc(2026, 8, 16, 11), title: "Cached")
  end
end
