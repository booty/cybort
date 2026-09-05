module Cybort
  FetchResult = Struct.new(
    :instance_id,
    :items,
    :sync_state,
    :started_at,
    :finished_at,
    :metadata,
    :source_fetched,
    :replace_existing_items,
    :error,
    keyword_init: true
  ) do
    def initialize(**attributes)
      replacement = attributes.fetch(:replace_existing_items, false)
      unless replacement == true || replacement == false
        raise ArgumentError, "replace_existing_items must be true or false"
      end
      if replacement && attributes[:error]
        raise ArgumentError, "failed results cannot replace existing items"
      end

      super(**attributes.merge(replace_existing_items: replacement))
    end

    def self.success(instance_id:, items:, sync_state:, started_at:, finished_at:, metadata: {}, source_fetched:,
                     replace_existing_items: false)
      new(
        instance_id: instance_id,
        items: items,
        sync_state: sync_state,
        started_at: started_at,
        finished_at: finished_at,
        metadata: metadata,
        source_fetched: source_fetched,
        replace_existing_items: replace_existing_items,
        error: nil
      )
    end

    def self.failure(instance_id:, error:, started_at:, finished_at:, metadata: {})
      new(
        instance_id: instance_id,
        items: [],
        sync_state: nil,
        started_at: started_at,
        finished_at: finished_at,
        metadata: metadata,
        source_fetched: false,
        replace_existing_items: false,
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
