require "test_helper"

class RedditAdapterTest < Minitest::Test
  class StubRedditClient
    attr_reader :calls

    def initialize
      @calls = []
    end
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
end
