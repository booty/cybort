module Cybort
  class Item
    ATTRIBUTES = %i[
      instance_id canonical_id urls fetched_at remote_created_at title body
      priority action_item info
    ].freeze

    attr_reader(*ATTRIBUTES)

    def initialize(instance_id: nil, canonical_id: nil, urls: [], fetched_at: nil,
                   remote_created_at: nil, title: nil, body: nil, priority: nil,
                   action_item: nil, info: {})
      required = {
        instance_id: instance_id,
        canonical_id: canonical_id,
        fetched_at: fetched_at,
        title: title
      }
      missing = required.select { |_key, value| value.nil? || value.to_s.empty? }.keys
      raise ValidationError, "item missing required fields: #{missing.join(", ")}" unless missing.empty?
      if !priority.nil? && (!priority.is_a?(Integer) || !priority.between?(0, 100))
        raise ValidationError, "item priority must be an integer from 0 through 100"
      end
      raise ValidationError, "item urls must be an array" unless urls.is_a?(Array)
      raise ValidationError, "item info must be a hash" unless info.is_a?(Hash)

      @instance_id = instance_id.to_s
      @canonical_id = canonical_id.to_s
      @urls = urls.map(&:to_s)
      @fetched_at = fetched_at
      @remote_created_at = remote_created_at
      @title = title.to_s
      @body = body
      @priority = priority
      @action_item = action_item
      @info = info
    end
  end
end

