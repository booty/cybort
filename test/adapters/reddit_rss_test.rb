require "test_helper"

class RedditRssAdapterTest < Minitest::Test
  include RedditRssFixture

  WEIGHTS = {
    "top" => 550,
    "rising" => 300,
    "momentum" => 100,
    "persistence" => 50
  }.freeze

  Instance = Struct.new(
    :id, :name, :adapter, :ttl_minutes, :retention_ttl_minutes,
    :num_items_to_fetch, :options, keyword_init: true
  )

  class RecordingHttp
    attr_reader :calls

    def initialize(bodies:)
      @bodies = bodies
      @calls = []
    end

    def get(url, headers:, timeout_seconds:, deadline_monotonic:)
      @calls << {
        url: url, headers: headers, timeout_seconds: timeout_seconds,
        deadline_monotonic: deadline_monotonic
      }
      value = @bodies.fetch(@calls.length - 1)
      raise value if value.is_a?(Exception)

      Cybort::HttpResponse.new(status: 200, headers: {}, body: value)
    end
  end

  class RecordingGate
    Lease = Struct.new(:observations, :released, keyword_init: true) do
      def observe(metadata:, status:)
        observations << [metadata, status]
      end

      def release
        self.released = true
      end
    end

    attr_reader :leases

    def initialize
      @leases = []
    end

    def acquire(operation:, deadline_monotonic:)
      lease = Lease.new(observations: [], released: false)
      @leases << [operation, deadline_monotonic, lease]
      lease
    end
  end

  def setup
    @now = Time.utc(2026, 9, 6, 12)
    @monotonic = 100.0
    @instance = instance(options: {
      subreddits: ["Ruby", "rails", "ruby"],
      user_agent: "macos:com.example.cybort:v0.1.0 (by /u/example_user)"
    })
  end

  def instance(options:)
    Instance.new(
      id: "reddit", name: "Reddit RSS", adapter: "reddit_rss", ttl_minutes: 15,
      retention_ttl_minutes: nil, num_items_to_fetch: 20, options: options
    )
  end

  def adapter(context: { items: [], last_successful_fetch: nil, sync_state: nil },
              http_client: nil, coordinator: RecordingGate.new)
    Cybort::Adapters::RedditRSS.new(
      instance: @instance,
      context: context,
      http_client: http_client,
      coordinator: coordinator,
      clock: -> { @now },
      monotonic_clock: -> { @monotonic }
    )
  end

  def valid_bodies
    entry = atom_entry(id: "t3_abc", subreddit: "ruby", title: "A post", published: (@now - 60).iso8601)
    empty = atom([])
    [atom([entry]), empty, atom([entry])]
  end

  def test_validates_and_normalizes_the_three_source_options
    weights = { top: 500, rising: 350, momentum: 100, persistence: 50 }
    configured = instance(options: {
      subreddits: ["Rails", "ruby", "rails"],
      user_agent: "macos:com.example.cybort:v0.1.0 (by /u/example_user)",
      activity_weights: weights
    })

    assert Cybort::Adapters::RedditRSS.validate_configuration!(configured)
    built = Cybort::Adapters::RedditRSS.new(
      instance: configured, context: { items: [], sync_state: nil, last_successful_fetch: nil },
      http_client: nil, clock: -> { @now }, monotonic_clock: -> { @monotonic }
    )

    assert_equal ["rails", "ruby"], built.subreddits
    assert_equal weights.transform_keys(&:to_s), built.weights
    assert_equal "macos:com.example.cybort:v0.1.0 (by /u/example_user)", built.user_agent
    assert_empty built.executable_dependencies
  end

  def test_rejects_unknown_credentials_and_cross_type_duplicate_source_options
    [
      { subreddits: ["ruby"], user_agent: valid_user_agent, token: "secret" },
      { subreddits: ["ruby"], user_agent: valid_user_agent, "url" => "https://example.test" },
      { subreddits: ["ruby"], user_agent: valid_user_agent, "user_agent" => valid_user_agent },
      { subreddits: ["ruby"], user_agent: valid_user_agent, activity_weights: WEIGHTS,
        "activity_weights" => WEIGHTS }
    ].each do |options|
      error = assert_raises(Cybort::ConfigurationError) do
        Cybort::Adapters::RedditRSS.validate_configuration!(instance(options: options))
      end
      refute_includes error.message, "secret"
      refute_includes error.message, "example.test"
    end
  end

  def test_rejects_invalid_limits_weights_and_nested_weight_duplicates
    [0, 101, 1.5].each do |limit|
      error = assert_raises(Cybort::ConfigurationError) do
        Cybort::Adapters::RedditRSS.validate_configuration!(instance(options: {
          subreddits: ["ruby"], user_agent: valid_user_agent
        }).tap { |value| value.num_items_to_fetch = limit })
      end
      assert_includes error.message, "num_items_to_fetch"
    end

    [
      { top: 500, rising: 300, momentum: 100, persistence: 101 },
      { top: 0, rising: 0, momentum: 500, persistence: 500 },
      { top: 500, rising: 300, momentum: 100 },
      { top: 500, rising: 300, momentum: 100, persistence: 100, unknown: 0 },
      { top: 500, "top" => 500, rising: 300, momentum: 100, persistence: 50 }
    ].each do |weights|
      assert_raises(Cybort::ConfigurationError) do
        Cybort::Adapters::RedditRSS.validate_configuration!(instance(options: {
          subreddits: ["ruby"], user_agent: valid_user_agent, activity_weights: weights
        }))
      end
    end
  end

  def test_rejects_invalid_subreddits_and_user_agent_without_echoing_values
    invalid_subreddits = [[], ["r/ruby"], ["ruby+rails"], ["a"], ["ruby\n"]]
    invalid_subreddits.each do |subreddits|
      error = assert_raises(Cybort::ConfigurationError) do
        Cybort::Adapters::RedditRSS.validate_configuration!(instance(options: {
          subreddits: subreddits, user_agent: valid_user_agent
        }))
      end
      refute_includes error.message, "ruby+rails"
    end

    ["", "x" * 257, "macos:com.example.cybort:v0.1.0 (by /u/example_user)\n",
     "https://example.test/feed"].each do |user_agent|
      error = assert_raises(Cybort::ConfigurationError) do
        Cybort::Adapters::RedditRSS.validate_configuration!(instance(options: {
          subreddits: ["ruby"], user_agent: user_agent
        }))
      end
      refute_includes error.message, "example.test"
    end
  end

  def test_cache_hit_does_not_construct_or_touch_source_client_or_gate
    context = {
      items: [Cybort::Item.new(
        instance_id: "reddit", canonical_id: "cached", urls: [], fetched_at: @now,
        title: "Cached item", body: nil, remote_created_at: @now, priority: 0,
        action_item: false, info: {}
      )],
      last_successful_fetch: @now,
      sync_state: { "polls" => [] }
    }
    http = Object.new
    def http.get(*)
      raise "HTTP touched on cache hit"
    end
    gate = Object.new
    def gate.acquire(*)
      raise "gate touched on cache hit"
    end

    result = adapter(context: context, http_client: http, coordinator: gate).fetch(
      fetch_mode: :cached, planned_at: @now
    )

    assert result.success?
    refute result.source_fetched
    assert_equal ["cached"], result.items.map(&:canonical_id)
    assert_equal context[:sync_state], result.sync_state
  end

  def test_remote_fetch_requests_new_rising_top_and_returns_replaceable_items
    http = RecordingHttp.new(bodies: valid_bodies)
    gate = RecordingGate.new
    result = adapter(http_client: http, coordinator: gate).fetch(
      fetch_mode: :remote, planned_at: @now
    )

    assert result.success?
    assert result.source_fetched
    assert result.replace_existing_items
    assert_equal [
      "https://www.reddit.com/r/rails+ruby/new/.rss?limit=100",
      "https://www.reddit.com/r/rails+ruby/rising/.rss?limit=100",
      "https://www.reddit.com/r/rails+ruby/top/.rss?t=day&limit=100"
    ], http.calls.map { |call| call.fetch(:url) }
    assert_equal ["t3_abc"], result.items.map(&:canonical_id)
    assert_nil result.items.first.body
    refute result.items.first.info.key?(:author)
    refute result.metadata.values.any? { |value| value.to_s.include?("example_user") }
    assert_equal "reddit_rss", result.metadata.fetch(:source)
    assert_equal 3, gate.leases.length
    assert gate.leases.all? { |_, _, lease| lease.released }
  end

  def test_deadline_expiry_during_item_materialization_fails_without_replacement
    http = RecordingHttp.new(bodies: valid_bodies)
    gate = RecordingGate.new
    original_item_new = Cybort::Item.method(:new)
    advance_monotonic = -> { @monotonic = 281.0 }
    Cybort::Item.define_singleton_method(:new) do |**attributes|
      item = original_item_new.call(**attributes)
      advance_monotonic.call
      item
    end

    result = adapter(http_client: http, coordinator: gate).fetch(
      fetch_mode: :remote, planned_at: @now
    )

    refute result.success?
    assert_equal :deadline, result.metadata.fetch(:category)
    refute result.replace_existing_items
    assert_empty result.items
    assert_nil result.sync_state
  ensure
    Cybort::Item.singleton_class.send(:remove_method, :new)
  end

  def test_failure_in_third_feed_returns_no_partial_items_or_state
    bodies = valid_bodies
    http = RecordingHttp.new(bodies: [bodies.first, bodies[1], "<html>feed failed sentinel</html>"])
    result = adapter(http_client: http).fetch(fetch_mode: :remote, planned_at: @now)

    refute result.success?
    assert_empty result.items
    assert_nil result.sync_state
    assert_equal 3, http.calls.length
  end

  private

  def valid_user_agent
    "macos:com.example.cybort:v0.1.0 (by /u/example_user)"
  end
end
