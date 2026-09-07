require "test_helper"

class RedditRssCoordinatorTest < Minitest::Test
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

  class BarrierSleeper
    attr_reader :calls

    def initialize(clock)
      @clock = clock
      @calls = []
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @blocked = false
      @released = false
    end

    def call(seconds)
      @mutex.synchronize do
        @calls << seconds
        @blocked = true
        @condition.broadcast
        @condition.wait(@mutex) until @released
      end
      @clock.advance(seconds)
    end

    def wait_until_blocked
      @mutex.synchronize { @condition.wait(@mutex) until @blocked }
    end

    def release
      @mutex.synchronize do
        @released = true
        @condition.broadcast
      end
      @clock.advance(2.0)
    end
  end

  def setup
    @clock = FakeClock.new
    @sleeper = FakeSleeper.new(@clock)
    @coordinator = Cybort::RedditRssCoordinator.new(
      clock: @clock.method(:call),
      sleeper: @sleeper.method(:call)
    )
  end

  def test_process_wide_lane_spaces_different_instances_and_release_is_idempotent
    sleeper = BarrierSleeper.new(@clock)
    coordinator = Cybort::RedditRssCoordinator.new(
      clock: @clock.method(:call), sleeper: sleeper.method(:call)
    )
    first = coordinator.acquire(operation: :new, deadline_monotonic: 20.0)
    blocked = Thread.new do
      coordinator.acquire(operation: :rising, deadline_monotonic: 20.0)
    end
    sleeper.wait_until_blocked
    assert blocked.alive?

    first.release
    sleeper.release
    second = blocked.value

    assert_operator @clock.now, :>=, 2.0
    second.release
    second.release
  ensure
    blocked&.kill
    blocked&.join
  end

  def test_cooldown_fails_active_acquire_immediately_without_sleeping_huge_delay
    first = @coordinator.acquire(operation: :new, deadline_monotonic: 20.0)
    huge = 10**200
    first.observe(metadata: { retry_after_seconds: huge }, status: 429)
    first.release
    @sleeper.calls.clear

    error = assert_raises(Cybort::RedditRssError) do
      @coordinator.acquire(operation: :top, deadline_monotonic: 10.0)
    end

    assert_equal :rate_limited, error.safe_metadata.fetch(:category)
    assert_equal huge, error.safe_metadata.fetch(:retry_after_seconds)
    assert_empty @sleeper.calls
  end

  def test_zero_remaining_uses_fallback_and_matching_release_survives_observe_error
    lease = @coordinator.acquire(operation: :new, deadline_monotonic: 120.0)
    lease.observe(metadata: { ratelimit_remaining: 0.0 }, status: 200)
    lease.release

    error = assert_raises(Cybort::RedditRssError) do
      @coordinator.acquire(operation: :rising, deadline_monotonic: 59.0)
    end

    assert_equal :rate_limited, error.safe_metadata.fetch(:category)
    assert_equal 60, error.safe_metadata.fetch(:retry_after_seconds)
    assert_equal 0.0, @clock.now
  end

  def test_deadline_and_sleeper_errors_are_safe
    error = assert_raises(Cybort::RedditRssError) do
      @coordinator.acquire(operation: :new, deadline_monotonic: 0.0)
    end
    assert_equal :deadline, error.safe_metadata.fetch(:category)

    failing_sleeper = ->(_seconds) { raise "raw sleeper secret" }
    coordinator = Cybort::RedditRssCoordinator.new(
      clock: @clock.method(:call), sleeper: failing_sleeper
    )
    first = coordinator.acquire(operation: :new, deadline_monotonic: 20.0)
    first.release
    error = assert_raises(Cybort::RedditRssError) do
      coordinator.acquire(operation: :rising, deadline_monotonic: 20.0)
    end
    assert_equal :deadline, error.safe_metadata.fetch(:category)
    refute_includes error.message, "raw sleeper secret"
  end

  def test_default_is_one_process_wide_instance
    assert_same Cybort::RedditRssCoordinator.default, Cybort::RedditRssCoordinator.default
  end
end
