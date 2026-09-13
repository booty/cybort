require "bigdecimal"
require "digest"
require "time"

module Cybort
  AppleHealthTimestamp = Data.define(:time, :utc_microseconds, :offset_minutes)
  AppleHealthDecimal = Data.define(:numeric_value, :identity)
  AppleHealthNormalizedRecord = Data.define(
    :series_key, :metric_key, :value_type, :canonical_unit, :dimensions,
    :source_record_key, :observed_at, :ended_at, :numeric_value,
    :categorical_value, :metadata
  )

  module AppleHealthCanonical
    InvalidTimestampError = Class.new(ArgumentError)
    MAX_DECIMAL_BYTES = 4_096
    MAX_DECIMAL_EXPONENT = 100_000
    MAX_STRING_BYTES = 4_096
    TIMESTAMP_PATTERN = /\A(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?\s*(Z|[+-]\d{2}:?\d{2})\z/.freeze
    DECIMAL_PATTERN = /\A[+-]?(?:(?:\d+(?:\.\d*)?)|(?:\.\d+))(?:[eE][+-]?\d+)?\z/.freeze

    module_function

    def parse_timestamp(value, field:)
      text = normalized_string(value, field.to_s, MAX_STRING_BYTES)
      match = TIMESTAMP_PATTERN.match(text)
      raise ArgumentError, "invalid #{field}" unless match

      year, month, day, hour, minute, second = match.captures.first(6).map(&:to_i)
      raise InvalidTimestampError, "invalid #{field}" if hour >= 24 || minute >= 60 || second >= 60
      fraction = match[7].to_s
      nanoseconds = fraction.empty? ? 0 : fraction.ljust(9, "0").to_i
      offset = match[8]
      offset_minutes = if offset == "Z"
                         0
                       else
                         sign = offset.start_with?("-") ? -1 : 1
                         hours, minutes = offset.delete_prefix("+").delete_prefix("-").split(":").then do |parts|
                           parts.length == 1 ? [parts.fetch(0)[0, 2], parts.fetch(0)[2, 2]] : parts
                         end
                         hours = hours.to_i
                         minutes = minutes.to_i
                         raise ArgumentError, "invalid #{field}" if hours >= 24 || minutes >= 60
                         sign * (hours * 60 + minutes)
                       end
      local = Time.new(year, month, day, hour, minute,
                       second + Rational(nanoseconds, 1_000_000_000), offset_minutes * 60)
      utc = local.getutc
      AppleHealthTimestamp.new(
        time: local,
        utc_microseconds: (utc.to_r * 1_000_000).floor,
        offset_minutes: offset_minutes
      )
    rescue ArgumentError, RangeError
      raise InvalidTimestampError, "invalid #{field}"
    end

    def parse_decimal(value)
      text = normalized_string(value, "decimal", MAX_DECIMAL_BYTES)
      raise ArgumentError, "invalid decimal" unless DECIMAL_PATTERN.match?(text)

      exponent_match = text.match(/[eE]([+-]?\d+)\z/)
      if exponent_match && exponent_match[1].to_i.abs > MAX_DECIMAL_EXPONENT
        raise ArgumentError, "decimal exponent is too large"
      end
      decimal = BigDecimal(text)
      sign, digits, _base, exponent = decimal.split
      sign = 0 if digits.delete("0").empty?
      numeric_value = decimal.to_f
      raise ArgumentError, "decimal is not finite" unless numeric_value.finite?
      identity = "#{sign}:#{digits}:#{exponent}".freeze
      AppleHealthDecimal.new(numeric_value: numeric_value, identity: identity)
    rescue ArgumentError, FloatDomainError
      raise ArgumentError, "invalid decimal"
    end

    def series_definition(attributes = nil, **keywords)
      attributes = (attributes || {}).merge(keywords)
      type = normalized_string(attributes[:type] || attributes["type"], "type", 256)
      raw_value_type = attributes[:value_type] || attributes["value_type"]
      value_type = raw_value_type.to_sym if raw_value_type.respond_to?(:to_sym)
      raise ArgumentError, "invalid value type" unless %i[numeric categorical].include?(value_type)
      unit_value = attributes.key?(:canonical_unit) ? attributes[:canonical_unit] : attributes["canonical_unit"]
      unit_value = attributes[:unit] if !attributes.key?(:canonical_unit) && attributes.key?(:unit)
      canonical_unit = unit_value.nil? ? nil : normalized_string(unit_value, "unit", 256)
      raise ArgumentError, "categorical values cannot have a unit" if value_type == :categorical && canonical_unit
      raise ArgumentError, "numeric values require a unit" if value_type == :numeric && canonical_unit.nil?

      dimensions = { "record_family" => "record", "apple_type" => type }.freeze
      fields = [["record", "record"], ["type", type], ["value_type", value_type.to_s], ["unit", canonical_unit]]
      {
        series_key: digest_key("apple-health-record-v1:", fields),
        metric_key: type,
        value_type: value_type,
        canonical_unit: canonical_unit,
        dimensions: dimensions
      }.freeze
    end

    def normalize_record(attributes:, metadata_entries:)
      attrs = normalize_attributes(attributes)
      type = normalized_string(attrs.fetch("type"), "type", 256)
      value_type = attrs.fetch("value_type").to_sym
      canonical_unit = attrs["unit"]
      definition = series_definition(type: type, value_type: value_type, canonical_unit: canonical_unit)
      creation = parse_timestamp(attrs.fetch("creationDate"), field: :creation_date)
      observed = parse_timestamp(attrs.fetch("startDate"), field: :start_date)
      ended = attrs["endDate"] && parse_timestamp(attrs["endDate"], field: :end_date)
      raise ArgumentError, "end precedes start" if ended && ended.utc_microseconds < observed.utc_microseconds

      decimal = nil
      categorical = nil
      value = attrs.fetch("value")
      if value_type == :numeric
        decimal = parse_decimal(value)
      else
        categorical = normalized_string(value, "category value", 1_024)
      end
      metadata = normalize_metadata(metadata_entries)
      stored_metadata = metadata.fetch(:stored).merge(
        "start_offset_minutes" => observed.offset_minutes,
        "creation_offset_minutes" => creation.offset_minutes
      )
      stored_metadata["end_offset_minutes"] = ended.offset_minutes if ended
      stored_metadata.freeze
      identity_fields = [
        ["record", "record"], ["type", type], ["value_type", value_type.to_s],
        ["unit", canonical_unit], ["creation", timestamp_identity(creation)],
        ["start", timestamp_identity(observed)], ["end", ended && timestamp_identity(ended)],
        ["value", decimal ? decimal.identity : categorical]
      ]
      %w[sourceName sourceVersion device].each do |key|
        identity_fields << [key, attrs[key]] if attrs.key?(key)
      end
      metadata.fetch(:identity_pairs).each_with_index do |pair, index|
        identity_fields << ["metadata_#{index}", "#{pair.fetch(0)}\u0000#{pair.fetch(1)}"]
      end
      AppleHealthNormalizedRecord.new(
        series_key: definition.fetch(:series_key), metric_key: definition.fetch(:metric_key),
        value_type: value_type, canonical_unit: canonical_unit, dimensions: definition.fetch(:dimensions),
        source_record_key: digest_key("apple-health-record-v1:", identity_fields),
        observed_at: observed.time, ended_at: ended&.time,
        numeric_value: decimal&.numeric_value, categorical_value: categorical,
        metadata: stored_metadata
      )
    end

    def encode_fields(fields)
      fields.sort_by(&:first).map do |tag, value|
        tag = normalized_string(tag, "identity tag", 256)
        bytes = value.nil? ? "".b : value.to_s.encode(Encoding::UTF_8).b
        [tag.bytesize].pack("N") + tag.b + [bytes.bytesize].pack("Q>") + bytes
      end.join.b
    end

    def digest_key(prefix, fields)
      "#{prefix}#{Digest::SHA256.hexdigest(encode_fields(fields))}"
    end

    def normalize_attributes(attributes)
      raise ArgumentError, "record attributes must be a hash" unless attributes.is_a?(Hash)
      attributes.each_with_object({}) do |(key, value), normalized|
        normalized[key.to_s] = value.is_a?(String) ? normalized_string(value, key.to_s, MAX_STRING_BYTES) : value
      end
    end

    def normalize_metadata(entries)
      raise ArgumentError, "metadata entries must be an array" unless entries.is_a?(Array)
      identity_pairs = []
      stored = {}
      entries.each do |entry|
        raise ArgumentError, "invalid metadata entry" unless entry.is_a?(Array) && entry.length == 2
        key = normalized_string(entry.fetch(0), "metadata key", 256)
        value = normalized_string(entry.fetch(1), "metadata value", 4_096)
        identity_value = value
        case key
        when "HKWasUserEntered"
          parsed = parse_boolean_metadata(value)
          raise ArgumentError, "conflicting metadata" if stored.key?("user_entered") && stored["user_entered"] != parsed
          stored["user_entered"] = parsed
          identity_value = parsed ? "true" : "false"
        when "HKMetadataKeySyncVersion"
          parsed = Integer(value, 10) rescue nil
          unless parsed && parsed.between?(0, 2_147_483_647)
            raise ArgumentError, "invalid synchronization version"
          end
          raise ArgumentError, "conflicting metadata" if stored.key?("synchronization_version") && stored["synchronization_version"] != parsed
          stored["synchronization_version"] = parsed
          identity_value = parsed.to_s
        end
        identity_pairs << [key, identity_value]
      end
      { identity_pairs: identity_pairs.sort.freeze, stored: stored.freeze }.freeze
    end

    def parse_boolean_metadata(value)
      case value
      when "true", "1" then true
      when "false", "0" then false
      else raise ArgumentError, "invalid boolean metadata"
      end
    end

    def timestamp_identity(timestamp)
      "#{timestamp.utc_microseconds}:#{timestamp.offset_minutes}"
    end

    def normalized_string(value, field, maximum_bytes)
      raise ArgumentError, "invalid #{field}" unless value.is_a?(String)
      copy = value.dup.force_encoding(Encoding::UTF_8)
      unless copy.valid_encoding? && !copy.empty? && !copy.strip.empty? &&
             copy.bytesize <= maximum_bytes && !copy.match?(/[\x00-\x1f\x7f]/)
        raise ArgumentError, "invalid #{field}"
      end
      copy.unicode_normalize(:nfc)
    end
  end
end
