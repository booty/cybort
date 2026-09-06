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

  def test_list_caps_before_deduplicating_and_does_not_follow_pages
    http = GmailHttpFixture.new(responses: [token_response, response({
      "messages" => [{"id" => "one"}, {"id" => "one"}, {"id" => "two"}],
      "nextPageToken" => "unused-page"
    })])
    gmail = client(http)
    gmail.authenticate(credentials: credentials)

    ids = gmail.list_message_ids(user_id: "me", query: "in:anywhere",
                                 limit: 2, include_spam_trash: true)

    assert_equal ["one"], ids
    params = URI.decode_www_form(URI(http.calls.last.fetch(:url)).query).to_h
    assert_equal "2", params.fetch("maxResults")
    assert_equal "true", params.fetch("includeSpamTrash")
    assert_equal "in:anywhere", params.fetch("q")
    assert_equal 2, http.calls.length
  end

  def test_detail_id_mismatch_is_safe
    http = GmailHttpFixture.new(responses: [token_response, response({"id" => "other"})])
    gmail = client(http)
    gmail.authenticate(credentials: credentials)

    error = assert_raises(Cybort::GmailApiError) do
      gmail.get_message(user_id: "me", message_id: "one")
    end

    assert_equal :invalid_identity, error.safe_metadata.fetch(:category)
    refute_includes error.message, "other"
  end

  def test_list_accepts_absent_or_empty_messages
    [{}, {"messages" => []}].each do |payload|
      http = GmailHttpFixture.new(responses: [token_response, response(payload)])
      gmail = client(http)
      gmail.authenticate(credentials: credentials)

      assert_equal [], gmail.list_message_ids(user_id: "me", query: "", limit: 2,
                                              include_spam_trash: false)
    end
  end

  def test_list_rejects_null_or_wrong_type_messages
    [nil, {}, "messages", 1].each do |messages|
      http = GmailHttpFixture.new(responses: [token_response, response("messages" => messages)])
      gmail = client(http)
      gmail.authenticate(credentials: credentials)

      error = assert_raises(Cybort::GmailApiError) do
        gmail.list_message_ids(user_id: "me", query: "", limit: 2, include_spam_trash: false)
      end

      assert_equal :invalid_shape, error.safe_metadata.fetch(:category)
    end
  end

  def test_list_inspects_only_the_prefix_and_ignores_records_after_limit
    http = GmailHttpFixture.new(responses: [token_response, response(
      "messages" => [{"id" => "one"}, {"id" => "two"}, nil]
    )])
    gmail = client(http)
    gmail.authenticate(credentials: credentials)

    assert_equal ["one", "two"], gmail.list_message_ids(user_id: "me", query: "",
                                                           limit: 2, include_spam_trash: false)
  end

  def test_list_rejects_bad_records_in_inspected_prefix
    [nil, [], {"id" => nil}, {"id" => ""}, {"id" => "."}, {"id" => ".."},
     {"id" => "a\u0000b"}, {"id" => 1}, {"id" => "a" * 257}].each do |record|
      http = GmailHttpFixture.new(responses: [token_response, response("messages" => [record])])
      gmail = client(http)
      gmail.authenticate(credentials: credentials)

      error = assert_raises(Cybort::GmailApiError) do
        gmail.list_message_ids(user_id: "me", query: "", limit: 1, include_spam_trash: false)
      end

      assert_equal :invalid_identity, error.safe_metadata.fetch(:category)
    end
  end

  def test_query_is_encoded_and_blank_query_is_omitted
    query = "from:a&subject:✓"
    http = GmailHttpFixture.new(responses: [token_response, response("messages" => [])])
    gmail = client(http)
    gmail.authenticate(credentials: credentials)
    gmail.list_message_ids(user_id: "me", query: query, limit: 2, include_spam_trash: false)

    uri = URI(http.calls.last.fetch(:url))
    params = URI.decode_www_form(uri.query).to_h
    assert_equal query, params.fetch("q")

    no_query_http = GmailHttpFixture.new(responses: [token_response, response({})])
    no_query_gmail = client(no_query_http)
    no_query_gmail.authenticate(credentials: credentials)
    no_query_gmail.list_message_ids(user_id: "me", query: " \t", limit: 2,
                                    include_spam_trash: false)
    refute URI(no_query_http.calls.last.fetch(:url)).query.include?("q=")
  end

  def test_get_uses_encoded_path_segments_and_requested_metadata
    message_id = "one/two + ✓"
    payload = {"id" => message_id, "snippet" => "hello", "internalDate" => "bad"}
    http = GmailHttpFixture.new(responses: [token_response, response(payload)])
    gmail = client(http)
    gmail.authenticate(credentials: credentials)
    assert_equal payload, gmail.get_message(user_id: "a+b@example.com", message_id: message_id)

    call = http.calls.last
    assert_equal :get, call.fetch(:method)
    assert_equal "Bearer fake-access", call.fetch(:headers).fetch("Authorization")
    assert_equal 1, call.fetch(:headers).length
    uri = URI(call.fetch(:url))
    assert_equal "/gmail/v1/users/a%2Bb%40example.com/messages/one%2Ftwo%20%2B%20%E2%9C%93", uri.path
    pairs = URI.decode_www_form(uri.query)
    assert_equal "metadata", pairs.assoc("format").last
    assert_equal "id,threadId,labelIds,snippet,internalDate,payload/headers", pairs.assoc("fields").last
    assert_equal %w[Subject From Date Message-ID], pairs.select { |key, _| key == "metadataHeaders" }.map(&:last)
    refute_includes call.fetch(:url), "fake-access"
  end

  def test_me_is_used_as_a_literal_path_segment
    http = GmailHttpFixture.new(responses: [token_response, response({"id" => "one"})])
    gmail = client(http)
    gmail.authenticate(credentials: credentials)
    gmail.get_message(user_id: "me", message_id: "one")

    assert_equal "/gmail/v1/users/me/messages/one", URI(http.calls.last.fetch(:url)).path
  end

  def test_invalid_detail_ids_do_not_make_http_calls
    [nil, "", " ", ".", "..", "a\u0000b", 1, "a" * 257].each do |message_id|
      http = GmailHttpFixture.new(responses: [token_response])
      gmail = client(http)
      gmail.authenticate(credentials: credentials)

      error = assert_raises(Cybort::GmailApiError) do
        gmail.get_message(user_id: "me", message_id: message_id)
      end

      assert_equal :invalid_identity, error.safe_metadata.fetch(:category)
      assert_equal 1, http.calls.length
    end
  end

  def test_get_rejects_404_without_returning_a_partial_result
    http = GmailHttpFixture.new(responses: [token_response, Cybort::HttpError.new(status: 404)])
    gmail = client(http)
    gmail.authenticate(credentials: credentials)

    error = assert_raises(Cybort::GmailApiError) do
      gmail.get_message(user_id: "me", message_id: "one")
    end

    assert_equal :get, error.safe_metadata.fetch(:operation)
    assert_equal :http, error.safe_metadata.fetch(:category)
    assert_equal 404, error.safe_metadata.fetch(:status)
  end

  def test_optional_get_fields_allow_null_and_malformed_internal_date
    payload = {
      "id" => "one", "snippet" => nil, "threadId" => nil, "labelIds" => nil,
      "payload" => {"headers" => nil}, "internalDate" => "not-a-date"
    }
    http = GmailHttpFixture.new(responses: [token_response, response(payload)])
    gmail = client(http)
    gmail.authenticate(credentials: credentials)

    assert_equal payload, gmail.get_message(user_id: "me", message_id: "one")
  end

  def test_optional_get_fields_reject_wrong_types
    {
      "snippet" => 1,
      "threadId" => [],
      "labelIds" => ["ok", 1],
      "payload" => []
    }.each do |key, value|
      payload = {"id" => "one"}
      payload[key] = value
      http = GmailHttpFixture.new(responses: [token_response, response(payload)])
      gmail = client(http)
      gmail.authenticate(credentials: credentials)

      error = assert_raises(Cybort::GmailApiError) do
        gmail.get_message(user_id: "me", message_id: "one")
      end

      assert_equal :invalid_shape, error.safe_metadata.fetch(:category)
    end

    payload = {"id" => "one", "payload" => {"headers" => [{}]}}
    http = GmailHttpFixture.new(responses: [token_response, response(payload)])
    gmail = client(http)
    gmail.authenticate(credentials: credentials)
    error = assert_raises(Cybort::GmailApiError) do
      gmail.get_message(user_id: "me", message_id: "one")
    end
    assert_equal :invalid_shape, error.safe_metadata.fetch(:category)

    [{"name" => "Subject"}, {"value" => "x"}, "header"].each do |header|
      payload = {"id" => "one", "payload" => {"headers" => [header]}}
      http = GmailHttpFixture.new(responses: [token_response, response(payload)])
      gmail = client(http)
      gmail.authenticate(credentials: credentials)

      error = assert_raises(Cybort::GmailApiError) do
        gmail.get_message(user_id: "me", message_id: "one")
      end

      assert_equal :invalid_shape, error.safe_metadata.fetch(:category)
    end
  end

  def test_expired_token_and_deadline_prevent_gmail_calls
    expired_http = GmailHttpFixture.new(responses: [token_response("expires_in" => 1)])
    expired_times = [0.0, 0.0, 1.0]
    expired_clock = -> { expired_times.shift || 1.0 }
    expired = client(expired_http, now: expired_clock)
    expired.authenticate(credentials: credentials)
    error = assert_raises(Cybort::GmailApiError) do
      expired.list_message_ids(user_id: "me", query: "", limit: 1, include_spam_trash: false)
    end
    assert_equal :token_expired, error.safe_metadata.fetch(:category)
    assert_equal 1, expired_http.calls.length

    deadline_http = GmailHttpFixture.new(responses: [token_response])
    deadline = client(deadline_http, now: -> { 300.0 }, deadline: 300.0)
    error = assert_raises(Cybort::GmailApiError) do
      deadline.authenticate(credentials: credentials)
    end
    assert_equal :deadline, error.safe_metadata.fetch(:category)
    assert_empty deadline_http.calls
  end

  def test_clients_do_not_share_access_tokens
    first_http = GmailHttpFixture.new(responses: [token_response("access_token" => "first"), response({"id" => "one"})])
    second_http = GmailHttpFixture.new(responses: [token_response("access_token" => "second"), response({"id" => "two"})])
    first = client(first_http)
    second = client(second_http)
    first.authenticate(credentials: credentials)
    second.authenticate(credentials: credentials)
    first.get_message(user_id: "me", message_id: "one")
    second.get_message(user_id: "me", message_id: "two")

    assert_equal "Bearer first", first_http.calls.last.fetch(:headers).fetch("Authorization")
    assert_equal "Bearer second", second_http.calls.last.fetch(:headers).fetch("Authorization")
  end
end
