require "test_helper"

class RateLimitHeadersTest < Minitest::Test
  def test_parses_case_insensitive_safe_values
    parsed = Cybort::RateLimitHeaders.parse(
      "X-Ratelimit-Used" => "3.5",
      "x-ratelimit-remaining" => "0",
      "X-RATELIMIT-RESET" => "42.25",
      "Retry-After" => "7"
    )

    assert_equal 3.5, parsed.fetch(:ratelimit_used)
    assert_equal 0.0, parsed.fetch(:ratelimit_remaining)
    assert_equal 42.25, parsed.fetch(:ratelimit_reset_seconds)
    assert_equal 7, parsed.fetch(:retry_after_seconds)
    assert parsed.frozen?
  end

  def test_omits_negative_nonfinite_and_http_date_values
    parsed = Cybort::RateLimitHeaders.parse(
      "x-ratelimit-used" => "NaN",
      "x-ratelimit-remaining" => "-1",
      "x-ratelimit-reset" => "Infinity",
      "retry-after" => "Wed, 21 Oct 2015 07:28:00 GMT"
    )

    assert_empty parsed
  end

  def test_omits_malformed_and_unknown_values
    parsed = Cybort::RateLimitHeaders.parse(
      "x-ratelimit-used" => "not-a-number",
      "x-ratelimit-remaining" => "",
      "x-ratelimit-reset" => "1.2.3",
      "retry-after" => "-1",
      "x-other" => "secret"
    )

    assert_empty parsed
  end

  def test_accepts_canonical_metadata_keys_when_reprocessing_safe_metadata
    parsed = Cybort::RateLimitHeaders.parse(
      ratelimit_used: 3.5,
      ratelimit_remaining: 1.0,
      ratelimit_reset_seconds: 12.0,
      retry_after_seconds: 7
    )

    assert_equal(
      {
        ratelimit_used: 3.5,
        ratelimit_remaining: 1.0,
        ratelimit_reset_seconds: 12.0,
        retry_after_seconds: 7
      },
      parsed
    )
  end
end
