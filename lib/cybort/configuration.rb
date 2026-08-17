require "tomlrb"

module Cybort
  class Configuration
    Instance = Struct.new(
      :id,
      :name,
      :adapter,
      :ttl_minutes,
      :num_items_to_fetch,
      :options,
      keyword_init: true
    )

    REQUIRED_INSTANCE_KEYS = %i[name adapter ttl_minutes num_items_to_fetch].freeze

    attr_reader :schema_version, :instances

    def self.load(path)
      data = Tomlrb.load_file(path, symbolize_keys: true)
      new(data)
    rescue KeyError => error
      raise ConfigurationError, "missing configuration key: #{error.key}"
    rescue Tomlrb::ParseError => error
      raise ConfigurationError, "invalid TOML: #{error.message}"
    end

    def initialize(data)
      @schema_version = data.fetch(:schema_version) do
        raise ConfigurationError, "missing configuration key: schema_version"
      end
      raise ConfigurationError, "unsupported schema_version: #{@schema_version}" unless @schema_version == 1

      raw_instances = data.fetch(:instances) do
        raise ConfigurationError, "missing configuration key: instances"
      end
      raise ConfigurationError, "instances must be a table" unless raw_instances.is_a?(Hash)

      @instances = raw_instances.to_h do |id, raw|
        [id.to_s, build_instance(id.to_s, raw)]
      end
    end

    private

    def build_instance(id, raw)
      REQUIRED_INSTANCE_KEYS.each do |key|
        raise ConfigurationError, "instance #{id} missing key: #{key}" unless raw.key?(key)
      end

      ttl_minutes = raw.fetch(:ttl_minutes)
      num_items_to_fetch = raw.fetch(:num_items_to_fetch)
      unless ttl_minutes.is_a?(Numeric) && ttl_minutes.positive?
        raise ConfigurationError, "instance #{id} ttl_minutes must be positive"
      end
      unless num_items_to_fetch.is_a?(Integer) && num_items_to_fetch.positive?
        raise ConfigurationError, "instance #{id} num_items_to_fetch must be a positive integer"
      end

      options = raw.reject { |key, _value| REQUIRED_INSTANCE_KEYS.include?(key) }
      Instance.new(
        id: id,
        name: raw.fetch(:name).to_s,
        adapter: raw.fetch(:adapter).to_s,
        ttl_minutes: ttl_minutes,
        num_items_to_fetch: num_items_to_fetch,
        options: options
      )
    end
  end
end

