module Cybort
  class CommandError < SourceError
    ALLOWED_METADATA = %i[
      tool operation command_index exit_category exit_code tool_version category
    ].freeze
    MAX_STRING_BYTES = 256

    attr_reader :safe_metadata

    def initialize(message, metadata: {})
      message = message.to_s
      unless message.bytesize <= MAX_STRING_BYTES && message.each_codepoint.none?(&:zero?) && message !~ /[\x00-\x1F\x7F]/
        raise ArgumentError, "command error message must be short and printable"
      end

      @safe_metadata = normalize_metadata(metadata).freeze
      super(message)
    end

    private

    def normalize_metadata(metadata)
      raise ArgumentError, "command error metadata must be a hash" unless metadata.is_a?(Hash)

      metadata.each_with_object({}) do |(key, value), result|
        key = key.to_sym
        raise ArgumentError, "unsupported command error metadata: #{key}" unless ALLOWED_METADATA.include?(key)
        unless value.nil? || value.is_a?(String) || value.is_a?(Integer) || value == true || value == false
          raise ArgumentError, "command error metadata must contain scalar values"
        end
        if value.is_a?(String) && value.bytesize > MAX_STRING_BYTES
          raise ArgumentError, "command error metadata value is too long"
        end

        result[key] = value
      end
    end
  end
end
