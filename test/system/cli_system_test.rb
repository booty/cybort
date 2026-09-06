require "test_helper"
require "support/gmail_http_fixture"

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

    def post_form(url, form:, headers:, timeout_seconds:, deadline_monotonic: nil)
      record_call(
        :post_form, url, form: form, headers: headers,
        timeout_seconds: timeout_seconds, deadline_monotonic: deadline_monotonic
      )
      response_for(@failures.fetch(:token, @routes.fetch(:token)))
    end

    def get(url, headers: {}, timeout_seconds: nil, deadline_monotonic: nil)
      record_call(
        :get, url, headers: headers,
        timeout_seconds: timeout_seconds, deadline_monotonic: deadline_monotonic
      )
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

  class FailingRedditTransport
    def post_form(_url, form:, headers:, **_options)
      raise EOFError, "REDDIT_TRANSPORT_SENTINEL"
    end

    def get(_url, headers:, **_options)
      raise EOFError, "REDDIT_TRANSPORT_SENTINEL"
    end
  end

  class RefusingCommandRunner
    def run(*)
      raise "COMMAND_RUNNER_SENTINEL"
    end
  end

  class RefusingDependencyChecker
    def resolve(*)
      raise "DEPENDENCY_CHECKER_SENTINEL"
    end

    def validate_version!(*)
      raise "DEPENDENCY_CHECKER_SENTINEL"
    end
  end

  class CommandFixtureAdapter < Cybort::Adapters::Base
    def self.validate_configuration!(_instance); end

    def fetch_from_source
      {
        items: [
          Cybort::Item.new(
            instance_id: instance.id,
            canonical_id: "fixture-#{instance.id}",
            fetched_at: clock.call,
            title: "Fixture item"
          )
        ],
        sync_state: {},
        metadata: { source: "command_fixture" }
      }
    end
  end

  class TwoAccountGmailHttp
    attr_reader :calls

    def initialize(accounts:)
      @accounts = accounts
      @calls = []
      @mutex = Mutex.new
    end

    def post_form(url, form:, **options)
      account = @accounts.values.find { |value| value.fetch(:refresh_token) == form.fetch(:refresh_token) }
      raise "unknown refresh token" unless account

      record(:post_form, url, form: form, **options)
      response(
        "access_token" => account.fetch(:access_token),
        "token_type" => "Bearer",
        "expires_in" => 3_600,
        "scope" => CliSystemTest::READONLY_SCOPE
      )
    end

    def get(url, headers:, **options)
      account = @accounts.values.find { |value| value.fetch(:authorization) == headers.fetch("Authorization") }
      raise "unknown bearer token" unless account

      record(:get, url, headers: headers, **options)
      uri = URI.parse(url)
      if uri.path.end_with?("/messages")
        response("messages" => [{ "id" => account.fetch(:message_id) }])
      else
        response(account.fetch(:detail))
      end
    end

    private

    def record(method, url, **options)
      @mutex.synchronize { @calls << { method: method, url: url }.merge(options) }
    end

    def response(payload)
      Cybort::HttpResponse.new(status: 200, headers: {}, body: JSON.generate(payload))
    end
  end

  READONLY_SCOPE = "https://www.googleapis.com/auth/gmail.readonly"

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
        path: @available ? "/usr/local/bin/#{dependency.executable}" : nil,
        version: @available ? "1.0.0" : nil,
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

  def write_gmail_config(root, credentials_file: nil, include_credentials_file: true,
                         ttl_minutes: 30, retention_ttl_minutes: nil, id: "gmail",
                         query: "in:anywhere", user_id: nil, include_spam_trash: nil)
    FileUtils.mkdir_p(root)
    retention = retention_ttl_minutes && "retention_ttl_minutes = #{retention_ttl_minutes}"
    credential = if include_credentials_file && credentials_file
      "credentials_file = #{JSON.generate(credentials_file)}"
    end
    user = user_id && "user_id = #{JSON.generate(user_id)}"
    spam_trash = unless include_spam_trash.nil?
      "include_spam_trash = #{include_spam_trash}"
    end
    File.write(File.join(root, "cybort.toml"), <<~TOML)
      schema_version = 1

      [instances.#{id}]
      name = "Gmail"
      adapter = "gmail"
      ttl_minutes = #{ttl_minutes}
      #{retention}
      #{credential}
      num_items_to_fetch = 2
      query = #{JSON.generate(query)}
      #{user}
      #{spam_trash}
    TOML
  end

  def write_authorized_user(root, filename: "authorized_user.json", refresh_token: "fake-refresh",
                            client_id: "fake-client", client_secret: "fake-secret")
    FileUtils.mkdir_p(root)
    path = File.join(root, filename)
    File.write(path, JSON.generate(
      "type" => "authorized_user",
      "client_id" => client_id,
      "client_secret" => client_secret,
      "refresh_token" => refresh_token
    ))
    File.chmod(0o600, path)
    path
  end

  def write_two_gmail_config(root, first_credentials_file:, second_credentials_file:)
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "cybort.toml"), <<~TOML)
      schema_version = 1

      [instances.z_mail]
      name = "Z Gmail"
      adapter = "gmail"
      ttl_minutes = 30
      num_items_to_fetch = 1
      query = "in:anywhere"
      credentials_file = #{JSON.generate(second_credentials_file)}

      [instances.a_mail]
      name = "A Gmail"
      adapter = "gmail"
      ttl_minutes = 30
      num_items_to_fetch = 1
      query = "is:unread"
      credentials_file = #{JSON.generate(first_credentials_file)}
    TOML
  end

  def gmail_response(payload, status: 200)
    body = payload.is_a?(String) ? payload : JSON.generate(payload)
    Cybort::HttpResponse.new(status: status, headers: {}, body: body)
  end

  def gmail_token_response(access_token: "fake-access")
    {
      "access_token" => access_token,
      "token_type" => "Bearer",
      "expires_in" => 3_600,
      "scope" => READONLY_SCOPE
    }
  end

  def gmail_success_http(list: fixture_json("list_valid.json"), details: {
    "one" => fixture_json("details/valid_one.json"),
    "two" => fixture_json("details/valid_two.json")
  })
    ids = list.fetch("messages", []).first(2).map { |message| message.fetch("id") }.uniq
    GmailHttpFixture.new(responses: [
      gmail_response(gmail_token_response),
      gmail_response(list),
      *ids.map { |id| gmail_response(details.fetch(id)) }
    ])
  end

  def fixture_json(name)
    JSON.parse(File.read(File.expand_path("../fixtures/gmail/#{name}", __dir__)))
  end

  def command_fixture_registry
    dependency = Cybort::Dependency.new(
      executable: "fixture-tool",
      purpose: "test fixture",
      install_hint: "brew install fixture-tool",
      auth_hint: "configure fixture-tool"
    )
    registry = Cybort::AdapterRegistry.new
    registry.register("command_fixture", CommandFixtureAdapter, dependencies: [dependency])
    registry.register("rss", Cybort::Adapters::RSS)
    registry
  end

  def write_command_fixture_config(root, ids: ["fixture"])
    FileUtils.mkdir_p(root)
    instances = ids.map do |id|
      <<~TOML

        [instances.#{id}]
        name = "#{id.capitalize}"
        adapter = "command_fixture"
        ttl_minutes = 30
        num_items_to_fetch = 1
      TOML
    end.join
    File.write(File.join(root, "cybort.toml"), "schema_version = 1\n#{instances}")
  end

  def append_rss_config(root)
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
  end

  def combined_gmail_rss_http(gmail_http, rss_body: self.rss_body)
    Class.new do
      define_method(:initialize) do |gmail, rss|
        @gmail = gmail
        @rss = rss
      end

      define_method(:post_form) { |url, **options| @gmail.post_form(url, **options) }
      define_method(:get) do |url, **options|
        if url.start_with?(Cybort::GmailClient::DATA_URL)
          @gmail.get(url, **options)
        else
          Cybort::HttpResponse.new(status: 200, headers: {}, body: @rss)
        end
      end
    end.new(gmail_http, rss_body)
  end

  def seed_gmail_instance(root, instance_id:, fetched_at:, items:)
    configuration = Cybort::Configuration.load(File.join(root, "cybort.toml"))
    persistence = Cybort::Persistence.new(File.join(root, "cybort.sqlite3"), clock: -> { fetched_at })
    persistence.setup!
    persistence.register_instance(configuration.instances.fetch(instance_id))
    persistence.write_fetch_result(
      Cybort::FetchResult.success(
        instance_id: instance_id,
        items: items,
        sync_state: {},
        started_at: fetched_at,
        finished_at: fetched_at,
        source_fetched: true
      )
    )
    persistence
  end

  def gmail_item(instance_id:, canonical_id:, fetched_at:, title: "Cached mail")
    Cybort::Item.new(
      instance_id: instance_id,
      canonical_id: canonical_id,
      fetched_at: fetched_at,
      title: title
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

  def test_reddit_transport_failure_is_sanitized_in_cli_and_fetch_history
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      write_reddit_config(root)
      output = StringIO.new
      status = Cybort::CLI.start(
        ["--force-fetch"], out: output, err: StringIO.new, home: directory,
        http_client: Cybort::HttpClient.new(transport: FailingRedditTransport.new)
      )

      persistence = Cybort::Persistence.new(File.join(root, "cybort.sqlite3"))
      fetch_run = persistence.fetch_runs_for(instance_id: "reddit").last

      assert_equal 1, status
      refute_includes output.string, "REDDIT_TRANSPORT_SENTINEL"
      refute_includes fetch_run.fetch("error_message").to_s, "REDDIT_TRANSPORT_SENTINEL"
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

  def test_gmail_rest_failure_after_prior_success_keeps_last_known_good_items
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      credentials_file = write_authorized_user(root)
      write_gmail_config(root, credentials_file: credentials_file, id: "jer_gmail")
      refusing_runner = RefusingCommandRunner.new
      refusing_checker = RefusingDependencyChecker.new
      first_output = StringIO.new
      first = Cybort::CLI.start(
        ["--json", "--force-fetch"], home: directory, out: first_output, err: StringIO.new,
        http_client: gmail_success_http, command_runner: refusing_runner,
        dependency_checker: refusing_checker
      )
      failed_output = StringIO.new
      token_rejected_http = GmailHttpFixture.new(responses: [Cybort::HttpError.new(status: 400)])
      failed = Cybort::CLI.start(
        ["--json", "--force-fetch"], home: directory, out: failed_output, err: StringIO.new,
        http_client: token_rejected_http, command_runner: refusing_runner,
        dependency_checker: refusing_checker
      )

      payload = JSON.parse(failed_output.string)
      mail = payload.fetch("instances").find { |entry| entry.fetch("id") == "jer_gmail" }
      assert_equal 0, first
      assert_equal 1, failed
      assert_equal "failure", mail.fetch("status")
      assert_equal "token", mail.fetch("metadata").fetch("operation")
      assert_equal "authentication", mail.fetch("metadata").fetch("category")
      assert_equal 400, mail.fetch("metadata").fetch("status")
      assert_equal "Quarterly review", mail.fetch("items").first.fetch("title")
      assert_equal 1, token_rejected_http.calls.length
      assert_equal :post_form, token_rejected_http.calls.first.fetch(:method)
    end
  end

  def test_same_gmail_id_migrates_existing_mail_without_duplicates_or_schema_change
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      credentials_file = write_authorized_user(root)
      write_gmail_config(root, credentials_file: credentials_file, id: "jer_gmail")
      seed_time = Time.utc(2026, 9, 5, 10)
      persistence = seed_gmail_instance(
        root, instance_id: "jer_gmail", fetched_at: seed_time,
        items: [gmail_item(instance_id: "jer_gmail", canonical_id: "one", fetched_at: seed_time, title: "Legacy subject")]
      )
      output = StringIO.new

      status = Cybort::CLI.start(
        ["--json", "--force-fetch"], home: directory, out: output, err: StringIO.new,
        clock: -> { Time.utc(2026, 9, 5, 12) },
        http_client: gmail_success_http(list: { "messages" => [{ "id" => "one" }, { "id" => "two" }] }),
        command_runner: RefusingCommandRunner.new, dependency_checker: RefusingDependencyChecker.new
      )

      payload = JSON.parse(output.string)
      items = payload.fetch("instances").first.fetch("items")
      assert_equal 0, status
      assert_equal %w[one two], items.map { |item| item.fetch("canonical_id") }.sort
      assert_equal "Quarterly review", items.find { |item| item.fetch("canonical_id") == "one" }.fetch("title")
      assert_equal 2, persistence.items_for(instance_id: "jer_gmail").length
      assert_equal ["one", "two"], persistence.items_for(instance_id: "jer_gmail").map(&:canonical_id).sort
      assert_equal ["adapter_instances", "fetch_runs", "items", "schema_migrations"], persistence.table_names
    end
  end

  def test_fresh_gmail_cache_without_credentials_file_skips_all_remote_and_preflight_calls
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      credentials_file = write_authorized_user(root)
      write_gmail_config(root, credentials_file: credentials_file, id: "jer_gmail")
      now = Time.utc(2026, 9, 5, 12)
      first = Cybort::CLI.start(
        ["--json", "--force-fetch"], home: directory, out: StringIO.new, err: StringIO.new,
        clock: -> { now }, http_client: gmail_success_http,
        command_runner: RefusingCommandRunner.new, dependency_checker: RefusingDependencyChecker.new
      )
      FileUtils.rm(credentials_file)
      write_gmail_config(root, include_credentials_file: false, id: "jer_gmail")
      http = GmailHttpFixture.new(responses: [])
      output = StringIO.new
      second = Cybort::CLI.start(
        ["--json"], home: directory, out: output, err: StringIO.new, clock: -> { now }, http_client: http,
        command_runner: RefusingCommandRunner.new, dependency_checker: RefusingDependencyChecker.new
      )

      instance = JSON.parse(output.string).fetch("instances").first
      assert_equal 0, first
      assert_equal 0, second
      assert_equal "cached", instance.fetch("status")
      assert_equal "Quarterly review", instance.fetch("items").first.fetch("title")
      assert_empty http.calls
    end
  end

  def test_stale_gmail_missing_credentials_preserves_items_and_freshness
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      credentials_file = write_authorized_user(root)
      write_gmail_config(root, credentials_file: credentials_file, id: "jer_gmail")
      fetched_at = Time.utc(2026, 9, 5, 10)
      persistence = seed_gmail_instance(
        root, instance_id: "jer_gmail", fetched_at: fetched_at,
        items: [gmail_item(instance_id: "jer_gmail", canonical_id: "cached", fetched_at: fetched_at)]
      )
      FileUtils.rm(credentials_file)
      http = GmailHttpFixture.new(responses: [])
      output = StringIO.new
      status = Cybort::CLI.start(
        ["--json", "--force-fetch"], home: directory, out: output, err: StringIO.new,
        clock: -> { Time.utc(2026, 9, 5, 12) }, http_client: http,
        command_runner: RefusingCommandRunner.new, dependency_checker: RefusingDependencyChecker.new
      )

      payload = JSON.parse(output.string)
      mail = payload.fetch("instances").first
      assert_equal 1, status
      assert_equal "failure", mail.fetch("status")
      assert_equal "credentials", mail.fetch("metadata").fetch("operation")
      assert_equal "missing", mail.fetch("metadata").fetch("category")
      assert_equal ["cached"], persistence.items_for(instance_id: "jer_gmail").map(&:canonical_id)
      assert_equal fetched_at, persistence.context_for(instance_id: "jer_gmail").fetch(:last_successful_fetch)
      assert_empty http.calls
    end
  end

  def test_gmail_403_does_not_block_healthy_rss
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      credentials_file = write_authorized_user(root)
      write_gmail_config(root, credentials_file: credentials_file, id: "jer_gmail")
      append_rss_config(root)
      gmail_http = GmailHttpFixture.new(responses: [gmail_response(gmail_token_response), Cybort::HttpError.new(status: 403)])
      output = StringIO.new
      status = Cybort::CLI.start(
        ["--json", "--force-fetch"], home: directory, out: output, err: StringIO.new,
        http_client: combined_gmail_rss_http(gmail_http),
        command_runner: RefusingCommandRunner.new, dependency_checker: RefusingDependencyChecker.new
      )
      payload = JSON.parse(output.string)
      gmail = payload.fetch("instances").find { |entry| entry.fetch("id") == "jer_gmail" }
      rss = payload.fetch("instances").find { |entry| entry.fetch("id") == "rss" }

      assert_equal 1, status
      assert_equal "partial_failure", payload.fetch("status")
      assert_equal "failure", gmail.fetch("status")
      assert_equal "list", gmail.fetch("metadata").fetch("operation")
      assert_equal "authorization", gmail.fetch("metadata").fetch("category")
      assert_equal 403, gmail.fetch("metadata").fetch("status")
      assert_equal "success", rss.fetch("status")
      assert_equal "First article", rss.fetch("items").first.fetch("title")
    end
  end

  def test_gmail_detail_failure_discards_partial_items_and_does_not_prune
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      credentials_file = write_authorized_user(root)
      write_gmail_config(root, credentials_file: credentials_file, retention_ttl_minutes: 60, id: "jer_gmail")
      fetched_at = Time.utc(2026, 9, 5, 10)
      persistence = seed_gmail_instance(
        root, instance_id: "jer_gmail", fetched_at: fetched_at,
        items: [gmail_item(instance_id: "jer_gmail", canonical_id: "old", fetched_at: fetched_at)]
      )
      http = GmailHttpFixture.new(responses: [
        gmail_response(gmail_token_response),
        gmail_response({ "messages" => [{ "id" => "one" }, { "id" => "two" }] }),
        gmail_response(fixture_json("details/valid_one.json")),
        Cybort::HttpError.new(status: 500)
      ])
      output = StringIO.new
      status = Cybort::CLI.start(
        ["--json", "--force-fetch"], home: directory, out: output, err: StringIO.new,
        clock: -> { Time.utc(2026, 9, 5, 12) }, http_client: http,
        command_runner: RefusingCommandRunner.new, dependency_checker: RefusingDependencyChecker.new
      )

      payload = JSON.parse(output.string)
      mail = payload.fetch("instances").first
      assert_equal 1, status
      assert_equal "failure", mail.fetch("status")
      assert_equal "get", mail.fetch("metadata").fetch("operation")
      assert_equal 500, mail.fetch("metadata").fetch("status")
      assert_equal ["old"], persistence.items_for(instance_id: "jer_gmail").map(&:canonical_id)
      assert_equal fetched_at, persistence.context_for(instance_id: "jer_gmail").fetch(:last_successful_fetch)
    end
  end

  def test_empty_gmail_success_advances_freshness_without_clearing_old_items
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      credentials_file = write_authorized_user(root)
      write_gmail_config(root, credentials_file: credentials_file, id: "jer_gmail")
      old_time = Time.utc(2026, 9, 5, 10)
      now = Time.utc(2026, 9, 5, 12)
      persistence = seed_gmail_instance(
        root, instance_id: "jer_gmail", fetched_at: old_time,
        items: [gmail_item(instance_id: "jer_gmail", canonical_id: "old", fetched_at: old_time)]
      )
      http = GmailHttpFixture.new(responses: [gmail_response(gmail_token_response), gmail_response(fixture_json("empty.json"))])
      output = StringIO.new
      status = Cybort::CLI.start(
        ["--json", "--force-fetch"], home: directory, out: output, err: StringIO.new,
        clock: -> { now }, http_client: http,
        command_runner: RefusingCommandRunner.new, dependency_checker: RefusingDependencyChecker.new
      )

      instance = JSON.parse(output.string).fetch("instances").first
      assert_equal 0, status
      assert_equal "success", instance.fetch("status")
      assert_equal 0, instance.fetch("item_count")
      assert_equal ["old"], instance.fetch("items").map { |item| item.fetch("canonical_id") }
      assert_equal now, persistence.context_for(instance_id: "jer_gmail").fetch(:last_successful_fetch)
    end
  end

  def test_successful_gmail_fetch_prunes_only_old_unreturned_items
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      credentials_file = write_authorized_user(root)
      write_gmail_config(root, credentials_file: credentials_file, retention_ttl_minutes: 60, id: "jer_gmail")
      old_time = Time.utc(2026, 9, 5, 10)
      recent_time = Time.utc(2026, 9, 5, 11, 30)
      persistence = seed_gmail_instance(
        root, instance_id: "jer_gmail", fetched_at: old_time,
        items: [
          gmail_item(instance_id: "jer_gmail", canonical_id: "old", fetched_at: old_time),
          gmail_item(instance_id: "jer_gmail", canonical_id: "recent", fetched_at: recent_time)
        ]
      )
      http = GmailHttpFixture.new(responses: [
        gmail_response(gmail_token_response),
        gmail_response({ "messages" => [{ "id" => "one" }] }),
        gmail_response(fixture_json("details/valid_one.json"))
      ])
      output = StringIO.new
      status = Cybort::CLI.start(
        ["--json", "--force-fetch"], home: directory, out: output, err: StringIO.new,
        clock: -> { Time.utc(2026, 9, 5, 12) }, http_client: http,
        command_runner: RefusingCommandRunner.new, dependency_checker: RefusingDependencyChecker.new
      )

      instance = JSON.parse(output.string).fetch("instances").first
      assert_equal 0, status
      assert_equal %w[one recent], persistence.items_for(instance_id: "jer_gmail").map(&:canonical_id).sort
      assert_equal 1, instance.fetch("metadata").fetch("items_pruned")
    end
  end

  def test_two_gmail_accounts_route_refresh_tokens_and_bearer_headers_by_account
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      first_credentials_file = write_authorized_user(root, filename: "a.json", refresh_token: "refresh-a")
      second_credentials_file = write_authorized_user(root, filename: "z.json", refresh_token: "refresh-z")
      write_two_gmail_config(
        root, first_credentials_file: first_credentials_file, second_credentials_file: second_credentials_file
      )
      first_detail = fixture_json("details/valid_one.json").merge("id" => "a")
      second_detail = fixture_json("details/valid_two.json").merge("id" => "z")
      http = TwoAccountGmailHttp.new(accounts: {
        a: { refresh_token: "refresh-a", access_token: "access-a", authorization: "Bearer access-a", message_id: "a", detail: first_detail },
        z: { refresh_token: "refresh-z", access_token: "access-z", authorization: "Bearer access-z", message_id: "z", detail: second_detail }
      })
      output = StringIO.new
      status = Cybort::CLI.start(
        ["--json", "--force-fetch"], home: directory, out: output, err: StringIO.new,
        http_client: http, command_runner: RefusingCommandRunner.new,
        dependency_checker: RefusingDependencyChecker.new
      )

      payload = JSON.parse(output.string)
      token_calls = http.calls.select { |call| call.fetch(:method) == :post_form }
      get_calls = http.calls.select { |call| call.fetch(:method) == :get }
      assert_equal 0, status
      assert_equal %w[refresh-a refresh-z], token_calls.map { |call| call.fetch(:form).fetch(:refresh_token) }.sort
      assert_equal 2, get_calls.count { |call| call.fetch(:headers).fetch("Authorization") == "Bearer access-a" }
      assert_equal 2, get_calls.count { |call| call.fetch(:headers).fetch("Authorization") == "Bearer access-z" }
      assert_equal "Quarterly review", payload.fetch("instances").find { |entry| entry.fetch("id") == "a_mail" }.fetch("items").first.fetch("title")
      assert_equal "(no subject)", payload.fetch("instances").find { |entry| entry.fetch("id") == "z_mail" }.fetch("items").first.fetch("title")
    end
  end

  def test_gmail_failure_diagnostics_and_history_contain_only_safe_metadata
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      credentials_file = write_authorized_user(
        root, filename: "SECRET_CREDENTIAL_PATH.json", refresh_token: "SECRET_TOKEN"
      )
      write_gmail_config(
        root, credentials_file: credentials_file, id: "jer_gmail", query: "SECRET_QUERY", user_id: "SECRET_USER@example.test"
      )
      raw_error_body = "RAW_ERROR_BODY"
      transport = GmailHttpFixture.new(responses: [
        gmail_response(gmail_token_response(access_token: "SECRET_ACCESS_TOKEN")),
        gmail_response(raw_error_body, status: 403)
      ])
      http = Cybort::HttpClient.new(transport: transport)
      output = StringIO.new
      status = Cybort::CLI.start(
        ["--json", "--force-fetch"], home: directory, out: output, err: StringIO.new,
        http_client: http, command_runner: RefusingCommandRunner.new,
        dependency_checker: RefusingDependencyChecker.new
      )
      persistence = Cybort::Persistence.new(File.join(root, "cybort.sqlite3"))
      run = persistence.fetch_runs_for(instance_id: "jer_gmail").last
      payload = JSON.parse(output.string)
      sensitive = ["SECRET_TOKEN", "SECRET_ACCESS_TOKEN", "SECRET_CREDENTIAL_PATH", "SECRET_QUERY", "SECRET_USER", raw_error_body]

      assert_equal 1, status
      assert_equal({ "source" => "gmail_api", "operation" => "list", "category" => "authorization", "status" => 403 }, payload.fetch("instances").first.fetch("metadata"))
      sensitive.each do |value|
        refute_includes output.string, value
        refute_includes run.fetch("error_message").to_s, value
        refute_includes run.fetch("metadata_json").to_s, value
      end
    end
  end

  def test_gmail_human_diagnostics_include_static_token_403_and_file_guidance
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      credentials_file = write_authorized_user(root)
      write_gmail_config(root, credentials_file: credentials_file, id: "jer_gmail")
      refusing_runner = RefusingCommandRunner.new
      refusing_checker = RefusingDependencyChecker.new
      token_output = StringIO.new
      token_status = Cybort::CLI.start(
        ["--force-fetch"], home: directory, out: token_output, err: StringIO.new,
        output_mode: :diagnostic, http_client: GmailHttpFixture.new(responses: [Cybort::HttpError.new(status: 400)]),
        command_runner: refusing_runner, dependency_checker: refusing_checker
      )
      forbidden_output = StringIO.new
      forbidden_status = Cybort::CLI.start(
        ["--force-fetch"], home: directory, out: forbidden_output, err: StringIO.new,
        output_mode: :diagnostic, http_client: GmailHttpFixture.new(responses: [gmail_response(gmail_token_response), Cybort::HttpError.new(status: 403)]),
        command_runner: refusing_runner, dependency_checker: refusing_checker
      )
      FileUtils.rm(credentials_file)
      missing_output = StringIO.new
      missing_status = Cybort::CLI.start(
        ["--force-fetch"], home: directory, out: missing_output, err: StringIO.new,
        output_mode: :diagnostic, http_client: GmailHttpFixture.new(responses: []),
        command_runner: refusing_runner, dependency_checker: refusing_checker
      )

      assert_equal 1, token_status
      assert_includes token_output.string, "Reauthorize Gmail credentials."
      assert_equal 1, forbidden_status
      assert_includes forbidden_output.string, "Check Gmail scope, API enablement, and account/admin policy."
      assert_equal 1, missing_status
      assert_includes missing_output.string, "Configure credentials_file using README Gmail setup."
      [token_output, forbidden_output, missing_output].each do |stream|
        assert stream.string.lines.all? { |line| line.end_with?("\n") }
      end
    end
  end

  def test_command_fixture_dependency_preflight_remains_grouped_for_multiple_instances
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      write_command_fixture_config(root, ids: %w[z_fixture a_fixture])
      output = StringIO.new
      status = Cybort::CLI.start(
        ["--json", "--force-fetch"], home: directory, out: output, err: StringIO.new,
        registry: command_fixture_registry, dependency_checker: FakeDependencyChecker.new(available: false),
        command_runner: RefusingCommandRunner.new
      )

      payload = JSON.parse(output.string)
      assert_equal 1, status
      assert_equal ["a_fixture", "z_fixture"], payload.fetch("unavailable_dependencies").first.fetch("instances")
      assert_equal %w[failure failure], payload.fetch("instances").map { |entry| entry.fetch("status") }
      assert_equal "fixture-tool", payload.fetch("unavailable_dependencies").first.fetch("tool")
    end
  end

  def test_fresh_command_fixture_cache_skips_dependency_preflight
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      write_command_fixture_config(root)
      initial_checker = FakeDependencyChecker.new(available: true)
      first = Cybort::CLI.start(
        ["--json", "--force-fetch"], home: directory, out: StringIO.new, err: StringIO.new,
        registry: command_fixture_registry, dependency_checker: initial_checker,
        command_runner: RefusingCommandRunner.new
      )
      second_checker = FakeDependencyChecker.new(available: false)
      output = StringIO.new
      second = Cybort::CLI.start(
        ["--json"], home: directory, out: output, err: StringIO.new,
        registry: command_fixture_registry, dependency_checker: second_checker,
        command_runner: RefusingCommandRunner.new
      )

      assert_equal 0, first
      assert_equal 0, second
      assert_equal "cached", JSON.parse(output.string).fetch("instances").first.fetch("status")
      assert_empty second_checker.calls
    end
  end

  def test_forced_command_fixture_cache_still_runs_dependency_preflight
    Dir.mktmpdir do |directory|
      root = File.join(directory, ".cybort")
      write_command_fixture_config(root)
      first = Cybort::CLI.start(
        ["--json", "--force-fetch"], home: directory, out: StringIO.new, err: StringIO.new,
        registry: command_fixture_registry, dependency_checker: FakeDependencyChecker.new(available: true),
        command_runner: RefusingCommandRunner.new
      )
      checker = FakeDependencyChecker.new(available: false)
      output = StringIO.new
      second = Cybort::CLI.start(
        ["--json", "--force-fetch"], home: directory, out: output, err: StringIO.new,
        registry: command_fixture_registry, dependency_checker: checker,
        command_runner: RefusingCommandRunner.new
      )

      assert_equal 0, first
      assert_equal 1, second
      assert_equal "failure", JSON.parse(output.string).fetch("instances").first.fetch("status")
      assert_equal ["fixture-tool"], checker.calls
    end
  end
end
