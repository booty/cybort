require "test_helper"

class CliSystemTest < Minitest::Test
  RSS_URL = "https://example.test/feed.xml"
  GITHUB_URL = "https://api.example.test/notifications"

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
end

