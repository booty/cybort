module Cybort
  FetchResult = Struct.new(
    :instance_id,
    :items,
    :sync_state,
    :started_at,
    :finished_at,
    :metadata,
    :source_fetched,
    :error,
    keyword_init: true
  ) do
    def self.success(instance_id:, items:, sync_state:, started_at:, finished_at:, metadata: {}, source_fetched:)
      new(
        instance_id: instance_id,
        items: items,
        sync_state: sync_state,
        started_at: started_at,
        finished_at: finished_at,
        metadata: metadata,
        source_fetched: source_fetched,
        error: nil
      )
    end

    def self.failure(instance_id:, error:, started_at:, finished_at:)
      new(
        instance_id: instance_id,
        items: [],
        sync_state: nil,
        started_at: started_at,
        finished_at: finished_at,
        metadata: {},
        source_fetched: false,
        error: error
      )
    end

    def success?
      error.nil?
    end

    def failure?
      !success?
    end
  end
end

