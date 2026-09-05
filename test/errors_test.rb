require_relative "test_helper"

class ErrorsTest < Minitest::Test
  def test_command_error_freezes_allow_listed_scalar_metadata
    error = Cybort::CommandError.new(
      "gws command failed",
      metadata: { tool: "gws", operation: "list", exit_category: "nonzero", exit_code: 1 }
    )

    assert_equal "gws command failed", error.message
    assert error.safe_metadata.frozen?
    assert_equal "gws", error.safe_metadata.fetch(:tool)
    assert_raises(ArgumentError) do
      Cybort::CommandError.new("unsafe", metadata: { stderr: "secret" })
    end
  end

  def test_command_error_rejects_non_scalar_or_oversized_metadata
    assert_raises(ArgumentError) do
      Cybort::CommandError.new("unsafe", metadata: { tool: ["gws"] })
    end
    assert_raises(ArgumentError) do
      Cybort::CommandError.new("unsafe", metadata: { tool: "x" * 300 })
    end
  end

  def test_http_error_exposes_only_safe_status_and_rate_metadata
    error = Cybort::HttpError.new(
      status: 429,
      headers: { "retry-after" => "5", "authorization" => "Bearer secret" }
    )

    assert_equal({ status: 429, retry_after_seconds: 5 }, error.safe_metadata)
    refute_includes error.message, "secret"
  end

  def test_reddit_api_error_exposes_allowlisted_metadata_without_secrets
    error = Cybort::RedditApiError.new(
      operation: :subscriptions,
      category: :authorization,
      status: 403,
      rate_metadata: { ratelimit_remaining: 0.0 },
      token: "secret-token",
      response_body: "private title",
      url: "https://reddit.example.test/private"
    )

    assert_equal :subscriptions, error.safe_metadata.fetch(:operation)
    assert_equal :authorization, error.safe_metadata.fetch(:category)
    assert_equal 403, error.safe_metadata.fetch(:status)
    assert_equal 0.0, error.safe_metadata.fetch(:ratelimit_remaining)
    refute_includes error.message, "secret-token"
    refute_includes error.message, "private title"
    refute_includes error.message, "reddit.example.test"
  end

  def test_http_transport_error_has_only_a_safe_category
    error = Cybort::HttpTransportError.new(category: :response_too_large)

    assert_equal({ category: :response_too_large }, error.safe_metadata)
    refute_includes error.message, "https://"
  end
end
