require "test_helper"

class GithubAdapterTest < Minitest::Test
  class StubHttpClient
    attr_reader :calls

    def initialize(body: nil, error: nil)
      @body = body
      @error = error
      @calls = []
    end

    def get(url, headers: {})
      @calls << [url, headers]
      raise @error if @error

      Cybort::HttpResponse.new(status: 200, headers: {}, body: @body)
    end
  end

  def instance(token: "secret", num_items_to_fetch: 2)
    Cybort::Configuration::Instance.new(
      id: "github",
      name: "GitHub",
      adapter: "github",
      ttl_minutes: 30,
      num_items_to_fetch: num_items_to_fetch,
      options: { api_url: "https://api.example.test/notifications", token: token }
    )
  end

  def adapter(body: File.read(File.expand_path("../fixtures/github/notifications.json", __dir__)), token: "secret", num_items_to_fetch: 2, error: nil)
    Cybort::Adapters::GitHub.new(
      instance: instance(token: token, num_items_to_fetch: num_items_to_fetch),
      context: { items: [], last_successful_fetch: nil, sync_state: nil },
      http_client: StubHttpClient.new(body: body, error: error),
      clock: -> { Time.utc(2026, 8, 16, 12) }
    )
  end

  def test_maps_nested_notification_fields_and_limits_items
    result = adapter(num_items_to_fetch: 1).fetch
    item = result.items.first

    assert result.success?
    assert_equal 1, result.items.length
    assert_equal "1001", item.canonical_id
    assert_equal "Mentioned in issue", item.title
    assert_equal ["https://api.github.com/repos/john/project/issues/1", "https://github.com/john/project"], item.urls
    assert_equal Time.utc(2026, 8, 16, 11), item.remote_created_at
    assert_equal "mention", item.info.fetch(:reason)
    assert_equal "john/project", item.info.fetch(:repository)
  end

  def test_sends_github_headers
    http_client = StubHttpClient.new(body: "[]")
    adapter_instance = Cybort::Adapters::GitHub.new(
      instance: instance,
      context: { items: [], last_successful_fetch: nil, sync_state: nil },
      http_client: http_client,
      clock: -> { Time.utc(2026, 8, 16, 12) }
    )

    adapter_instance.fetch

    headers = http_client.calls.first.fetch(1)
    assert_equal "application/vnd.github+json", headers.fetch("Accept")
    assert_equal "Bearer secret", headers.fetch("Authorization")
  end

  def test_requires_token
    assert_raises(Cybort::ConfigurationError) { adapter(token: "") }
  end

  def test_http_failure_becomes_failure_result
    result = adapter(error: Cybort::SourceError.new("GitHub unavailable")).fetch

    refute result.success?
    assert_includes result.error.message, "GitHub unavailable"
    assert_empty result.items
  end
end

