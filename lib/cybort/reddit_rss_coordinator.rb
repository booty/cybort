module Cybort
  class RedditRssCoordinator
    DEFAULT_CLOCK = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    DEFAULT_SLEEPER = ->(seconds) { sleep(seconds) }
    REQUEST_SPACING_SECONDS = 2
    IN_FLIGHT_WAIT_SLICE_SECONDS = 0.05
    UNKNOWN_COOLDOWN_SECONDS = 60

    class Lease
      def initialize(coordinator, token)
        @coordinator = coordinator
        @token = token
        @released = false
      end

      def observe(metadata:, status: nil)
        return self if @released

        @coordinator.send(:observe, token: @token, metadata: metadata, status: status)
        self
      end

      def release
        return self if @released

        @coordinator.send(:release, token: @token)
        @released = true
        self
      end
    end

    class << self
      def default
        @default
      end
    end

    def initialize(clock: DEFAULT_CLOCK, sleeper: DEFAULT_SLEEPER)
      @clock = callable(clock, :clock)
      @sleeper = callable(sleeper, :sleeper)
      @mutex = Mutex.new
      @active_token = nil
      @next_allowed_at = nil
      @cooldown_observed_at = nil
      @cooldown_delay_seconds = nil
    end

    def acquire(operation:, deadline_monotonic:)
      operation = normalize_operation(operation)
      deadline = normalize_deadline(deadline_monotonic)

      loop do
        token = nil
        wait_seconds = @mutex.synchronize do
          now = monotonic_now
          raise_error(operation, :deadline) unless now < deadline

          cooldown_remaining = cooldown_remaining_seconds(now)
          raise_error(operation, :rate_limited, retry_after_seconds: cooldown_remaining) if cooldown_remaining

          if @active_token
            [deadline - now, IN_FLIGHT_WAIT_SLICE_SECONDS].min
          elsif @next_allowed_at && now < @next_allowed_at
            [deadline - now, @next_allowed_at - now].min
          else
            token = Object.new
            @active_token = token
            nil
          end
        end

        return Lease.new(self, token) if token

        wait_outside_mutex(wait_seconds, operation)
      end
    end

    private

    def observe(token:, metadata:, status:)
      parsed = RateLimitHeaders.parse(metadata)
      @mutex.synchronize do
        return unless @active_token.equal?(token)

        remaining = parsed[:ratelimit_remaining]
        throttled = status.to_i == 429 || (!remaining.nil? && remaining <= 0)
        next unless throttled

        now = monotonic_now
        hints = [parsed[:retry_after_seconds], parsed[:ratelimit_reset_seconds]].filter_map do |value|
          next unless value.is_a?(Numeric) && value.finite? && value >= 0

          value.is_a?(Integer) ? value : value.ceil
        end
        delay = [UNKNOWN_COOLDOWN_SECONDS, hints.max || 0].max
        if @cooldown_observed_at
          current_remaining = cooldown_remaining_seconds(now)
          delay = [delay, current_remaining].max if current_remaining
        end
        @cooldown_observed_at = now
        @cooldown_delay_seconds = delay
      end
    end

    def release(token:)
      @mutex.synchronize do
        return unless @active_token.equal?(token)

        @active_token = nil
        @next_allowed_at = monotonic_now + REQUEST_SPACING_SECONDS
      end
    end

    def cooldown_remaining_seconds(now)
      return unless @cooldown_observed_at && @cooldown_delay_seconds

      elapsed = now.to_r - @cooldown_observed_at.to_r
      return if elapsed >= @cooldown_delay_seconds

      (@cooldown_delay_seconds - elapsed).ceil
    end

    def wait_outside_mutex(wait_seconds, operation)
      raise_error(operation, :deadline) unless wait_seconds && wait_seconds.positive?

      @sleeper.call(wait_seconds)
    rescue StandardError
      raise_error(operation, :deadline)
    end

    def raise_error(operation, category, retry_after_seconds: nil)
      raise RedditRssError.new(
        operation: operation,
        category: category,
        retry_after_seconds: retry_after_seconds
      ), cause: nil
    end

    def normalize_operation(value)
      operation = value.to_sym
      return operation if RedditRssError::OPERATIONS.include?(operation) && !%i[state selection].include?(operation)

      raise ArgumentError, "unsupported Reddit RSS operation"
    rescue NoMethodError
      raise ArgumentError, "unsupported Reddit RSS operation"
    end

    def normalize_deadline(value)
      deadline = Float(value)
      raise ArgumentError, "deadline_monotonic must be finite" unless deadline.finite?

      deadline
    rescue ArgumentError, TypeError
      raise ArgumentError, "deadline_monotonic must be finite"
    end

    def monotonic_now
      value = Float(@clock.call)
      raise ArgumentError, "clock must return a finite number" unless value.finite?

      value
    rescue ArgumentError, TypeError
      raise ArgumentError, "clock must return a finite number"
    end

    def callable(value, name)
      raise ArgumentError, "#{name} must be callable" unless value.respond_to?(:call)

      value
    end
  end

  RedditRssCoordinator.instance_variable_set(:@default, RedditRssCoordinator.new)
end
