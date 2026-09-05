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

    def get(url, headers: {}, timeout_seconds: nil)
      raise Cybort::SourceError, "source unavailable: #{url}" if @failures.include?(url)

      Cybort::HttpResponse.new(status: 200, headers: {}, body: @responses.fetch(url))
    end
  end

  class RedditHttpClient
    attr_reader :calls, :requested_urls

    def initialize(token:, subscriptions:, unread:, home:, subreddits:, failures: {}, extra_responses: {})
      @routes = {
        token: token,
        subscriptions: Array(subscriptions),
        unread: Array(unread),
        home: Array(home),
        subreddits: subreddits.transform_values { |values| Array(values) }
      }
      @failures = failures
      @extra_responses = extra_responses
      @calls = []
      @requested_urls = []
    end

    def post_form(url, form:, headers:, timeout_seconds:)
      record_call(:post_form, url, form: form, headers: headers, timeout_seconds: timeout_seconds)
      response_for(@failures.fetch(:token, @routes.fetch(:token)))
    end

    def get(url, headers: {}, timeout_seconds: nil)
      record_call(:get, url, headers: headers, timeout_seconds: timeout_seconds)
      return response_for(@extra_responses.fetch(url)) if @extra_responses.key?(url)

      uri = URI.parse(url)
      route, name = route_for(uri)
      failure_key = name ? "#{route}:#{name}" : route
      failure = @failures[failure_key] || @failures[route.to_sym]
      return response_for(failure) unless failure.nil?

      value = if route == :subreddit
        next_response(@routes.fetch(:subreddits).fetch(name, []), empty_listing)
      else
        next_response(@routes.fetch(route), empty_listing)
      end
      response_for(value)
    end

    private

    def record_call(method, url, **options)
      @requested_urls << url
      @calls << { method: method, url: url }.merge(options)
    end

    def route_for(uri)
      case uri.path
      when "/subreddits/mine/subscriber" then [:subscriptions, nil]
      when "/message/unread" then [:unread, nil]
      when "/hot" then [:home, nil]
      else
        match = uri.path.match(%r{\A/r/([^/]+)/hot\z})
        raise "unexpected Reddit URL: #{uri.path}" unless match

        [:subreddit, match[1]]
      end
    end

    def next_response(values, default)
      values.empty? ? default : values.shift
    end

    def response_for(value)
      raise value if value.is_a?(Exception)
      return value if value.is_a?(Cybort::HttpResponse)

      body = value.is_a?(String) ? value : JSON.generate(value)
      Cybort::HttpResponse.new(status: 200, headers: {}, body: body)
    end

    def empty_listing
      { "kind" => "Listing", "data" => { "children" => [], "after" => nil } }
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

  def write_gmail_config(root, ttl_minutes: 30, retention_ttl_minutes: nil, id: "gmail")
    FileUtils.mkdir_p(root)
    retention = retention_ttl_minutes && "retention_ttl_minutes = #{retention_ttl_minutes}"
    File.write(File.join(root, "cybort.toml"), <<~TOML)
      schema_version = 1

      [instances.#{id}]
      name = "Gmail"
      adapter = "gmail"
      ttl_minutes = #{ttl_minutes}
      #{retention}
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

  def reddit_fixture(name)
    JSON.parse(File.read(File.expand_path("../fixtures/reddit/#{name}.json", __dir__)))
  end

  def reddit_client(token: reddit_fixture("token"), subscriptions: reddit_fixture("subscriptions_page_1").then { |page| [page, reddit_fixture("subscriptions_page_2")] },
                    unread: [single_reddit_message_listing],
                    home: [reddit_fixture("home_hot")],
                    subreddits: {
                      "askscience" => [askscience_listing],
                      "news" => [news_listing]
                    }, failures: {}, extra_responses: {})
    RedditHttpClient.new(
      token: token,
      subscriptions: subscriptions,
      unread: unread,
      home: home,
      subreddits: subreddits,
      failures: failures,
      extra_responses: extra_responses
    )
  end

  def askscience_listing
    listing = reddit_fixture("included_hot")
    listing["data"]["children"] = listing.fetch("data").fetch("children").select do |child|
      child.fetch("data").fetch("subreddit") == "askscience"
    end
    listing
  end

  def news_listing
    listing = reddit_fixture("news_hot")
    ordinary = listing.fetch("data").fetch("children").find do |child|
      child.fetch("data").fetch("id") == "e5"
    end
    ordinary.fetch("data")["created_utc"] = 1_788_678_001
    listing
  end

  def single_reddit_message_listing
    page = reddit_fixture("unread_page_1")
    page["data"]["children"] = page.fetch("data").fetch("children").select do |child|
      child.fetch("data", {}).fetch("id", nil) == "d4"
    end
    page["data"]["after"] = nil
    page
  end

  def write_reddit_config(root, ttl_minutes: 15, retention_ttl_minutes: nil, num_items_to_fetch: 3,
                          include_subreddits: ["askscience"], exclude_subreddits: ["memes"], both: false)
    FileUtils.mkdir_p(root)
    retention = retention_ttl_minutes && "retention_ttl_minutes = #{retention_ttl_minutes}"
    reddit = <<~TOML

      [instances.reddit]
      name = "Reddit"
      adapter = "reddit"
      ttl_minutes = #{ttl_minutes}
      #{retention}
      num_items_to_fetch = #{num_items_to_fetch}
      client_id = "fake-client-id"
      client_secret = "fake-client-secret"
      refresh_token = "fake-refresh-token"
      user_agent = "macos:com.example.cybort:v1 (by /u/test_user)"
      include_subreddits = #{JSON.generate(include_subreddits)}
      exclude_subreddits = #{JSON.generate(exclude_subreddits)}
    TOML
    rss = if both
      <<~TOML

        [instances.rss]
        name = "RSS"
        adapter = "rss"
        ttl_minutes = 30
        num_items_to_fetch = 5
        url = "#{RSS_URL}"
      TOML
    else
      ""
    end
    File.write(File.join(root, "cybort.toml"), <<~TOML + reddit + rss)
      schema_version = 1
    TOML
  end

  def empty_reddit_listing
    { "kind" => "Listing", "data" => { "children" => [], "after" => nil } }
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

  def test_reddit_remote_snapshot_persists_items_in_cli_recency_order
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      write_reddit_config(root)
      client = reddit_client
      output = StringIO.new

      status = Cybort::CLI.start(
        ["--force-fetch"], out: output, err: StringIO.new, home: directory, http_client: client
      )
      payload = JSON.parse(output.string)
      instance = payload.fetch("instances").find { |value| value.fetch("id") == "reddit" }

      assert_equal 0, status
      assert_equal "success", instance.fetch("status")
      assert_equal 3, instance.fetch("item_count")
      assert_equal %w[t4_d4 t3_e5 t3_d4], instance.fetch("items").map { |item| item.fetch("canonical_id") }
      assert_equal [1, 3, 2], instance.fetch("items").map { |item| item.fetch("info").fetch("selection_rank") }
      assert instance.fetch("items").all? { |item| item.fetch("body").nil? }
      assert_equal "unsupported_by_documented_data_api", instance.fetch("metadata").fetch("chat_collection")
      refute client.requested_urls.any? { |url| url.match?(%r{/r/[^/]*\+[^/]*/hot}) }

      persistence = Cybort::Persistence.new(File.join(root, "cybort.sqlite3"))
      assert_equal %w[t4_d4 t3_e5 t3_d4], persistence.items_for(instance_id: "reddit").map(&:canonical_id)
    end
  end

  def test_reddit_complete_snapshot_removes_omitted_items_and_refreshes_returned_identity
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      write_reddit_config(root)
      first = Cybort::CLI.start(
        ["--force-fetch"], out: StringIO.new, err: StringIO.new, home: directory, http_client: reddit_client
      )

      refreshed = reddit_fixture("home_hot")
      refreshed["data"]["children"] = [refreshed["data"]["children"].first]
      refreshed["data"]["children"].first["data"].merge!(
        "title" => "Refreshed Ruby thread", "score" => 700, "num_comments" => 80
      )
      empty = empty_reddit_listing
      second_client = reddit_client(
        unread: [empty],
        home: [refreshed],
        subreddits: { "askscience" => [empty], "news" => [empty] }
      )
      output = StringIO.new
      second = Cybort::CLI.start(
        ["--force-fetch"], out: output, err: StringIO.new, home: directory, http_client: second_client
      )
      payload = JSON.parse(output.string)
      items = payload.fetch("instances").find { |value| value.fetch("id") == "reddit" }.fetch("items")

      assert_equal 0, first
      assert_equal 0, second
      assert_equal ["t3_a1"], items.map { |item| item.fetch("canonical_id") }
      assert_equal "Refreshed Ruby thread", items.first.fetch("title")
      assert_equal 700, items.first.fetch("info").fetch("vote_score")
      assert_equal 80, items.first.fetch("info").fetch("comment_count")
    end
  end

  def test_reddit_empty_complete_snapshot_clears_the_instance
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      write_reddit_config(root)
      first = Cybort::CLI.start(
        ["--force-fetch"], out: StringIO.new, err: StringIO.new, home: directory, http_client: reddit_client
      )
      empty = empty_reddit_listing
      empty_client = reddit_client(
        subscriptions: [empty], unread: [empty], home: [empty], subreddits: { "askscience" => [empty] }
      )
      output = StringIO.new
      second = Cybort::CLI.start(
        ["--force-fetch"], out: output, err: StringIO.new, home: directory, http_client: empty_client
      )
      payload = JSON.parse(output.string)
      items = payload.fetch("instances").find { |value| value.fetch("id") == "reddit" }.fetch("items")

      assert_equal 0, first
      assert_equal 0, second
      assert_empty items

      persistence = Cybort::Persistence.new(File.join(root, "cybort.sqlite3"))
      assert_empty persistence.items_for(instance_id: "reddit")
    end
  end

  def test_reddit_cache_hit_makes_no_remote_calls_and_has_no_remote_chat_metadata
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      write_reddit_config(root)
      client = reddit_client
      first = Cybort::CLI.start(
        ["--force-fetch"], out: StringIO.new, err: StringIO.new, home: directory, http_client: client
      )
      request_count = client.calls.length
      output = StringIO.new
      second = Cybort::CLI.start(
        [], out: output, err: StringIO.new, home: directory, http_client: client
      )
      payload = JSON.parse(output.string)
      instance = payload.fetch("instances").find { |value| value.fetch("id") == "reddit" }

      assert_equal 0, first
      assert_equal 0, second
      assert_equal "cached", instance.fetch("status")
      assert_equal request_count, client.calls.length
      refute instance.fetch("metadata").key?("chat_collection")
      refute_empty instance.fetch("items")
    end
  end

  def test_reddit_remote_failures_preserve_prior_items_and_sync_state
    failure_cases = {
      token_401: -> { reddit_client(failures: { token: Cybort::HttpResponse.new(status: 401, headers: {}, body: "secret token error") }) },
      data_403: -> { reddit_client(failures: { subscriptions: Cybort::HttpResponse.new(status: 403, headers: {}, body: "private title") }) },
      rate_limited: -> { reddit_client(failures: { subscriptions: Cybort::HttpResponse.new(status: 429, headers: { "x-ratelimit-reset" => "0" }, body: "private title") }) },
      timeout: -> { reddit_client(failures: { token: Cybort::HttpTransportError.new(category: :timeout) }) },
      malformed_later_page: -> {
        reddit_client(unread: [reddit_fixture("unread_page_1"), "not-json-MALFORMED_SECRET_TITLE"])
      }
    }

    failure_cases.each do |name, build_client|
      Dir.mktmpdir do |directory|
        root = File.join(directory, ".cybort")
        write_reddit_config(root)
        first = Cybort::CLI.start(
          ["--force-fetch"], out: StringIO.new, err: StringIO.new, home: directory, http_client: reddit_client
        )
        persistence = Cybort::Persistence.new(File.join(root, "cybort.sqlite3"))
        before_items = persistence.items_for(instance_id: "reddit").map(&:canonical_id)
        before_context = persistence.context_for(instance_id: "reddit")
        output = StringIO.new
        second = Cybort::CLI.start(
          ["--force-fetch"], out: output, err: StringIO.new, home: directory, http_client: build_client.call
        )
        payload = JSON.parse(output.string)
        instance = payload.fetch("instances").find { |value| value.fetch("id") == "reddit" }
        failure_run = persistence.fetch_runs_for(instance_id: "reddit").last

        assert_equal 0, first, name
        assert_equal 1, second, name
        assert_equal "failure", instance.fetch("status"), name
        assert_equal before_items, persistence.items_for(instance_id: "reddit").map(&:canonical_id), name
        assert_equal before_context.fetch(:last_successful_fetch), persistence.context_for(instance_id: "reddit").fetch(:last_successful_fetch), name
        refute_includes output.string, "fake-refresh-token", name
        refute_includes output.string, "MALFORMED_SECRET_TITLE", name
        refute_includes failure_run.fetch("error_message").to_s, "private title", name
      end
    end
  end

  def test_reddit_retention_remains_success_only_when_composed_with_replacement
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      write_reddit_config(root, retention_ttl_minutes: 1)
      now = [Time.utc(2026, 9, 5, 12)]
      clock = -> { now.fetch(0) }
      first = Cybort::CLI.start(
        ["--force-fetch"], out: StringIO.new, err: StringIO.new, home: directory,
        http_client: reddit_client, clock: clock
      )
      now[0] += 120
      failed = Cybort::CLI.start(
        ["--force-fetch"], out: StringIO.new, err: StringIO.new, home: directory,
        http_client: reddit_client(failures: { token: Cybort::HttpResponse.new(status: 401, headers: {}, body: "secret") }),
        clock: clock
      )
      persistence = Cybort::Persistence.new(File.join(root, "cybort.sqlite3"))
      preserved_ids = persistence.items_for(instance_id: "reddit").map(&:canonical_id)
      empty = empty_reddit_listing
      succeeded = Cybort::CLI.start(
        ["--force-fetch"], out: StringIO.new, err: StringIO.new, home: directory,
        http_client: reddit_client(
          subscriptions: [empty], unread: [empty], home: [empty], subreddits: { "askscience" => [empty] }
        ), clock: clock
      )

      assert_equal 0, first
      assert_equal 1, failed
      assert_equal 0, succeeded
      assert_equal %w[t4_d4 t3_e5 t3_d4], preserved_ids
      assert_empty persistence.items_for(instance_id: "reddit")
    end
  end

  def test_reddit_failure_does_not_discard_successful_rss_result
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      write_reddit_config(root, both: true)
      output = StringIO.new
      status = Cybort::CLI.start(
        ["--force-fetch"], out: output, err: StringIO.new, home: directory,
        http_client: reddit_client(
          failures: { token: Cybort::HttpResponse.new(status: 401, headers: {}, body: "secret") },
          extra_responses: { RSS_URL => rss_body }
        )
      )
      payload = JSON.parse(output.string)
      reddit = payload.fetch("instances").find { |value| value.fetch("id") == "reddit" }
      rss = payload.fetch("instances").find { |value| value.fetch("id") == "rss" }

      assert_equal 1, status
      assert_equal "partial_failure", payload.fetch("status")
      assert_equal "failure", reddit.fetch("status")
      assert_equal "success", rss.fetch("status")
      assert_equal "First article", rss.fetch("items").first.fetch("title")
      refute_includes output.string, "fake-refresh-token"
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
      write_gmail_config(root, retention_ttl_minutes: 60)
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
      assert_equal "Quarterly review", payload.fetch("instances").find { |value| value.fetch("id") == "gmail" }.fetch("items").first.fetch("title")
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
