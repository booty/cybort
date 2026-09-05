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

  def test_init_creates_installation_and_schema
    Dir.mktmpdir do |directory|
      path = File.join(directory, "cybort")
      output = StringIO.new

      status = Cybort::CLI.start(["init", path], out: output, err: output, home: directory)

      assert_equal 0, status
      assert_path_exists File.join(path, "cybort.toml")
      assert_path_exists File.join(path, "cybort.sqlite3")
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
end
