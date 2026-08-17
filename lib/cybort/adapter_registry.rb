module Cybort
  class AdapterRegistry
    def self.default
      new.tap { |registry| registry.register("rss", Adapters::RSS) }
    end

    def initialize
      @adapters = {}
    end

    def register(name, adapter_factory)
      @adapters[name.to_s] = adapter_factory
    end

    def validate!(instances)
      instances.each_value do |instance|
        next if @adapters.key?(instance.adapter)

        raise ConfigurationError, "unknown adapter: #{instance.adapter}"
      end
    end

    def build(instance:, context:, http_client:, clock:)
      factory = @adapters.fetch(instance.adapter) do
        raise ConfigurationError, "unknown adapter: #{instance.adapter}"
      end
      if factory.respond_to?(:new)
        factory.new(instance: instance, context: context, http_client: http_client, clock: clock)
      else
        factory.call(instance: instance, context: context, http_client: http_client, clock: clock)
      end
    end
  end
end

