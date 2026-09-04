module Cybort
  class AdapterRegistry
    Entry = Struct.new(:factory, :dependencies, :validator, keyword_init: true)

    def self.default
      new.tap do |registry|
        registry.register("rss", Adapters::RSS)
        registry.register("github", Adapters::GitHub)
      end
    end

    def initialize
      @adapters = {}
    end

    def register(name, adapter_factory, dependencies: [], validate_configuration: nil)
      validator = validate_configuration || if adapter_factory.respond_to?(:validate_configuration!)
        ->(instance) { adapter_factory.validate_configuration!(instance) }
      end
      @adapters[name.to_s] = Entry.new(
        factory: adapter_factory,
        dependencies: Array(dependencies).freeze,
        validator: validator || ->(_instance) {}
      )
    end

    def validate!(instances)
      instances.each_value do |instance|
        next if @adapters.key?(instance.adapter)

        raise ConfigurationError, "unknown adapter: #{instance.adapter}"
      end
    end

    def validate_configuration!(instances)
      if instances.respond_to?(:each_value)
        errors = instances.keys.sort.each_with_object([]) do |id, messages|
          begin
            validate_configuration!(instances.fetch(id))
          rescue ConfigurationError => error
            messages << "#{id}: #{error.message}"
          end
        end
        raise ConfigurationError, errors.join("\n") unless errors.empty?
        return
      end

      entry = @adapters.fetch(instances.adapter) do
        raise ConfigurationError, "unknown adapter: #{instances.adapter}"
      end
      entry.validator.call(instances)
    end

    def dependencies_for(instance)
      @adapters.fetch(instance.adapter) do
        raise ConfigurationError, "unknown adapter: #{instance.adapter}"
      end.dependencies
    end

    def build(instance:, context:, http_client:, clock:, command_runner: nil, dependency_resolutions: {}, monotonic_clock: nil)
      entry = @adapters.fetch(instance.adapter) do
        raise ConfigurationError, "unknown adapter: #{instance.adapter}"
      end
      kwargs = {
        instance: instance,
        context: context,
        http_client: http_client,
        clock: clock,
        command_runner: command_runner,
        dependency_resolutions: dependency_resolutions
      }
      kwargs[:monotonic_clock] = monotonic_clock if monotonic_clock
      if entry.factory.respond_to?(:new)
        entry.factory.new(**kwargs)
      else
        entry.factory.call(**kwargs)
      end
    end
  end
end
