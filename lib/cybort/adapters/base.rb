module Cybort
  module Adapters
    class Base
      attr_reader :instance, :context, :http_client, :clock

      def initialize(instance:, context:, http_client:, clock: -> { Time.now.utc })
        @instance = instance
        @context = context
        @http_client = http_client
        @clock = clock
      end

      def fetch(force_fetch: false)
        started_at = clock.call
        if !force_fetch && fresh_cache?
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
          finished_at: clock.call
        )
      end

      private

      def fresh_cache?
        fetched_at = context[:last_successful_fetch]
        fetched_at && (clock.call - fetched_at) < (instance.ttl_minutes * 60)
      end

      def fetch_from_source
        raise NotImplementedError, "#{self.class} must implement #fetch_from_source"
      end
    end
  end
end

