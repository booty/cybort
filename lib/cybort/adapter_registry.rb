module Cybort
  class AdapterRegistry
    RESULT_KINDS = %i[items time_series].freeze
    Entry = Struct.new(:factory, :dependencies, :validator, :display_name, :item_noun, :result_kind, keyword_init: true)

    def self.default
      new.tap do |registry|
        registry.register("rss", Adapters::RSS, display_name: "RSS", item_noun: "articles")
        registry.register("github", Adapters::GitHub, display_name: "GitHub", item_noun: "notifications")
        registry.register("reddit", Adapters::Reddit, display_name: "Reddit", item_noun: "items")
        registry.register("reddit_rss", Adapters::RedditRSS, display_name: "Reddit RSS", item_noun: "posts")
        registry.register("gmail", Adapters::Gmail, display_name: "Gmail", item_noun: "messages")
      end
    end

    def initialize
      @adapters = {}
    end

    def register(name, adapter_factory, dependencies: [], validate_configuration: nil,
                 display_name: nil, item_noun: "items", result_kind: :items)
      raise ArgumentError, "invalid adapter result kind" unless RESULT_KINDS.include?(result_kind)
      if result_kind == :time_series && !accepts_keyword?(adapter_factory, :spool_factory)
        raise ArgumentError, "time-series adapter factory must accept spool_factory keyword"
      end
      validator = validate_configuration || if adapter_factory.respond_to?(:validate_configuration!)
        ->(instance) { adapter_factory.validate_configuration!(instance) }
      end
      @adapters[name.to_s] = Entry.new(
        factory: adapter_factory,
        dependencies: Array(dependencies).freeze,
        validator: validator || ->(_instance) {},
        display_name: display_name,
        item_noun: item_noun,
        result_kind: result_kind
      )
    end

    def display_name_for(instance)
      @adapters.fetch(instance.adapter).display_name || instance.adapter
    end

    def item_noun_for(instance)
      @adapters.fetch(instance.adapter).item_noun || "items"
    end

    def result_kind_for(instance)
      @adapters.fetch(instance.adapter) { raise ConfigurationError, "unknown adapter: #{instance.adapter}" }.result_kind
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

    def build(instance:, context:, http_client:, clock:, command_runner: nil, dependency_resolutions: {}, monotonic_clock: nil, spool_factory: nil)
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
      kwargs[:spool_factory] = spool_factory if entry.result_kind == :time_series
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

    def accepts_keyword?(factory, keyword)
      parameters = if factory.is_a?(Class)
        factory.instance_method(:initialize).parameters
      else
        factory.parameters
      end
      parameters.any? { |kind, name| kind == :keyrest || (%i[key keyreq].include?(kind) && name == keyword) }
    end
  end
end
