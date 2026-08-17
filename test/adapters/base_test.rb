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
      { items: [item], sync_state: { cursor: "new" }, metadata: { status: 200 } }
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

  def adapter(context:, now: Time.utc(2026, 8, 16, 12))
    StubAdapter.new(
      instance: instance,
      context: context,
      http_client: nil,
      clock: -> { now }
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

  def test_source_error_becomes_failure_result
    adapter_instance = adapter(context: { items: [], last_successful_fetch: nil, sync_state: nil })
    adapter_instance.define_singleton_method(:fetch_from_source) { raise "boom" }

    result = adapter_instance.fetch

    refute result.success?
    assert_equal "RuntimeError", result.error.class.name
    assert_equal [], result.items
  end
end

