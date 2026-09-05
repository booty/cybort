module Cybort
  module RateLimitHeaders
    RATE_HEADER_NAMES = {
      "x-ratelimit-used" => :ratelimit_used,
      "x-ratelimit-remaining" => :ratelimit_remaining,
      "x-ratelimit-reset" => :ratelimit_reset_seconds
    }.freeze

    RETRY_AFTER_HEADER = "retry-after"
    DECIMAL_PATTERN = /\A(?:\d+(?:\.\d*)?|\.\d+)\z/.freeze
    INTEGER_PATTERN = /\A\d+\z/.freeze

    module_function

    def parse(headers)
      normalized = {}
      source = headers.respond_to?(:to_h) ? headers.to_h : {}
      source.each { |key, value| normalized[key.to_s.downcase.tr("_", "-")] = value }
      parsed = {}

      RATE_HEADER_NAMES.each do |header_name, metadata_key|
        canonical_name = metadata_key.to_s.tr("_", "-")
        value = parse_nonnegative_float(
          normalized[header_name] || normalized[header_name.delete_prefix("x-")] || normalized[canonical_name]
        )
        parsed[metadata_key] = value unless value.nil?
      end

      retry_after = normalized[RETRY_AFTER_HEADER] || normalized["retry-after-seconds"]
      if retry_after.is_a?(Integer) && retry_after >= 0
        parsed[:retry_after_seconds] = retry_after
      elsif retry_after.is_a?(String) && retry_after.match?(INTEGER_PATTERN)
        parsed[:retry_after_seconds] = retry_after.to_i
      end

      parsed.freeze
    end

    def parse_nonnegative_float(value)
      return unless value.is_a?(Numeric) || value.is_a?(String)

      numeric = if value.is_a?(Numeric)
                  Float(value)
                elsif value.match?(DECIMAL_PATTERN)
                  Float(value)
                end
      return unless numeric&.finite? && numeric >= 0

      numeric
    rescue ArgumentError, TypeError
      nil
    end
    private_class_method :parse_nonnegative_float
  end
end
