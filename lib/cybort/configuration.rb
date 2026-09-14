require "tomlrb"

module Cybort
  class Configuration
    Instance = Struct.new(
      :id,
      :name,
      :adapter,
      :ttl_minutes,
      :retention_ttl_minutes,
      :hard_expiry_ttl_minutes,
      :num_items_to_fetch,
      :options,
      keyword_init: true
    )

    REQUIRED_INSTANCE_KEYS = %i[name adapter ttl_minutes num_items_to_fetch].freeze
    COMMON_INSTANCE_KEYS = (REQUIRED_INSTANCE_KEYS + %i[retention_ttl_minutes hard_expiry_ttl_minutes]).freeze
    INVALID_TOML_MESSAGE = "invalid TOML configuration"
    MAX_INSTANCE_ID_BYTES = 256
    MAX_INSTANCE_NAME_BYTES = 512
    MAX_ADAPTER_NAME_BYTES = 128
    UNSAFE_TEXT = /[\x00-\x1f\x7f]/
    PATH_SEPARATOR = %r{[/\\]}

    attr_reader :schema_version, :instances

    def self.load(path)
      data = Tomlrb.load_file(path, symbolize_keys: true)
      new(data)
    rescue KeyError => error
      raise ConfigurationError, "missing configuration key: #{error.key}"
    rescue Tomlrb::ParseError
      raise ConfigurationError, INVALID_TOML_MESSAGE
    end

    def initialize(data)
      raise ValidationError, "configuration must be a table" unless data.is_a?(Hash)

      @schema_version = data.fetch(:schema_version) do
        raise ConfigurationError, "missing configuration key: schema_version"
      end
      raise ConfigurationError, "unsupported schema_version: #{@schema_version}" unless @schema_version == 1

      raw_instances = data.fetch(:instances) do
        raise ConfigurationError, "missing configuration key: instances"
      end
      raise ValidationError, "instances must be a table" unless raw_instances.is_a?(Hash)

      @instances = raw_instances.each_with_object({}) do |(id, raw), instances|
        normalized_id = normalize_instance_id(id)
        raise ValidationError, "instance ids must be unique" if instances.key?(normalized_id)

        instances[normalized_id] = build_instance(normalized_id, raw)
      end
    end

    private

    def build_instance(id, raw)
      raise ValidationError, "instance table must be a table" unless raw.is_a?(Hash)

      REQUIRED_INSTANCE_KEYS.each do |key|
        raise ValidationError, "instance is missing key: #{key}" unless raw.key?(key)
      end

      ttl_minutes = raw.fetch(:ttl_minutes)
      num_items_to_fetch = raw.fetch(:num_items_to_fetch)
      unless finite_positive_number?(ttl_minutes)
        raise ValidationError, "instance ttl_minutes must be finite and positive"
      end
      unless num_items_to_fetch.is_a?(Integer) && num_items_to_fetch.positive?
        raise ValidationError, "instance num_items_to_fetch must be a positive integer"
      end
      retention_ttl_minutes = raw[:retention_ttl_minutes]
      unless retention_ttl_minutes.nil? ||
             finite_positive_integer?(retention_ttl_minutes)
        raise ValidationError, "instance retention_ttl_minutes must be a finite positive integer"
      end
      hard_expiry_ttl_minutes = raw[:hard_expiry_ttl_minutes]
      unless hard_expiry_ttl_minutes.nil? ||
             finite_positive_integer?(hard_expiry_ttl_minutes)
        raise ValidationError, "instance hard_expiry_ttl_minutes must be a finite positive integer"
      end

      name = normalize_text(raw.fetch(:name), :name, MAX_INSTANCE_NAME_BYTES, path_safe: true)
      adapter = normalize_text(raw.fetch(:adapter), :adapter, MAX_ADAPTER_NAME_BYTES, path_safe: true)

      options = raw.reject { |key, _value| COMMON_INSTANCE_KEYS.include?(key) }
      Instance.new(
        id: id,
        name: name,
        adapter: adapter,
        ttl_minutes: ttl_minutes,
        retention_ttl_minutes: retention_ttl_minutes,
        hard_expiry_ttl_minutes: hard_expiry_ttl_minutes,
        num_items_to_fetch: num_items_to_fetch,
        options: options
      )
    end

    def normalize_instance_id(value)
      normalized = if value.is_a?(String) || value.is_a?(Symbol)
                     value.to_s
                   end
      normalize_text(normalized, :id, MAX_INSTANCE_ID_BYTES, path_safe: true, reject_dot_segments: true)
    end

    def normalize_text(value, field, maximum_bytes, path_safe:, reject_dot_segments: false)
      unless value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1, maximum_bytes)
        raise ValidationError, "instance #{field} must be a bounded UTF-8 string"
      end
      if value.match?(UNSAFE_TEXT) || (path_safe && value.match?(PATH_SEPARATOR)) ||
         (reject_dot_segments && %w[. ..].include?(value))
        raise ValidationError, "instance #{field} contains unsafe characters"
      end

      value
    end

    def finite_positive_number?(value)
      value.is_a?(Numeric) && value.respond_to?(:finite?) && value.finite? && value.positive?
    end

    def finite_positive_integer?(value)
      value.is_a?(Integer) && value.positive?
    end
  end
end
