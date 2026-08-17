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
end

