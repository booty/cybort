require "test_helper"

class ConfigurationTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/configuration/single_rss.toml", __dir__)

  def test_loads_stable_id_display_name_and_common_options
    configuration = Cybort::Configuration.load(FIXTURE)
    instance = configuration.instances.fetch("personal_rss")

    assert_equal "personal_rss", instance.id
    assert_equal "Personal RSS", instance.name
    assert_equal "rss", instance.adapter
    assert_equal 30, instance.ttl_minutes
    assert_nil instance.retention_ttl_minutes
    assert_equal 10, instance.num_items_to_fetch
    assert_equal "https://example.test/feed.xml", instance.options.fetch(:url)
  end

  def test_loads_optional_retention_ttl_minutes_as_common_configuration
    source = File.read(FIXTURE).sub(
      "ttl_minutes = 30\n",
      "ttl_minutes = 30\nretention_ttl_minutes = 2880\n"
    )

    Tempfile.create(["cybort-config", ".toml"]) do |file|
      file.write(source)
      file.flush
      instance = Cybort::Configuration.load(file.path).instances.fetch("personal_rss")

      assert_equal 2880, instance.retention_ttl_minutes
      refute instance.options.key?(:retention_ttl_minutes)
    end
  end

  def test_rejects_invalid_retention_ttl_minutes
    invalid_values = ["0", "-1", "1.5", '"48h"', "true"]

    invalid_values.each do |value|
      source = File.read(FIXTURE).sub(
        "ttl_minutes = 30\n",
        "ttl_minutes = 30\nretention_ttl_minutes = #{value}\n"
      )

      Tempfile.create(["cybort-config", ".toml"]) do |file|
        file.write(source)
        file.flush

        error = assert_raises(Cybort::ConfigurationError) do
          Cybort::Configuration.load(file.path)
        end
        assert_includes error.message, "retention_ttl_minutes"
      end
    end
  end

  def test_retention_is_independent_per_instance_and_may_be_shorter_than_cache_ttl
    fixture = File.expand_path("fixtures/configuration/rss_and_github.toml", __dir__)
    source = File.read(fixture).sub(
      "[instances.rss]\n",
      "[instances.rss]\nretention_ttl_minutes = 5\n"
    )

    Tempfile.create(["cybort-config", ".toml"]) do |file|
      file.write(source)
      file.flush
      instances = Cybort::Configuration.load(file.path).instances

      assert_equal 5, instances.fetch("rss").retention_ttl_minutes
      assert_nil instances.fetch("github").retention_ttl_minutes
    end
  end

  %i[schema_version adapter ttl_minutes num_items_to_fetch].each do |missing_key|
    define_method("test_rejects_missing_#{missing_key}") do
      configuration = <<~TOML
        schema_version = 1

        [instances.example]
        name = "Example"
        adapter = "rss"
        ttl_minutes = 30
        num_items_to_fetch = 10
        url = "https://example.test/feed.xml"
      TOML

      configuration = configuration.sub(/#{missing_key} = .*\n/, "") if missing_key != :schema_version
      configuration = configuration.sub("schema_version = 1\n", "") if missing_key == :schema_version

      Tempfile.create(["cybort-config", ".toml"]) do |file|
        file.write(configuration)
        file.flush

        error = assert_raises(Cybort::ConfigurationError) do
          Cybort::Configuration.load(file.path)
        end

        assert_includes error.message, missing_key.to_s
      end
    end
  end

  def test_rejects_non_positive_ttl_and_fetch_limit
    configuration = File.read(FIXTURE).sub("ttl_minutes = 30", "ttl_minutes = 0").sub("num_items_to_fetch = 10", "num_items_to_fetch = -1")
    Tempfile.create(["cybort-config", ".toml"]) do |file|
      file.write(configuration)
      file.flush
      error = assert_raises(Cybort::ConfigurationError) do
        Cybort::Configuration.load(file.path)
      end

      assert_includes error.message, "ttl_minutes"
    end
  end
end
