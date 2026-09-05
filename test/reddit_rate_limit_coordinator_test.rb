require "test_helper"

class RedditRateLimitCoordinatorTest < Minitest::Test
  class FakeClock
    attr_reader :now

    def initialize(now = 0.0)
      @now = now
    end

    def call
      @now
    end

    def advance(seconds)
      @now += seconds
    end
  end

  class FakeSleeper
    attr_reader :calls

    def initialize(clock)
      @clock = clock
      @calls = []
    end

    def call(seconds)
      @calls << seconds
      @clock.advance(seconds)
    end
  end

  def setup
    @clock = FakeClock.new
    @sleeper = FakeSleeper.new(@clock)
    @coordinator = Cybort::RedditRateLimitCoordinator.new(
      clock: @clock.method(:call),
      sleeper: @sleeper.method(:call)
    )
  end

  def test_same_client_is_serialized_and_deadline_is_rate_limited
    key = @coordinator.key_for("same")
    first = @coordinator.acquire(key: key, deadline_monotonic: 20.0, operation: :subscriptions)
    first.observe(metadata: { ratelimit_remaining: 1.0, ratelimit_reset_seconds: 10.0 })
    first.release

    lease = @coordinator.acquire(key: key, deadline_monotonic: 20.0, operation: :home_hot)

    error = assert_raises(Cybort::RedditApiError) do
      @coordinator.acquire(key: key, deadline_monotonic: 5.0, operation: :news_hot)
    end

    assert_equal :rate_limited, error.safe_metadata.fetch(:category)
    assert_equal :news_hot, error.safe_metadata.fetch(:operation)
    assert_equal 5.0, @clock.now

    lease.observe(metadata: { ratelimit_remaining: 0.0, ratelimit_reset_seconds: 10.0 })
    lease.release
    reset_lease = @coordinator.acquire(key: key, deadline_monotonic: 20.0)
    assert_equal 15.0, @clock.now
    reset_lease.release
  end

  def test_different_client_ids_are_independent
    first = @coordinator.acquire(key: @coordinator.key_for("first"), deadline_monotonic: 20.0)

    second = @coordinator.acquire(key: @coordinator.key_for("second"), deadline_monotonic: 20.0)

    second.release
    first.release
  end

  def test_retry_after_on_429_blocks_same_client_until_retry_window
    key = @coordinator.key_for("same")
    lease = @coordinator.acquire(key: key, deadline_monotonic: 30.0)
    lease.observe(metadata: { retry_after_seconds: 7 }, status: 429)
    lease.release

    blocked = assert_raises(Cybort::RedditApiError) do
      @coordinator.acquire(key: key, deadline_monotonic: 6.0)
    end
    assert_equal :rate_limited, blocked.safe_metadata.fetch(:category)
    assert_equal 6.0, @clock.now

    released = @coordinator.acquire(key: key, deadline_monotonic: 20.0)
    assert_equal 7.0, @clock.now
    released.release
  end

  def test_unknown_429_uses_a_bounded_fallback_and_recovers
    key = @coordinator.key_for("same")
    lease = @coordinator.acquire(key: key, deadline_monotonic: 120.0)
    lease.observe(metadata: {}, status: 429)
    lease.release

    assert_raises(Cybort::RedditApiError) do
      @coordinator.acquire(key: key, deadline_monotonic: 59.0)
    end
    assert_equal 59.0, @clock.now

    recovered = @coordinator.acquire(key: key, deadline_monotonic: 120.0)
    assert_equal Cybort::RedditRateLimitCoordinator::UNKNOWN_RESET_COOLDOWN_SECONDS, @clock.now
    recovered.release
  end

  def test_zero_remaining_without_reset_uses_a_bounded_fallback
    key = @coordinator.key_for("same")
    lease = @coordinator.acquire(key: key, deadline_monotonic: 120.0)
    lease.observe(metadata: { ratelimit_remaining: 0.0 }, status: 200)
    lease.release

    assert_raises(Cybort::RedditApiError) do
      @coordinator.acquire(key: key, deadline_monotonic: 59.0)
    end
    assert_equal 59.0, @clock.now

    recovered = @coordinator.acquire(key: key, deadline_monotonic: 120.0)
    assert_equal Cybort::RedditRateLimitCoordinator::UNKNOWN_RESET_COOLDOWN_SECONDS, @clock.now
    recovered.release
  end

  def test_release_is_idempotent_and_transport_failure_does_not_invent_capacity
    key = @coordinator.key_for("same")
    lease = @coordinator.acquire(key: key, deadline_monotonic: 20.0)
    lease.observe(metadata: { ratelimit_remaining: 0.0, ratelimit_reset_seconds: 10.0 })

    lease.release
    lease.release

    error = assert_raises(Cybort::RedditApiError) do
      @coordinator.acquire(key: key, deadline_monotonic: 5.0)
    end
    assert_equal :rate_limited, error.safe_metadata.fetch(:category)
    assert_equal 5.0, @clock.now
  end

  def test_key_is_an_opaque_sha256_digest_and_never_appears_in_error
    client_id = "client-secret"
    key = @coordinator.key_for(client_id)

    assert_equal Digest::SHA256.digest(client_id), key
    refute_equal client_id, key

    error = assert_raises(Cybort::RedditApiError) do
      @coordinator.acquire(key: key, deadline_monotonic: -1.0)
    end
    refute_includes error.message, client_id
    refute_includes error.message, key
    refute_includes error.safe_metadata.to_s, client_id
    refute_includes error.safe_metadata.to_s, key
  end

  def test_default_is_process_wide
    assert_same Cybort::RedditRateLimitCoordinator.default, Cybort::RedditRateLimitCoordinator.default
  end
end
