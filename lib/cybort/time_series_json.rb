require "json"

module Cybort
  module TimeSeriesJSON
    DIMENSION_LIMITS = {
      encoded_bytes: 16 * 1024, depth: 1, entries: 32,
      key_bytes: 128, string_bytes: 512
    }.freeze
    METADATA_LIMITS = {
      encoded_bytes: 64 * 1024, depth: 8, entries: 256,
      key_bytes: 128, string_bytes: 4 * 1024
    }.freeze

    module_function

    def validate_dimensions!(value)
      validate_object!(value, limits: DIMENSION_LIMITS, flat: true)
    end

    def validate_metadata!(value)
      validate_object!(value, limits: METADATA_LIMITS, flat: false)
    end

    def validate_object!(value, limits:, flat:)
      unless value.is_a?(Hash)
        raise ArgumentError, "time-series JSON value must be an object"
      end

      copy = validate_node(value, limits: limits, depth: 0, flat: flat)
      encoded = JSON.generate(copy)
      if encoded.bytesize > limits.fetch(:encoded_bytes)
        raise ArgumentError, "time-series JSON exceeds encoded byte limit"
      end

      deep_freeze(copy)
    end

    def validate_node(value, limits:, depth:, flat:)
      case value
      when Hash
        if depth >= limits.fetch(:depth)
          raise ArgumentError, "time-series JSON exceeds depth limit"
        end
        if value.length > limits.fetch(:entries)
          raise ArgumentError, "time-series JSON exceeds collection-size limit"
        end

        value.each_with_object({}) do |(key, child), copy|
          unless key.is_a?(String)
            raise ArgumentError, "time-series JSON object keys must be strings"
          end
          normalized_key = utf8_copy(key)
          check_string!(normalized_key, limits.fetch(:key_bytes), "object key")
          if flat && !scalar?(child)
            raise ArgumentError, "time-series dimensions must contain scalar values"
          end
          copy[normalized_key] = validate_node(child, limits: limits, depth: depth + 1, flat: flat)
        end
      when Array
        if flat
          raise ArgumentError, "time-series dimensions must contain scalar values"
        end
        if depth >= limits.fetch(:depth)
          raise ArgumentError, "time-series JSON exceeds depth limit"
        end
        if value.length > limits.fetch(:entries)
          raise ArgumentError, "time-series JSON exceeds collection-size limit"
        end
        value.map { |child| validate_node(child, limits: limits, depth: depth + 1, flat: false) }
      when String
        normalized = utf8_copy(value)
        check_string!(normalized, limits.fetch(:string_bytes), "string value")
        normalized
      when Integer, TrueClass, FalseClass, NilClass
        value
      when Float
        raise ArgumentError, "time-series JSON floats must be finite" unless value.finite?
        value
      else
        raise ArgumentError, "unsupported time-series JSON value"
      end
    end

    def scalar?(value)
      value.is_a?(String) || value.is_a?(Integer) || value.is_a?(Float) ||
        value == true || value == false
    end

    def check_string!(value, limit, label)
      raise ArgumentError, "time-series JSON #{label} is not valid UTF-8" unless value.encoding == Encoding::UTF_8 && value.valid_encoding?
      raise ArgumentError, "time-series JSON #{label} exceeds byte limit" if value.bytesize > limit
    end

    def utf8_copy(value)
      copy = value.dup
      copy.force_encoding(Encoding::UTF_8)
      copy
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
