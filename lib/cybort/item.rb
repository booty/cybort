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
      unless action_item.nil? || action_item == true || action_item == false
        raise ValidationError, "item action_item must be true, false, or nil"
      end

      @instance_id = instance_id.to_s
      @canonical_id = canonical_id.to_s
      @urls = urls.map(&:to_s).freeze
      @fetched_at = fetched_at
      @remote_created_at = remote_created_at
      @title = title.to_s
      @body = body
      @priority = priority
      @action_item = action_item
      @info = deep_freeze(deep_dup(info))
    end

    def to_h
      {
        instance_id: instance_id,
        canonical_id: canonical_id,
        urls: urls.dup,
        fetched_at: fetched_at.utc.iso8601(6),
        remote_created_at: remote_created_at&.utc&.iso8601(6),
        title: title,
        body: body,
        priority: priority,
        action_item: action_item,
        info: deep_dup(info)
      }
    end

    private

    def deep_dup(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, child), copy| copy[deep_dup(key)] = deep_dup(child) }
      when Array
        value.map { |child| deep_dup(child) }
      when String
        value.dup
      else
        value
      end
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each { |key, child| deep_freeze(key); deep_freeze(child) }
      when Array
        value.each { |child| deep_freeze(child) }
      end
      value.freeze
    end
  end
end
