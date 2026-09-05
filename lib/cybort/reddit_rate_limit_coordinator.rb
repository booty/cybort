require "digest"

module Cybort
  class RedditRateLimitCoordinator
    DEFAULT_CLOCK = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    DEFAULT_SLEEPER = ->(seconds) { sleep(seconds) }
    IN_FLIGHT_WAIT_SLICE_SECONDS = 0.05
    ERROR_OPERATION = :home_hot

    State = Struct.new(:remaining, :reset_at, :lease_token, keyword_init: true)

    class Lease
      def initialize(coordinator, key, lease_token)
        @coordinator = coordinator
        @key = key
        @lease_token = lease_token
        @released = false
      end

      def observe(metadata:, status: nil)
        return self if @released

        @coordinator.send(
          :observe,
          key: @key,
          lease_token: @lease_token,
          metadata: metadata,
          status: status
        )
        self
      end

      def release
        return self if @released

        @coordinator.send(:release, key: @key, lease_token: @lease_token)
        @released = true
        self
      end

    end

    class << self
      def default
        @default ||= new
      end
    end

    def initialize(clock: DEFAULT_CLOCK, sleeper: DEFAULT_SLEEPER)
      @clock = callable(clock, :clock)
      @sleeper = callable(sleeper, :sleeper)
      @mutex = Mutex.new
      @states = {}
    end

    def key_for(client_id)
      raise ArgumentError, "client_id must be a nonblank string" unless client_id.is_a?(String) && !client_id.empty?

      Digest::SHA256.digest(client_id).freeze
    end

    def acquire(key:, deadline_monotonic:, operation: ERROR_OPERATION)
      deadline = normalize_deadline(deadline_monotonic)
      operation = normalize_operation(operation)

      loop do
        wait_seconds = nil
        admitted = false
        lease_token = nil

        @mutex.synchronize do
          now = monotonic_now
          raise_rate_limited(operation) unless now < deadline

          state = state_for(key)
          reset_expired_state(state, now)

          if state.lease_token
            wait_seconds = [deadline - now, IN_FLIGHT_WAIT_SLICE_SECONDS].min
          elsif state.remaining && state.remaining <= 0
            reset_at = state.reset_at || Float::INFINITY
            if reset_at <= now
              state.remaining = nil
              state.reset_at = nil
              wait_seconds = nil
            else
              wait_seconds = [deadline - now, reset_at - now].min
            end
          end

          unless wait_seconds
            lease_token = Object.new
            state.remaining -= 1 if state.remaining
            state.lease_token = lease_token
            admitted = true
          end
        end

        if admitted
          return Lease.new(self, key, lease_token)
        end

        wait_outside_mutex(wait_seconds, operation)
      end
    end

    private

    def observe(key:, lease_token:, metadata:, status:)
      parsed = parse_metadata(metadata)
      @mutex.synchronize do
        state = @states[key]
        return unless state && state.lease_token.equal?(lease_token)

        now = monotonic_now
        state.remaining = parsed[:ratelimit_remaining] unless parsed[:ratelimit_remaining].nil?

        delays = [parsed[:ratelimit_reset_seconds], parsed[:retry_after_seconds]].compact
        if status.to_i == 429
          state.remaining = 0.0
          state.reset_at = if delays.empty?
                             Float::INFINITY
                           else
                             now + delays.max
                           end
        elsif !delays.empty?
          state.reset_at = now + delays.max
        end
      end
    end

    def release(key:, lease_token:)
      @mutex.synchronize do
        state = @states[key]
        return unless state && state.lease_token.equal?(lease_token)

        state.lease_token = nil
      end
    end

    def state_for(key)
      @states[key] ||= State.new
    end

    def reset_expired_state(state, now)
      return unless state.reset_at && state.reset_at <= now

      state.remaining = nil
      state.reset_at = nil
    end

    def parse_metadata(metadata)
      return {} unless metadata.respond_to?(:to_h)

      headers = metadata.to_h.each_with_object({}) do |(key, value), result|
        case key.to_s.downcase.tr("_", "-")
        when "x-ratelimit-used", "ratelimit-used"
          result["x-ratelimit-used"] = value
        when "x-ratelimit-remaining", "ratelimit-remaining"
          result["x-ratelimit-remaining"] = value
        when "x-ratelimit-reset", "ratelimit-reset", "ratelimit-reset-seconds"
          result["x-ratelimit-reset"] = value
        when "retry-after", "retry-after-seconds"
          result["retry-after"] = value
        end
      end
      RateLimitHeaders.parse(headers)
    rescue ArgumentError, TypeError
      {}
    end

    def wait_outside_mutex(wait_seconds, operation)
      now = monotonic_now
      raise_rate_limited(operation) unless wait_seconds && wait_seconds.positive? && now + wait_seconds > now

      @sleeper.call(wait_seconds)
    rescue RedditApiError
      raise
    rescue StandardError
      raise_rate_limited(operation)
    end

    def raise_rate_limited(operation)
      raise RedditApiError.new(operation: operation, category: :rate_limited)
    end

    def normalize_deadline(value)
      deadline = Float(value)
      raise ArgumentError, "deadline_monotonic must be finite" unless deadline.finite?

      deadline
    rescue ArgumentError, TypeError
      raise ArgumentError, "deadline_monotonic must be finite"
    end

    def normalize_operation(value)
      operation = value.to_sym
      return operation if RedditApiError::OPERATIONS.include?(operation)

      raise ArgumentError, "unsupported Reddit API operation"
    rescue NoMethodError
      raise ArgumentError, "unsupported Reddit API operation"
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
end
