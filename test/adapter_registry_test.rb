require "test_helper"

class AdapterRegistryTest < Minitest::Test
  Instance = Struct.new(:adapter, keyword_init: true)

  def test_registers_factory_dependencies_and_side_effect_free_validator
    calls = []
    dependency = Cybort::Dependency.new(executable: "tool", purpose: "test tool")
    registry = Cybort::AdapterRegistry.new
    registry.register(
      "fake",
      ->(**_kwargs) { Object.new },
      dependencies: [dependency],
      validate_configuration: ->(instance) { calls << instance.adapter }
    )

    instance = Instance.new(adapter: "fake")
    registry.validate_configuration!(instance)

    assert_equal ["fake"], calls
    assert_equal [dependency], registry.dependencies_for(instance)
  end

  def test_aggregates_configuration_errors_in_instance_order
    registry = Cybort::AdapterRegistry.new
    registry.register("fake", ->(**_kwargs) { Object.new }, validate_configuration: lambda do |instance|
      raise Cybort::ConfigurationError, "#{instance.adapter} invalid"
    end)
    instances = {
      "z" => Instance.new(adapter: "fake"),
      "a" => Instance.new(adapter: "fake")
    }

    error = assert_raises(Cybort::ConfigurationError) { registry.validate_configuration!(instances) }

    assert_equal "a: fake invalid\nz: fake invalid", error.message
  end

  def test_builtin_source_validation_is_side_effect_free
    registry = Cybort::AdapterRegistry.default
    rss = Cybort::Configuration::Instance.new(
      id: "rss", name: "RSS", adapter: "rss", ttl_minutes: 30,
      num_items_to_fetch: 1, options: { url: "not-a-url" }
    )
    github = Cybort::Configuration::Instance.new(
      id: "github", name: "GitHub", adapter: "github", ttl_minutes: 30,
      num_items_to_fetch: 1, options: { token: "", api_url: "https://api.example.test" }
    )

    error = assert_raises(Cybort::ConfigurationError) do
      registry.validate_configuration!({ "github" => github, "rss" => rss })
    end

    assert_equal "github: github instance requires token\nrss: rss instance requires an HTTP(S) url", error.message
  end

  def test_legacy_callable_factory_receives_only_legacy_keywords
    registry = Cybort::AdapterRegistry.new
    factory = lambda do |instance:, context:, http_client:, clock:|
      [instance, context, http_client, clock]
    end
    registry.register("legacy", factory)
    instance = Instance.new(adapter: "legacy")

    result = registry.build(instance: instance, context: {}, http_client: nil, clock: -> {})

    assert_equal instance, result.fetch(0)
  end

  def test_aggregates_unknown_and_known_invalid_adapters_independently_of_hash_order
    registry = Cybort::AdapterRegistry.new
    registry.register("known", ->(**_kwargs) { Object.new }, validate_configuration: ->(_instance) {
      raise Cybort::ConfigurationError, "invalid options"
    })
    instances = {
      "z_unknown" => Instance.new(adapter: "missing"),
      "a_known" => Instance.new(adapter: "known")
    }

    error = assert_raises(Cybort::ConfigurationError) { registry.validate_configuration!(instances) }

    assert_equal "a_known: invalid options\nz_unknown: unknown adapter: missing", error.message
  end
end
