require "test_helper"

class CliSystemTest < Minitest::Test
  RSS_URL = "https://example.test/feed.xml"
  GITHUB_URL = "https://api.example.test/notifications"
  EMPTY_RSS_BODY = <<~XML
    <?xml version="1.0"?>
    <rss version="2.0">
      <channel><title>Empty</title></channel>
    </rss>
  XML

  class FakeHttpClient
    def initialize(responses:, failures: [])
      @responses = responses
      @failures = failures
    end

    def get(url, headers: {})
      raise Cybort::SourceError, "source unavailable: #{url}" if @failures.include?(url)

      Cybort::HttpResponse.new(status: 200, headers: {}, body: @responses.fetch(url))
    end
  end

  FakeStatus = Struct.new(:success?, :exitstatus)

  class FakeGwsRunner
    attr_reader :calls

    def initialize(list_body:, details:, failure: nil)
      @list_body = list_body
      @details = details
      @failure = failure
      @calls = []
    end

    def run(argv, **options)
      @calls << [argv, options]
      return Cybort::CommandResult.new(
        argv: argv, stdout: "redacted@example.test", stderr: "token=redacted", status: FakeStatus.new(false, 7),
        timed_out: false, stdout_truncated: false, stderr_truncated: false, spawn_error_category: nil
      ) if @failure

      params = JSON.parse(argv.fetch(-1))
      body = if argv.include?("list")
        @list_body
      else
        JSON.generate(@details.fetch(params.fetch("id")))
      end
      Cybort::CommandResult.new(
        argv: argv, stdout: body, stderr: "", status: FakeStatus.new(true, 0),
        timed_out: false, stdout_truncated: false, stderr_truncated: false, spawn_error_category: nil
      )
    end
  end

  class FakeDependencyChecker
    attr_reader :calls

    def initialize(available:)
      @available = available
      @calls = []
    end

    def resolve(dependency, env: ENV.to_h)
      @calls << dependency.executable
      Cybort::DependencyResolution.new(
        dependency: dependency,
        path: @available ? "/usr/local/bin/gws" : nil,
        version: @available ? "0.22.5" : nil,
        error: @available ? nil : { category: "missing", executable: dependency.executable, purpose: dependency.purpose, install_hint: dependency.install_hint }
      )
    end

    def validate_version!(_dependency, resolution)
      resolution
    end
  end

  def rss_body
    File.read(File.expand_path("../fixtures/rss/basic.xml", __dir__))
  end

  def github_body
    File.read(File.expand_path("../fixtures/github/notifications.json", __dir__))
  end

  def write_config(root, both: false)
    FileUtils.mkdir_p(root)
    github = if both
      <<~TOML

        [instances.github]
        name = "GitHub"
        adapter = "github"
        ttl_minutes = 30
        num_items_to_fetch = 5
        api_url = "#{GITHUB_URL}"
        token = "secret"
      TOML
    else
      ""
    end
    File.write(File.join(root, "cybort.toml"), <<~TOML + github)
      schema_version = 1

      [instances.rss]
      name = "RSS"
      adapter = "rss"
      ttl_minutes = 30
      num_items_to_fetch = 5
      url = "#{RSS_URL}"
    TOML
  end

  def write_gmail_config(root, ttl_minutes: 30, id: "gmail")
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "cybort.toml"), <<~TOML)
      schema_version = 1

      [instances.#{id}]
      name = "Gmail"
      adapter = "gmail"
      ttl_minutes = #{ttl_minutes}
      num_items_to_fetch = 2
      query = "in:anywhere"
    TOML
  end

  def write_two_gmail_config(root)
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "cybort.toml"), <<~TOML)
      schema_version = 1

      [instances.z_mail]
      name = "Z Gmail"
      adapter = "gmail"
      ttl_minutes = 30
      num_items_to_fetch = 1
      query = "in:anywhere"

      [instances.a_mail]
      name = "A Gmail"
      adapter = "gmail"
      ttl_minutes = 30
      num_items_to_fetch = 1
      query = "is:unread"
    TOML
  end

  def gmail_runner(failure: nil)
    FakeGwsRunner.new(
      list_body: File.read(File.expand_path("../fixtures/gmail/list_valid.json", __dir__)),
      details: {
        "one" => JSON.parse(File.read(File.expand_path("../fixtures/gmail/details/valid_one.json", __dir__))),
        "two" => JSON.parse(File.read(File.expand_path("../fixtures/gmail/details/valid_two.json", __dir__)))
      },
      failure: failure
    )
  end

  def client
    FakeHttpClient.new(responses: { RSS_URL => rss_body, GITHUB_URL => github_body })
  end

  def test_init_creates_a_usable_installation
    Dir.mktmpdir do |directory|
      path = File.join(directory, "installation")
      status = Cybort::CLI.start(["init", path], out: StringIO.new, err: StringIO.new, home: directory, input: StringIO.new)

      assert_equal 0, status
      assert_path_exists File.join(path, "cybort.toml")
      assert_path_exists File.join(path, "cybort.sqlite3")
    end
  end

  def test_one_source_run_returns_json_and_persists_item
    Dir.mktmpdir do |directory|
      write_config(File.join(directory, ".cybort"))
      output = StringIO.new

      status = Cybort::CLI.start(["--force-fetch"], out: output, err: StringIO.new, home: directory, http_client: client)
      payload = JSON.parse(output.string)

      assert_equal 0, status
      assert_equal "success", payload.fetch("status")
      assert_equal "First article", payload.fetch("instances").first.fetch("items").first.fetch("title")
    end
  end

  def test_successful_remote_fetch_prunes_expired_items_before_cli_output
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "cybort.toml"), <<~TOML)
        schema_version = 1

        [instances.rss]
        name = "RSS"
        adapter = "rss"
        ttl_minutes = 30
        retention_ttl_minutes = 60
        num_items_to_fetch = 5
        url = "#{RSS_URL}"
      TOML
      now = [Time.utc(2026, 9, 5, 10)]
      populated_client = FakeHttpClient.new(responses: { RSS_URL => rss_body })
      empty_client = FakeHttpClient.new(responses: { RSS_URL => EMPTY_RSS_BODY })

      first_status = Cybort::CLI.start(
        ["--force-fetch"], out: StringIO.new, err: StringIO.new, home: directory,
        http_client: populated_client, clock: -> { now.fetch(0) }
      )
      now[0] = Time.utc(2026, 9, 5, 12)
      output = StringIO.new
      second_status = Cybort::CLI.start(
        ["--force-fetch"], out: output, err: StringIO.new, home: directory,
        http_client: empty_client, clock: -> { now.fetch(0) }
      )

      payload = JSON.parse(output.string)
      assert_equal 0, first_status
      assert_equal 0, second_status
      assert_equal "success", payload.fetch("status")
      assert_empty payload.fetch("instances").first.fetch("items")

      persistence = Cybort::Persistence.new(File.join(root, "cybort.sqlite3"))
      assert_empty persistence.items_for(instance_id: "rss")
      assert_equal 2, persistence.fetch_runs_for(instance_id: "rss").length
    end
  end

  def test_cache_hit_preserves_items_older_than_retention_duration
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "cybort.toml"), <<~TOML)
        schema_version = 1

        [instances.rss]
        name = "RSS"
        adapter = "rss"
        ttl_minutes = 30
        retention_ttl_minutes = 5
        num_items_to_fetch = 5
        url = "#{RSS_URL}"
      TOML
      now = [Time.utc(2026, 9, 5, 10)]
      http_client = FakeHttpClient.new(responses: { RSS_URL => rss_body })

      first_status = Cybort::CLI.start(
        ["--force-fetch"], out: StringIO.new, err: StringIO.new, home: directory,
        http_client: http_client, clock: -> { now.fetch(0) }
      )
      now[0] = Time.utc(2026, 9, 5, 10, 10)
      output = StringIO.new
      second_status = Cybort::CLI.start(
        [], out: output, err: StringIO.new, home: directory,
        http_client: http_client, clock: -> { now.fetch(0) }
      )

      payload = JSON.parse(output.string)
      instance_payload = payload.fetch("instances").first
      assert_equal 0, first_status
      assert_equal 0, second_status
      assert_equal "cached", instance_payload.fetch("status")
      refute_empty instance_payload.fetch("items")

      persistence = Cybort::Persistence.new(File.join(root, "cybort.sqlite3"))
      refute_empty persistence.items_for(instance_id: "rss")
      assert_equal 1, persistence.fetch_runs_for(instance_id: "rss").length
    end
  end

  def test_two_source_run_reports_both_instances
    Dir.mktmpdir do |directory|
      write_config(File.join(directory, ".cybort"), both: true)
      output = StringIO.new

      status = Cybort::CLI.start(["--force-fetch"], out: output, err: StringIO.new, home: directory, http_client: client)
      ids = JSON.parse(output.string).fetch("instances").map { |instance| instance.fetch("id") }

      assert_equal 0, status
      assert_equal %w[github rss], ids.sort
    end
  end

  def test_partial_failure_returns_nonzero_and_keeps_successful_source_data
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      write_config(root, both: true)
      Cybort::CLI.start(["--force-fetch"], out: StringIO.new, err: StringIO.new, home: directory, http_client: client)

      output = StringIO.new
      failing_client = FakeHttpClient.new(responses: { RSS_URL => rss_body, GITHUB_URL => github_body }, failures: [GITHUB_URL])
      status = Cybort::CLI.start(["--force-fetch"], out: output, err: StringIO.new, home: directory, http_client: failing_client)
      payload = JSON.parse(output.string)
      rss_instance = payload.fetch("instances").find { |instance| instance.fetch("id") == "rss" }

      assert_equal 1, status
      assert_equal "partial_failure", payload.fetch("status")
      refute_empty rss_instance.fetch("items")
    end
  end

  def test_fresh_gmail_cache_remains_available_when_gws_is_missing
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      write_gmail_config(root)
      clock = -> { Time.utc(2026, 9, 4, 12) }
      first_output = StringIO.new
      first = Cybort::CLI.start(
        ["--force-fetch"], out: first_output, err: StringIO.new, home: directory,
        clock: clock, command_runner: gmail_runner, dependency_checker: FakeDependencyChecker.new(available: true)
      )
      output = StringIO.new
      second = Cybort::CLI.start(
        [], out: output, err: StringIO.new, home: directory,
        clock: clock, dependency_checker: FakeDependencyChecker.new(available: false)
      )

      assert_equal 0, first
      assert_equal 0, second
      payload = JSON.parse(output.string)
      assert_equal "cached", payload.fetch("instances").first.fetch("status")
      assert_equal "Quarterly review", payload.fetch("instances").first.fetch("items").first.fetch("title")
    end
  end

  def test_stale_gmail_dependency_failure_does_not_block_rss
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      write_gmail_config(root)
      File.open(File.join(root, "cybort.toml"), "a") do |file|
        file.puts <<~TOML

          [instances.rss]
          name = "RSS"
          adapter = "rss"
          ttl_minutes = 30
          num_items_to_fetch = 1
          url = "#{RSS_URL}"
        TOML
      end
      current_time = [Time.utc(2026, 9, 4, 12)]
      first = Cybort::CLI.start(
        ["--force-fetch"], out: StringIO.new, err: StringIO.new, home: directory,
        clock: -> { current_time.fetch(0) }, http_client: client,
        command_runner: gmail_runner, dependency_checker: FakeDependencyChecker.new(available: true)
      )
      current_time[0] += 3_601
      output = StringIO.new
      second = Cybort::CLI.start(
        ["--force-fetch"], out: output, err: StringIO.new, home: directory,
        clock: -> { current_time.fetch(0) }, http_client: client,
        dependency_checker: FakeDependencyChecker.new(available: false)
      )

      assert_equal 0, first
      assert_equal 1, second
      payload = JSON.parse(output.string)
      assert_equal %w[failure success], payload.fetch("instances").map { |value| value.fetch("status") }
      assert_equal ["gmail"], payload.fetch("unavailable_dependencies").first.fetch("instances")
      assert_equal "First article", payload.fetch("instances").find { |value| value.fetch("id") == "rss" }.fetch("items").first.fetch("title")
    end
  end

  def test_gmail_command_failure_keeps_last_known_good_items
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      write_gmail_config(root)
      Cybort::CLI.start(
        ["--force-fetch"], out: StringIO.new, err: StringIO.new, home: directory,
        command_runner: gmail_runner, dependency_checker: FakeDependencyChecker.new(available: true)
      )
      output = StringIO.new
      status = Cybort::CLI.start(
        ["--force-fetch"], out: output, err: StringIO.new, home: directory,
        command_runner: gmail_runner(failure: true), dependency_checker: FakeDependencyChecker.new(available: true)
      )

      payload = JSON.parse(output.string)
      assert_equal 1, status
      assert_equal "failure", payload.fetch("instances").first.fetch("status")
      assert_equal "Quarterly review", payload.fetch("instances").first.fetch("items").first.fetch("title")
      assert_includes output.string, "gws auth setup"
      refute_includes output.string, "token=redacted"
      refute_includes output.string, "redacted@example.test"
    end
  end

  def test_force_fetch_of_fresh_gmail_cache_still_requires_gws
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      write_gmail_config(root)
      first = Cybort::CLI.start(
        ["--force-fetch"], out: StringIO.new, err: StringIO.new, home: directory,
        command_runner: gmail_runner, dependency_checker: FakeDependencyChecker.new(available: true)
      )
      output = StringIO.new
      second = Cybort::CLI.start(
        ["--force-fetch"], out: output, err: StringIO.new, home: directory,
        dependency_checker: FakeDependencyChecker.new(available: false)
      )

      assert_equal 0, first
      assert_equal 1, second
      assert_equal "failure", JSON.parse(output.string).fetch("instances").first.fetch("status")
    end
  end

  def test_groups_missing_gws_guidance_for_multiple_instances_in_sorted_order
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      write_two_gmail_config(root)
      output = StringIO.new

      status = Cybort::CLI.start(
        ["--force-fetch"], out: output, err: StringIO.new, home: directory,
        dependency_checker: FakeDependencyChecker.new(available: false)
      )

      payload = JSON.parse(output.string)
      assert_equal 1, status
      assert_equal ["a_mail", "z_mail"], payload.fetch("unavailable_dependencies").first.fetch("instances")
      assert_equal %w[failure failure], payload.fetch("instances").map { |value| value.fetch("status") }
    end
  end

  def test_persists_only_safe_command_failure_metadata
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      write_gmail_config(root)
      Cybort::CLI.start(
        ["--force-fetch"], out: StringIO.new, err: StringIO.new, home: directory,
        command_runner: gmail_runner, dependency_checker: FakeDependencyChecker.new(available: true)
      )
      Cybort::CLI.start(
        ["--force-fetch"], out: StringIO.new, err: StringIO.new, home: directory,
        command_runner: gmail_runner(failure: true), dependency_checker: FakeDependencyChecker.new(available: true)
      )

      persistence = Cybort::Persistence.new(File.join(root, "cybort.sqlite3"))
      metadata = persistence.fetch_runs_for(instance_id: "gmail").last.fetch("metadata_json")
      assert_includes metadata, "gws auth setup"
      refute_includes metadata, "token=redacted"
      refute_includes metadata, "redacted@example.test"
    end
  end
end
