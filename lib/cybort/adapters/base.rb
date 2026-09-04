module Cybort
  AdapterPlan = Struct.new(
    :instance, :context, :fetch_mode, :planned_at, :dependency_requirements,
    :resolutions, keyword_init: true
  ) do
    def initialize(**attributes)
      super
      self.context = context.dup.freeze
      self.dependency_requirements = Array(dependency_requirements).dup.freeze
      self.resolutions = (resolutions || {}).dup.freeze
      freeze
    end

    def with(**attributes)
      self.class.new(**to_h.merge(attributes))
    end
  end

  module Adapters
    class Base
      attr_reader :instance, :context, :http_client, :clock, :command_runner,
                  :dependency_resolutions, :monotonic_clock

      def initialize(instance:, context:, http_client:, clock: -> { Time.now.utc }, command_runner: nil,
                     dependency_resolutions: {}, monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @instance = instance
        @context = context
        @http_client = http_client
        @clock = clock
        @command_runner = command_runner
        @dependency_resolutions = dependency_resolutions
        @monotonic_clock = monotonic_clock
      end

      def dependency_resolutions=(resolutions)
        @dependency_resolutions = (resolutions || {}).dup.freeze
      end

      def plan(force_fetch:, planned_at:)
        mode = force_fetch || !fresh_cache_at?(planned_at) ? :remote : :cached
        AdapterPlan.new(
          instance: instance,
          context: context,
          fetch_mode: mode,
          planned_at: planned_at,
          dependency_requirements: [],
          resolutions: {}
        )
      end

      def fetch(force_fetch: false, fetch_mode: nil, planned_at: nil)
        planned_at ||= clock.call
        fetch_mode ||= force_fetch || !fresh_cache_at?(planned_at) ? :remote : :cached
        started_at = clock.call
        if fetch_mode == :cached
          return FetchResult.success(
            instance_id: instance.id,
            items: context.fetch(:items, []),
            sync_state: context[:sync_state],
            started_at: started_at,
            finished_at: clock.call,
            source_fetched: false
          )
        end

        fetched = fetch_from_source
        FetchResult.success(
          instance_id: instance.id,
          items: fetched.fetch(:items),
          sync_state: fetched[:sync_state],
          started_at: started_at,
          finished_at: clock.call,
          metadata: fetched.fetch(:metadata, {}),
          source_fetched: true
        )
      rescue StandardError => error
        FetchResult.failure(
          instance_id: instance.id,
          error: error,
          started_at: started_at || clock.call,
          finished_at: clock.call,
          metadata: error.respond_to?(:safe_metadata) ? error.safe_metadata : {}
        )
      end

      private

      def fresh_cache_at?(at)
        fetched_at = context[:last_successful_fetch]
        fetched_at && (at - fetched_at) < (instance.ttl_minutes * 60)
      end

      def fetch_from_source
        raise NotImplementedError, "#{self.class} must implement #fetch_from_source"
      end
    end
  end
end
