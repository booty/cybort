require "test_helper"

class CliTest < Minitest::Test
  class StubHttpClient
    attr_reader :calls

    def initialize(body)
      @body = body
      @calls = 0
    end

    def get(_url, headers: {})
      @calls += 1
      Cybort::HttpResponse.new(status: 200, headers: {}, body: @body)
    end
  end

  class MissingDependencyChecker
    attr_reader :calls

    def initialize(dependency)
      @dependency = dependency
      @calls = []
    end

    def resolve(dependency, env: ENV.to_h)
      @calls << dependency.executable
      Cybort::DependencyResolution.new(
        dependency: dependency,
        path: nil,
        version: nil,
        error: { category: "missing", executable: dependency.executable }
      )
    end

    def validate_version!(_dependency, resolution)
      resolution
    end
  end

  class StubCommandAdapter < Cybort::Adapters::Base
    def self.validate_configuration!(_instance); end

    def fetch_from_source
      raise "should not fetch when dependency is unavailable"
    end
  end

  RSS_BODY = <<~XML
    <?xml version="1.0"?>
    <rss version="2.0"><channel><title>Test</title>
      <item><guid>cli-1</guid><title>CLI article</title>
        <link>https://example.test/cli</link>
        <description>CLI body</description>
        <pubDate>Sun, 16 Aug 2026 11:00:00 GMT</pubDate>
      </item>
    </channel></rss>
  XML

  def write_config(root)
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "cybort.toml"), <<~TOML)
      schema_version = 1

      [instances.cli_rss]
      name = "CLI RSS"
      adapter = "rss"
      ttl_minutes = 30
      num_items_to_fetch = 5
      url = "https://example.test/feed.xml"
    TOML
  end

  def test_missing_configuration_explains_how_to_initialize_cybort
    Dir.mktmpdir do |directory|
      output = StringIO.new
      error_output = StringIO.new

      status = Cybort::CLI.start([], out: output, err: error_output, home: directory)

      assert_equal 2, status
      assert_empty output.string
      assert_includes error_output.string, "No Cybort configuration found"
      assert_includes error_output.string, "cybort init"
      assert_includes error_output.string, "cybort.toml"
    end
  end

  def test_fetches_and_then_uses_cached_rss_data
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      write_config(root)
      client = StubHttpClient.new(RSS_BODY)
      first_output = StringIO.new

      first_status = Cybort::CLI.start(["--force-fetch"], out: first_output, err: first_output, home: directory, http_client: client)
      second_output = StringIO.new
      second_status = Cybort::CLI.start([], out: second_output, err: second_output, home: directory, http_client: client)

      assert_equal 0, first_status
      assert_equal 0, second_status
      assert_equal 1, client.calls
      assert_equal "success", JSON.parse(second_output.string).fetch("status")
      assert_equal "CLI article", JSON.parse(second_output.string).fetch("instances").first.fetch("items").first.fetch("title")
    end
  end

  def test_runtime_root_selects_an_alternate_installation
    Dir.mktmpdir do |directory|
      root = File.join(directory, "alternate")
      write_config(root)
      output = StringIO.new

      status = Cybort::CLI.start(
        ["--root", root, "--force-fetch"],
        out: output, err: StringIO.new, home: directory,
        http_client: StubHttpClient.new(RSS_BODY)
      )

      assert_equal 0, status
      assert_equal "CLI article", JSON.parse(output.string).fetch("instances").first.fetch("items").first.fetch("title")
      assert_path_exists File.join(root, "cybort.sqlite3")
    end
  end

  def test_diagnostic_mode_emits_newline_terminated_non_json_output
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      write_config(root)
      output = StringIO.new

      status = Cybort::CLI.start(
        ["--force-fetch"], out: output, err: StringIO.new, home: directory,
        http_client: StubHttpClient.new(RSS_BODY), output_mode: :diagnostic
      )

      assert_equal 0, status
      refute_empty output.string
      refute_match(/\A\s*\{/, output.string)
      assert output.string.lines.all? { |line| line.end_with?("\n") }
    end
  end

  def test_emits_grouped_dependency_guidance_for_source_failure
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "cybort.toml"), <<~TOML)
        schema_version = 1

        [instances.command_source]
        name = "Command Source"
        adapter = "command"
        ttl_minutes = 30
        num_items_to_fetch = 1
      TOML
      dependency = Cybort::Dependency.new(
        executable: "missing-tool",
        purpose: "test command",
        install_hint: "brew install missing-tool"
      )
      registry = Cybort::AdapterRegistry.new
      registry.register("command", StubCommandAdapter, dependencies: [dependency])
      checker = MissingDependencyChecker.new(dependency)
      output = StringIO.new

      status = Cybort::CLI.start(
        [], out: output, err: StringIO.new, home: directory, registry: registry,
        dependency_checker: checker
      )

      payload = JSON.parse(output.string)
      assert_equal 1, status
      assert_equal "failure", payload.fetch("instances").first.fetch("status")
      assert_equal ["command_source"], payload.fetch("unavailable_dependencies").first.fetch("instances")
      assert_equal "brew install missing-tool", payload.fetch("unavailable_dependencies").first.fetch("install_hint")
      assert_equal ["missing-tool"], checker.calls
      refute_includes output.string, "stderr"
    end
  end

  def test_invalid_toml_does_not_echo_configuration_contents
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      FileUtils.mkdir_p(root)
      sentinel = "CLI_PARSE_SENTINEL"
      File.write(File.join(root, "cybort.toml"), <<~TOML)
        schema_version = 1

        [instances.reddit]
        name = "Reddit"
        adapter = "reddit"
        client_secret = #{sentinel}
      TOML
      output = StringIO.new
      error_output = StringIO.new

      status = Cybort::CLI.start([], out: output, err: error_output, home: directory)

      assert_equal 2, status
      refute_includes error_output.string, sentinel
      refute_includes output.string, sentinel
    end
  end

  def test_purge_requires_exact_confirmation_and_can_create_a_backup
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      FileUtils.mkdir_p(root)
      database = File.join(root, "cybort.sqlite3")
      persistence = Cybort::Persistence.new(database).setup!
      instance = Cybort::Configuration::Instance.new(
        id: "rss", name: "RSS", adapter: "rss", ttl_minutes: 30,
        retention_ttl_minutes: nil, hard_expiry_ttl_minutes: nil,
        num_items_to_fetch: 5, options: {}
      )
      persistence.register_instance(instance)
      persistence.write_fetch_result(
        Cybort::FetchResult.success(
          instance_id: "rss",
          items: [Cybort::Item.new(instance_id: "rss", canonical_id: "entry", fetched_at: Time.now.utc, title: "Entry")],
          sync_state: { cursor: "next" },
          started_at: Time.now.utc,
          finished_at: Time.now.utc,
          source_fetched: true
        )
      )
      backup = File.join(directory, "rss-backup")
      output = StringIO.new

      status = Cybort::CLI.start(
        ["purge", "rss", "--backup", backup],
        out: output, err: StringIO.new, home: directory,
        input: StringIO.new("PURGE rss\n")
      )

      assert_equal 0, status
      assert_equal %w[cybort-timeseries.sqlite3 cybort.sqlite3 manifest.json], Dir.children(backup).sort
      assert_nil persistence.instance_record("rss")
      assert_includes output.string, "Purged rss"
    end
  end

  def test_purge_removes_a_time_series_instance_from_both_databases
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      FileUtils.mkdir_p(root)
      clock = -> { Time.utc(2026, 8, 16, 12, 34, 56) }
      instance = Cybort::Configuration::Instance.new(
        id: "sensor", name: "Sensor", adapter: "fixture", ttl_minutes: 30,
        retention_ttl_minutes: nil, hard_expiry_ttl_minutes: nil,
        num_items_to_fetch: 5, options: {}
      )
      main = Cybort::Persistence.new(File.join(root, "cybort.sqlite3"), clock: clock).setup!
      main.register_instance(instance)
      time_series = Cybort::TimeSeriesPersistence.new(
        File.join(root, "cybort-timeseries.sqlite3"), clock: clock
      ).setup!
      factory = Cybort::TimeSeriesSpoolFactory.new(directory: root, clock: clock)
      writer = factory.open(
        instance_id: "sensor", import_key: "batch-1", import_mode: :append,
        source_started_at: clock.call - 60
      )
      writer.register_series(
        series_key: "temperature", metric_key: "temperature", value_type: :numeric,
        canonical_unit: "Cel", dimensions: {}
      )
      writer.add_observation(
        series_key: "temperature", source_record_key: "reading-1", observed_at: clock.call,
        numeric_value: 21.5, metadata: {}
      )
      artifact = writer.finalize(sync_state: {}, source_finished_at: clock.call, metadata: {})
      time_series.import(artifact)
      FileUtils.rm_f(artifact.path)
      time_series.close
      main.close

      status = Cybort::CLI.start(
        ["purge", "sensor", "--yes"], out: StringIO.new, err: StringIO.new,
        home: directory, clock: clock
      )

      assert_equal 0, status
      reopened_main = Cybort::Persistence.new(File.join(root, "cybort.sqlite3"), clock: clock).setup!
      assert_nil reopened_main.instance_record("sensor")
      assert_empty reopened_main.pending_time_series_purges
      reopened_time_series = Cybort::TimeSeriesReader.new(File.join(root, "cybort-timeseries.sqlite3"))
      assert_equal 0, reopened_time_series.context_for(instance_id: "sensor").fetch(:observation_count)
      reopened_main.close
      reopened_time_series.close
    ensure
      main&.close
      time_series&.close
    end
  end

  def test_purge_finishes_pending_intent_after_canonical_delete_commits
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      FileUtils.mkdir_p(root)
      clock = -> { Time.utc(2026, 8, 16, 12, 34, 56) }
      instance = Cybort::Configuration::Instance.new(
        id: "sensor", name: "Sensor", adapter: "fixture", ttl_minutes: 30,
        retention_ttl_minutes: nil, hard_expiry_ttl_minutes: nil,
        num_items_to_fetch: 5, options: {}
      )
      main = Cybort::Persistence.new(File.join(root, "cybort.sqlite3"), clock: clock).setup!
      main.register_instance(instance)
      time_series = Cybort::TimeSeriesPersistence.new(
        File.join(root, "cybort-timeseries.sqlite3"), clock: clock
      ).setup!
      factory = Cybort::TimeSeriesSpoolFactory.new(directory: root, clock: clock)
      writer = factory.open(
        instance_id: "sensor", import_key: "batch-1", import_mode: :append,
        source_started_at: clock.call - 60
      )
      writer.register_series(
        series_key: "temperature", metric_key: "temperature", value_type: :numeric,
        canonical_unit: "Cel", dimensions: {}
      )
      writer.add_observation(
        series_key: "temperature", source_record_key: "reading-1", observed_at: clock.call,
        numeric_value: 21.5, metadata: {}
      )
      artifact = writer.finalize(sync_state: {}, source_finished_at: clock.call, metadata: {})
      time_series.import(artifact)
      FileUtils.rm_f(artifact.path)

      assert main.begin_time_series_purge(instance_id: "sensor")
      assert time_series.delete_instance(instance_id: "sensor")
      time_series.close
      main.close

      status = Cybort::CLI.start(
        ["purge", "sensor", "--yes"], out: StringIO.new, err: StringIO.new,
        home: directory, clock: clock
      )

      assert_equal 0, status
      reopened_main = Cybort::Persistence.new(File.join(root, "cybort.sqlite3"), clock: clock).setup!
      assert_nil reopened_main.instance_record("sensor")
      assert_empty reopened_main.pending_time_series_purges
      reopened_main.close
    ensure
      main&.close
      time_series&.close
    end
  end
end
