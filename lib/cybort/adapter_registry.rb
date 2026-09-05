module Cybort
  class AdapterRegistry
    Entry = Struct.new(:factory, :dependencies, :validator, keyword_init: true)

    def self.default
      new.tap do |registry|
        registry.register("rss", Adapters::RSS)
        registry.register("github", Adapters::GitHub)
        registry.register("reddit", Adapters::Reddit)
        registry.register(
          "gmail",
          Adapters::Gmail,
          dependencies: [
            Dependency.new(
              executable: "gws",
              purpose: "Google-maintained Google Workspace CLI",
              install_hint: "brew install googleworkspace-cli",
              auth_hint: "Run gws auth setup, then gws auth login --scopes https://www.googleapis.com/auth/gmail.readonly",
              version_requirement: ">= 0.22.5, < 0.23.0",
              environment_keys: %w[
                GOOGLE_WORKSPACE_CLI_CONFIG_DIR
                GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE
                GOOGLE_WORKSPACE_CLI_TOKEN
                GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND
                GOOGLE_WORKSPACE_PROJECT_ID
                HTTPS_PROXY HTTP_PROXY NO_PROXY SSL_CERT_FILE SSL_CERT_DIR
              ]
            )
          ]
        )
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
      errors = instances.keys.sort.filter_map do |id|
        instance = instances.fetch(id)
        "#{id}: unknown adapter: #{instance.adapter}" unless @adapters.key?(instance.adapter)
      end
      raise ConfigurationError, errors.join("\n") unless errors.empty?
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

    def plan(instance:, context:, force_fetch:, planned_at:)
      entry = @adapters.fetch(instance.adapter) do
        raise ConfigurationError, "unknown adapter: #{instance.adapter}"
      end
      factory = entry.factory
      if factory.respond_to?(:plan)
        factory.plan(instance: instance, context: context, force_fetch: force_fetch, planned_at: planned_at)
      else
        Adapters::Base.plan(instance: instance, context: context, force_fetch: force_fetch, planned_at: planned_at)
      end
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
        entry.factory.new(**compatible_keywords(entry.factory, kwargs))
      else
        entry.factory.call(**compatible_keywords(entry.factory, kwargs))
      end
    end

    private

    def compatible_keywords(factory, kwargs)
      parameters = if factory.is_a?(Class)
        factory.instance_method(:initialize).parameters
      else
        factory.parameters
      end
      return kwargs if parameters.any? { |kind, _name| kind == :keyrest }

      accepted = parameters.select { |kind, _name| %i[key keyreq].include?(kind) }.map(&:last)
      kwargs.select { |key, _value| accepted.include?(key) }
    end
  end
end
