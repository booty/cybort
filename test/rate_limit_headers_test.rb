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

  def test_omits_negative_nonfinite_and_malformed_http_date_values
    parsed = Cybort::RateLimitHeaders.parse(
      "x-ratelimit-used" => "NaN",
      "x-ratelimit-remaining" => "-1",
      "x-ratelimit-reset" => "Infinity",
      "retry-after" => "not a date"
    )

    assert_empty parsed
  end

  def test_normalizes_http_date_retry_after_against_supplied_time
    now = Time.utc(2026, 9, 6, 12)

    parsed = Cybort::RateLimitHeaders.parse(
      { "Retry-After" => "Sun, 06 Sep 2026 12:01:30 GMT" }, now: now
    )

    assert_equal({ retry_after_seconds: 90 }, parsed)
  end

  def test_clamps_past_http_date_to_zero
    parsed = Cybort::RateLimitHeaders.parse(
      { "retry-after" => "Sun, 06 Sep 2026 11:59:59 GMT" },
      now: Time.utc(2026, 9, 6, 12)
    )

    assert_equal({ retry_after_seconds: 0 }, parsed)
  end

  def test_rejects_control_and_overlong_retry_after_text
    control = Cybort::RateLimitHeaders.parse(
      { "retry-after" => "12\n" }, now: Time.utc(2026, 9, 6, 12)
    )
    overlong = Cybort::RateLimitHeaders.parse(
      { "retry-after" => "9" * 129 }, now: Time.utc(2026, 9, 6, 12)
    )

    assert_empty control
    assert_empty overlong
  end

  def test_retains_a_128_byte_numeric_retry_after_without_float_capping
    value = "9" * 128

    parsed = Cybort::RateLimitHeaders.parse("retry-after" => value)

    assert_equal Integer(value, 10), parsed.fetch(:retry_after_seconds)
    assert_instance_of Integer, parsed.fetch(:retry_after_seconds)
  end

  def test_retains_a_far_future_http_date_as_a_finite_integer_delay
    parsed = Cybort::RateLimitHeaders.parse(
      { "retry-after" => "Sun, 06 Sep 3026 12:00:00 GMT" },
      now: Time.utc(2026, 9, 6, 12)
    )

    assert_instance_of Integer, parsed.fetch(:retry_after_seconds)
    assert_operator parsed.fetch(:retry_after_seconds), :>, 0
  end

  def test_supports_the_original_inline_keyword_like_hash_form
    parsed = Cybort::RateLimitHeaders.parse(retry_after_seconds: 7)

    assert_equal({ retry_after_seconds: 7 }, parsed)
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
