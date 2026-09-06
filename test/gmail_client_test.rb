require "test_helper"
require "support/gmail_http_fixture"

class GmailClientTest < Minitest::Test
  READONLY_SCOPE = "https://www.googleapis.com/auth/gmail.readonly"
  Credentials = Struct.new(:client_id, :client_secret, :refresh_token, keyword_init: true)

  def response(payload)
    Cybort::HttpResponse.new(status: 200, headers: {}, body: JSON.generate(payload))
  end

  def response_body(body)
    Cybort::HttpResponse.new(status: 200, headers: {}, body: body)
  end

  def credentials
    Credentials.new(
      client_id: "fake-client",
      client_secret: "fake-secret",
      refresh_token: "fake-refresh"
    )
  end

  def token_response(overrides = {})
    response({
      "access_token" => "fake-access",
      "token_type" => "Bearer",
      "expires_in" => 3_600
    }.merge(overrides))
  end

  def client(http, now: -> { 0.0 }, deadline: 300.0)
    Cybort::GmailClient.new(
      http_client: http,
      monotonic_clock: now,
      deadline_monotonic: deadline
    )
  end

  def test_refresh_uses_fixed_endpoint_and_form_without_bearer_header
    http = GmailHttpFixture.new(responses: [token_response])

    assert_nil client(http).authenticate(credentials: credentials)

    call = http.calls.fetch(0)
    assert_equal :post_form, call.fetch(:method)
    assert_equal "https://oauth2.googleapis.com/token", call.fetch(:url)
    assert_equal({ grant_type: "refresh_token", client_id: "fake-client",
                   client_secret: "fake-secret", refresh_token: "fake-refresh" },
                 call.fetch(:form))
    assert_equal 30.0, call.fetch(:timeout_seconds)
    assert_equal 30.0, call.fetch(:deadline_monotonic)
    refute call.fetch(:headers).key?("Authorization")
  end

  def test_token_rejection_preserves_safe_status
    http = GmailHttpFixture.new(responses: [Cybort::HttpError.new(status: 400)])

    error = assert_raises(Cybort::GmailApiError) do
      client(http).authenticate(credentials: credentials)
    end

    assert_equal :authentication, error.safe_metadata.fetch(:category)
    assert_equal :token, error.safe_metadata.fetch(:operation)
    assert_equal 400, error.safe_metadata.fetch(:status)
    refute_includes error.message, "fake-secret"
  end

  def test_malformed_token_json_is_invalid_json
    http = GmailHttpFixture.new(responses: [response_body("{")])

    error = assert_raises(Cybort::GmailApiError) do
      client(http).authenticate(credentials: credentials)
    end

    assert_equal :invalid_json, error.safe_metadata.fetch(:category)
    assert_equal 1, http.calls.length
  end

  def test_non_object_token_json_is_invalid_shape
    http = GmailHttpFixture.new(responses: [response(["access-token"])])

    error = assert_raises(Cybort::GmailApiError) do
      client(http).authenticate(credentials: credentials)
    end

    assert_equal :invalid_shape, error.safe_metadata.fetch(:category)
  end

  def test_blank_control_and_oversized_access_tokens_are_invalid_shape
    ["", "   ", "bad\u0000token", "a" * 8_193].each do |access_token|
      http = GmailHttpFixture.new(responses: [token_response("access_token" => access_token)])

      error = assert_raises(Cybort::GmailApiError) do
        client(http).authenticate(credentials: credentials)
      end

      assert_equal :invalid_shape, error.safe_metadata.fetch(:category)
    end
  end

  def test_token_type_must_be_case_insensitive_bearer
    [nil, "", "Basic", 1].each do |token_type|
      http = GmailHttpFixture.new(responses: [token_response("token_type" => token_type)])

      error = assert_raises(Cybort::GmailApiError) do
        client(http).authenticate(credentials: credentials)
      end

      assert_equal :invalid_shape, error.safe_metadata.fetch(:category)
    end

    assert_nil client(GmailHttpFixture.new(responses: [token_response("token_type" => "bEaReR")])).authenticate(credentials: credentials)
  end

  def test_expiry_must_be_a_positive_integer
    [0, -1, 1.5, "3600", nil].each do |expires_in|
      http = GmailHttpFixture.new(responses: [token_response("expires_in" => expires_in)])

      error = assert_raises(Cybort::GmailApiError) do
        client(http).authenticate(credentials: credentials)
      end

      assert_equal :invalid_shape, error.safe_metadata.fetch(:category)
    end
  end

  def test_scope_may_be_absent_but_present_scope_must_include_readonly_scope
    assert_nil client(GmailHttpFixture.new(responses: [token_response])).authenticate(credentials: credentials)

    [nil, [READONLY_SCOPE], "https://www.googleapis.com/auth/gmail.modify"].each do |scope|
      http = GmailHttpFixture.new(responses: [token_response("scope" => scope)])

      error = assert_raises(Cybort::GmailApiError) do
        client(http).authenticate(credentials: credentials)
      end

      assert_equal :scope, error.safe_metadata.fetch(:category)
    end

    assert_nil client(GmailHttpFixture.new(responses: [token_response("scope" => "openid #{READONLY_SCOPE} profile")])).authenticate(credentials: credentials)
  end

  def test_http_statuses_are_classified_without_exposing_response_bodies
    { 403 => :authorization, 429 => :rate_limited, 500 => :http }.each do |status, category|
      http = GmailHttpFixture.new(responses: [Cybort::HttpError.new(status: status)])

      error = assert_raises(Cybort::GmailApiError) do
        client(http).authenticate(credentials: credentials)
      end

      assert_equal category, error.safe_metadata.fetch(:category)
      assert_equal status, error.safe_metadata.fetch(:status)
      refute_includes error.message, "fake-access"
    end
  end

  def test_transport_failures_preserve_only_the_safe_category
    { network: :network, timeout: :timeout, response_too_large: :response_too_large }.each do |transport_category, category|
      http = GmailHttpFixture.new(
        responses: [Cybort::HttpTransportError.new(category: transport_category)]
      )

      error = assert_raises(Cybort::GmailApiError) do
        client(http).authenticate(credentials: credentials)
      end

      assert_equal :token, error.safe_metadata.fetch(:operation)
      assert_equal category, error.safe_metadata.fetch(:category)
      refute_includes error.message, "fake"
    end
  end

  def test_deadline_crossing_never_passes_non_positive_budget_to_http
    http = GmailHttpFixture.new(responses: [token_response])
    times = [0.0, 299.0, 300.0, 300.0]
    now = -> { times.shift || 300.0 }

    error = assert_raises(Cybort::GmailApiError) do
      client(http, now: now, deadline: 300.0).authenticate(credentials: credentials)
    end

    assert_equal :deadline, error.safe_metadata.fetch(:category)
    assert_equal 1, http.calls.length
    assert_equal 1.0, http.calls.fetch(0).fetch(:timeout_seconds)
  end

  def test_request_deadline_is_capped_by_attempt_deadline
    http = GmailHttpFixture.new(responses: [token_response])

    assert_nil client(http, now: -> { 295.0 }, deadline: 300.0).authenticate(credentials: credentials)

    call = http.calls.fetch(0)
    assert_equal 5.0, call.fetch(:timeout_seconds)
    assert_equal 300.0, call.fetch(:deadline_monotonic)
  end

  def test_response_after_request_deadline_is_a_timeout
    times = [0.0, 0.0, 31.0]
    http = GmailHttpFixture.new(responses: [token_response])
    clock = -> { times.shift || 31.0 }

    error = assert_raises(Cybort::GmailApiError) do
      client(http, now: clock, deadline: 300.0).authenticate(credentials: credentials)
    end

    assert_equal :timeout, error.safe_metadata.fetch(:category)
    assert_equal 1, http.calls.length
  end

  def test_client_inspection_is_redacted
    http = GmailHttpFixture.new(responses: [token_response])
    gmail = client(http)
    gmail.authenticate(credentials: credentials)

    refute_includes gmail.inspect, "fake-access"
    refute_includes gmail.inspect, "fake-secret"
    refute_includes gmail.to_s, "fake-access"
    refute_includes gmail.to_s, "fake-secret"
  end
end
