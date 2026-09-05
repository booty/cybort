require "test_helper"

class RedditAdapterTest < Minitest::Test
  class StubRedditClient
    attr_reader :calls

    def initialize
      @calls = []
    end
  end

  class PipelineRedditClient
    attr_reader :calls, :subscriptions, :unread_pages, :home, :subreddits

    def initialize(subscriptions:, unread_pages:, home: [], subreddits: {}, safe_metadata: {})
      @subscriptions = subscriptions
      @unread_pages = unread_pages
      @home = home
      @subreddits = subreddits
      @safe_metadata = safe_metadata
      @calls = []
    end

    def authenticate(**credentials)
      @calls << Call.new(:authenticate, credentials)
      :session
    end

    def each_subscription_page(session:)
      @calls << Call.new(:subscriptions, session)
      subscriptions.each { |children| yield children }
    end

    def each_unread_page(session:)
      @calls << Call.new(:unread_messages, session)
      unread_pages.each { |children| yield children }
    end

    def home_hot(session:)
      @calls << Call.new(:home_hot, session)
      home
    end

    def subreddit_hot(session:, subreddit:, operation: :subreddit_hot)
      @calls << Call.new(operation, subreddit)
      subreddits.fetch(subreddit, [])
    end

    def safe_metadata
      @safe_metadata
    end

    Call = Struct.new(:operation, :value, keyword_init: false)
  end

  class StubCoordinator; end

  def test_accepts_valid_configuration_and_normalizes_subreddit_scope
    client = StubRedditClient.new
    adapter_instance = adapter(
      options: {
        include_subreddits: %w[AskScience news NEWS askscience],
        exclude_subreddits: %w[MEMES News memes]
      },
      reddit_client: client
    )

    assert_equal %w[askscience], adapter_instance.include_subreddits
    assert_equal %w[memes news], adapter_instance.exclude_subreddits
    assert_same client, adapter_instance.reddit_client
    assert_empty client.calls
  end

  def test_accepts_default_empty_subreddit_lists
    adapter_instance = adapter(options: {}, reddit_client: StubRedditClient.new)

    assert_empty adapter_instance.include_subreddits
    assert_empty adapter_instance.exclude_subreddits
  end

  def test_rejects_blank_credential_config
    %i[client_id client_secret refresh_token].each do |key|
      client = StubRedditClient.new

      assert_raises(Cybort::ConfigurationError) do
        adapter(options: { key => "   " }, reddit_client: client)
      end
      assert_empty client.calls
    end
  end

  def test_rejects_control_character_in_credential_config
    %i[client_id client_secret refresh_token].each do |key|
      ["secret\0value", "secret\u007fvalue"].each do |value|
        client = StubRedditClient.new

        assert_raises(Cybort::ConfigurationError) do
          adapter(options: { key => value }, reddit_client: client)
        end
        assert_empty client.calls
      end
    end
  end

  def test_rejects_credential_over_byte_limit_config
    { client_id: 256, client_secret: 1_024, refresh_token: 4_096 }.each do |key, maximum_bytes|
      client = StubRedditClient.new

      assert_raises(Cybort::ConfigurationError) do
        adapter(options: { key => "a" * (maximum_bytes + 1) }, reddit_client: client)
      end
      assert_empty client.calls
    end
  end

  def test_rejects_blank_control_and_overlong_user_agent_config
    ["   ", "macos:app:v1\0 (by /u/user)", "macos:app:v1\u007f (by /u/user)"].each do |value|
      client = StubRedditClient.new

      assert_raises(Cybort::ConfigurationError) do
        adapter(options: { user_agent: value }, reddit_client: client)
      end
      assert_empty client.calls
    end

    overlong = "macos:app:#{'v' * 240} (by /u/user)"
    assert_operator overlong.bytesize, :>, 256
    client = StubRedditClient.new
    assert_raises(Cybort::ConfigurationError) do
      adapter(options: { user_agent: overlong }, reddit_client: client)
    end
    assert_empty client.calls
  end

  def test_rejects_malformed_user_agent_config
    [
      ":app:v1 (by /u/user)",
      "macos::v1 (by /u/user)",
      "macos:app: (by /u/user)",
      "macos:app:v1 (by user)",
      "macos:app:v1 (by /u/user name)",
      "macos:app:v1 (by /u/user) trailing"
    ].each do |value|
      assert_raises(Cybort::ConfigurationError) do
        adapter(options: { user_agent: value }, reddit_client: StubRedditClient.new)
      end
    end
  end

  def test_rejects_non_array_subreddit_config
    %i[include_subreddits exclude_subreddits].each do |key|
      assert_raises(Cybort::ConfigurationError) do
        adapter(options: { key => "news" }, reddit_client: StubRedditClient.new)
      end
    end
  end

  def test_rejects_invalid_subreddit_names_config
    [
      ["include_subreddits", ["news", 42]],
      ["include_subreddits", [""]],
      ["include_subreddits", ["r/news"]],
      ["include_subreddits", ["news/posts"]],
      ["include_subreddits", ["news\0"]],
      ["exclude_subreddits", ["a"]],
      ["exclude_subreddits", ["a" * 22]]
    ].each do |key, value|
      assert_raises(Cybort::ConfigurationError) do
        adapter(options: { key.to_sym => value }, reddit_client: StubRedditClient.new)
      end
    end
  end

  def test_rejects_more_than_fifty_subreddits_config
    names = (1..51).map { |index| "sub#{index}" }

    %i[include_subreddits exclude_subreddits].each do |key|
      assert_raises(Cybort::ConfigurationError) do
        adapter(options: { key => names }, reddit_client: StubRedditClient.new)
      end
    end
  end

  def test_rejects_num_items_outside_reddit_bounds_config
    [0, 101].each do |value|
      assert_raises(Cybort::ConfigurationError) do
        adapter(num_items_to_fetch: value, reddit_client: StubRedditClient.new)
      end
    end
  end

  def test_accepts_num_items_at_reddit_bounds_config
    [1, 100].each do |value|
      instance = adapter(num_items_to_fetch: value, reddit_client: StubRedditClient.new)
      assert_equal value, instance.instance.num_items_to_fetch
    end
  end

  def test_uses_injected_coordinator_and_monotonic_clock
    coordinator = StubCoordinator.new
    monotonic_clock = -> { 12.5 }
    adapter_instance = adapter(
      reddit_client: StubRedditClient.new,
      coordinator: coordinator,
      monotonic_clock: monotonic_clock
    )

    assert_same coordinator, adapter_instance.coordinator
    assert_same monotonic_clock, adapter_instance.monotonic_clock
  end

  def test_executable_dependencies_are_empty
    assert_empty Cybort::Adapters::Reddit.executable_dependencies
    assert_empty adapter(reddit_client: StubRedditClient.new).executable_dependencies
  end

  def test_fetches_scope_messages_and_threads_without_multi_subreddit_paths
    client = PipelineRedditClient.new(
      subscriptions: [[subscription("ruby"), subscription("news"), subscription("memes")]],
      unread_pages: [[reddit_message("m1", subject: "Unread")]],
      home: [submission("a1", subreddit: "ruby", score: 100, comments: 20)],
      subreddits: {
        "askscience" => [submission("c3", subreddit: "askscience", score: 40, comments: 12)],
        "news" => [submission("d4", subreddit: "news", title: "LIVE THREAD: event", score: 75, comments: 55)]
      },
      safe_metadata: { ratelimit_remaining: 7.0 }
    )
    adapter_instance = adapter(
      options: { include_subreddits: %w[askscience news memes], exclude_subreddits: ["memes"] },
      num_items_to_fetch: 4,
      reddit_client: client
    )

    result = adapter_instance.fetch(force_fetch: true)

    assert result.success?
    assert_equal %w[news ruby], adapter_instance.joined_effective
    assert_equal ["askscience"], adapter_instance.explicit_to_fetch
    assert_equal 1, client.calls.count { |call| call.operation == :home_hot }
    assert_equal ["askscience"], client.calls.select { |call| call.operation == :subreddit_hot }.map(&:value)
    assert_equal ["news"], client.calls.select { |call| call.operation == :news_hot }.map(&:value)
    assert client.calls.none? { |call| call.value.to_s.include?("+") }
    assert result.replace_existing_items
    assert_equal "unsupported_by_documented_data_api", result.metadata.fetch(:chat_collection)
    assert_equal 7.0, result.metadata.fetch(:ratelimit_remaining)
    assert_equal ["t4_m1", "t3_d4", "t3_a1", "t3_c3"], result.items.map(&:canonical_id)
    assert result.items.all? { |item| item.body.nil? }
  end

  def test_filters_nonqualifying_unread_objects_before_message_quota
    client = PipelineRedditClient.new(
      subscriptions: [[]],
      unread_pages: [
        [
          { "kind" => "t1", "data" => { "id" => "reply", "name" => "t1_reply", "new" => true } },
          reddit_message("old", new: false),
          reddit_message("comment", was_comment: true),
          reddit_message("m1"),
        ],
        [reddit_message("m2")]
      ]
    )
    adapter_instance = adapter(num_items_to_fetch: 2, reddit_client: client)

    result = adapter_instance.fetch(force_fetch: true)

    assert result.success?
    assert_equal %w[t4_m1 t4_m2], result.items.map(&:canonical_id)
    assert_equal 1, client.calls.count { |call| call.operation == :unread_messages }
    refute result.items.any? { |item| item.body || item.info.key?(:author) || item.info.key?(:raw) }
  end

  def test_filters_out_of_scope_home_recommendations_but_fails_explicit_subreddit_mismatch
    home_client = PipelineRedditClient.new(
      subscriptions: [[subscription("ruby")]],
      unread_pages: [[]],
      home: [submission("outside", subreddit: "outside")]
    )
    home_result = adapter(reddit_client: home_client).fetch(force_fetch: true)
    assert home_result.success?
    assert_empty home_result.items

    explicit_client = PipelineRedditClient.new(
      subscriptions: [[]],
      unread_pages: [[]],
      subreddits: { "askscience" => [submission("wrong", subreddit: "news")] }
    )
    explicit_result = adapter(options: { include_subreddits: ["askscience"] }, reddit_client: explicit_client).fetch(force_fetch: true)
    refute explicit_result.success?
    assert_empty explicit_result.items
    refute explicit_result.replace_existing_items
  end

  def test_normalizes_duplicate_threads_using_dedicated_precedence_and_canonical_url
    client = PipelineRedditClient.new(
      subscriptions: [[subscription("ruby"), subscription("news")]],
      unread_pages: [[]],
      home: [submission("a1", subreddit: "news", title: "Home title", score: 1, comments: 1)],
      subreddits: {
        "ruby" => [],
        "news" => [submission("a1", subreddit: "news", title: "Dedicated title", score: 500, comments: 50),
                   submission("d4", subreddit: "news", title: "Mega thread", score: 10, comments: 10)]
      }
    )
    result = adapter(num_items_to_fetch: 3, reddit_client: client).fetch(force_fetch: true)

    assert result.success?
    ruby = result.items.find { |item| item.canonical_id == "t3_a1" }
    assert_equal "Dedicated title", ruby.title
    assert_equal ["https://www.reddit.com/r/news/comments/a1/example-title/"], ruby.urls
    assert_equal 500, ruby.info.fetch(:vote_score)
    assert_equal 50, ruby.info.fetch(:comment_count)
  end

  def test_rejects_permalink_attacks_and_malformed_required_pages
    [
      "https://evil.test/r/news/comments/a1/title",
      "//evil.test/r/news/comments/a1/title",
      "/r/news/comments/a1/title?x=1",
      "/r/news/comments/a1/title%2fescape",
      "/r/news/comments/a1/%2e%2e/escape",
      "/r/news/comments/a1/title%00"
    ].each do |permalink|
      client = PipelineRedditClient.new(
        subscriptions: [[subscription("news")]],
        unread_pages: [[]],
        home: [submission("a1", subreddit: "news", permalink: permalink)]
      )
      result = adapter(reddit_client: client).fetch(force_fetch: true)
      refute result.success?, permalink
      refute result.replace_existing_items
    end
  end

  private

  def adapter(options: {}, num_items_to_fetch: 25, reddit_client:, coordinator: Cybort::RedditRateLimitCoordinator.default,
              monotonic_clock: -> { 0.0 })
    Cybort::Adapters::Reddit.new(
      instance: instance(options: options, num_items_to_fetch: num_items_to_fetch),
      context: { items: [], last_successful_fetch: nil, sync_state: nil },
      http_client: nil,
      clock: -> { Time.utc(2026, 9, 5, 12) },
      reddit_client: reddit_client,
      coordinator: coordinator,
      monotonic_clock: monotonic_clock
    )
  end

  def instance(options:, num_items_to_fetch: 25)
    Cybort::Configuration::Instance.new(
      id: "reddit",
      name: "Reddit",
      adapter: "reddit",
      ttl_minutes: 30,
      num_items_to_fetch: num_items_to_fetch,
      options: base_options.merge(options)
    )
  end

  def base_options
    {
      client_id: "client-id",
      client_secret: "client-secret",
      refresh_token: "refresh-token",
      user_agent: "macos:com.example.cybort:v1 (by /u/example_user)"
    }
  end

  def subscription(name)
    { "kind" => "t5", "data" => { "id" => name, "name" => "t5_#{name}", "display_name" => name.capitalize } }
  end

  def reddit_message(id, subject: "Message", new: true, was_comment: false)
    data = { "id" => id, "name" => "t4_#{id}", "new" => new, "created_utc" => 1_788_681_600, "subject" => subject }
    data["was_comment"] = was_comment unless was_comment.nil?
    { "kind" => "t4", "data" => data }
  end

  def submission(id, subreddit:, title: "Thread", score: 100, comments: 10,
                 permalink: "/r/#{subreddit}/comments/#{id}/example-title/", created_utc: 1_788_678_000)
    {
      "kind" => "t3",
      "data" => {
        "id" => id,
        "name" => "t3_#{id}",
        "subreddit" => subreddit,
        "title" => title,
        "score" => score,
        "num_comments" => comments,
        "created_utc" => created_utc,
        "stickied" => false,
        "permalink" => permalink
      }
    }
  end
end
