require "test_helper"
require "uri"

class RedditClientTest < Minitest::Test
  Response = Struct.new(:status, :headers, :body, keyword_init: true)

  class FakeClock
    attr_reader :now

    def initialize(now = 0.0)
      @now = now
    end

    def call
      @now
    end

    def advance(seconds)
      @now += seconds
    end
  end

  class FakeHttpClient
    attr_reader :calls

    def initialize(responses: [], error: nil, &response_block)
      @responses = responses.dup
      @error = error
      @response_block = response_block
      @calls = []
    end

    def post_form(url, form:, headers:, timeout_seconds:)
      @calls << { method: :post_form, url: url, form: form, headers: headers, timeout_seconds: timeout_seconds }
      response_or_error
    end

    def get(url, headers:, timeout_seconds:)
      @calls << { method: :get, url: url, headers: headers, timeout_seconds: timeout_seconds }
      response_or_error
    end

    private

    def response_or_error
      raise @error if @error && @calls.length > 1
      return @response_block.call(@calls.last) if @response_block

      @responses.shift || raise("missing fake response")
    end
  end

  def setup
    @clock = FakeClock.new
    @http = FakeHttpClient.new(
      responses: [
        response({
          access_token: "test-access",
          token_type: "bearer",
          expires_in: 3600,
          scope: "read mysubreddits privatemessages"
        }),
        listing(children: [{ "kind" => "t5", "data" => { "id" => "abc", "name" => "t5_abc" } }], after: "t5_def"),
        listing(children: [], after: nil)
      ]
    )
    @client = Cybort::RedditClient.new(
      http_client: @http,
      coordinator: Cybort::RedditRateLimitCoordinator.new(clock: @clock.method(:call), sleeper: ->(seconds) { @clock.advance(seconds) }),
      clock: @clock.method(:call),
      deadline_seconds: 120,
      request_limit: 90
    )
  end

  def test_authenticates_with_basic_form_and_validates_bearer_token
    session = @client.authenticate(
      client_id: "client-id",
      client_secret: "client-secret",
      refresh_token: "refresh-token",
      user_agent: "macos:com.example.cybort:v0.1.0 (by /u/test_user)"
    )

    assert session
    call = @http.calls.first
    assert_equal :post_form, call.fetch(:method)
    assert_equal "https://www.reddit.com/api/v1/access_token", call.fetch(:url)
    assert_equal({ grant_type: "refresh_token", refresh_token: "refresh-token" }, call.fetch(:form))
    assert_equal "Basic #{['client-id:client-secret'].pack('m0')}", call.fetch(:headers).fetch("Authorization")
    assert_equal "macos:com.example.cybort:v0.1.0 (by /u/test_user)", call.fetch(:headers).fetch("User-Agent")
    refute_includes call.fetch(:url), "refresh-token"
  end

  def test_accepts_wildcard_scope_and_case_insensitive_bearer
    @http = FakeHttpClient.new(responses: [response({ access_token: "token", token_type: "BEARER", expires_in: 1.5, scope: "*" })])
    client = build_client

    assert client.authenticate(
      client_id: "client-id",
      client_secret: "client-secret",
      refresh_token: "refresh-token",
      user_agent: valid_user_agent
    )
  end

  def test_rejects_invalid_credentials_before_network_call
    [" ", "bad\0value", "bad\u007fvalue"].each do |value|
      client = build_client
      assert_raises(Cybort::ValidationError) do
        client.authenticate(client_id: value, client_secret: "secret", refresh_token: "refresh", user_agent: valid_user_agent)
      end
      assert_empty @http.calls
    end
  end

  def test_rejects_invalid_token_response_without_exposing_body
    [
      [{ access_token: "", token_type: "bearer", expires_in: 1, scope: "*" }, :invalid_shape],
      [{ access_token: "token", token_type: "mac", expires_in: 1, scope: "*" }, :invalid_shape],
      [{ access_token: "token", token_type: "bearer", expires_in: 0, scope: "*" }, :invalid_shape],
      [{ access_token: "token", token_type: "bearer", expires_in: "nope", scope: "*" }, :invalid_shape],
      [{ access_token: "token", token_type: "bearer", expires_in: 1, scope: "read" }, :authorization]
    ].each do |payload|
      @http = FakeHttpClient.new(responses: [response(payload.fetch(0))])
      error = assert_raises(Cybort::RedditApiError) do
        build_client.authenticate(
          client_id: "client-id",
          client_secret: "client-secret",
          refresh_token: "refresh-token",
          user_agent: valid_user_agent
        )
      end
      assert_equal payload.fetch(1), error.safe_metadata.fetch(:category)
      refute_includes error.message, "private title"
    end
  end

  def test_subscriptions_paginate_with_valid_cursor_and_expected_path
    session = authenticate

    pages = []
    @client.each_subscription_page(session: session) { |children| pages << children }

    assert_equal 2, pages.length
    assert_equal "/subreddits/mine/subscriber?limit=100&raw_json=1", URI.parse(@http.calls[1].fetch(:url)).request_uri
    assert_equal "/subreddits/mine/subscriber?limit=100&raw_json=1&after=t5_def", URI.parse(@http.calls[2].fetch(:url)).request_uri
    assert_equal "Bearer test-access", @http.calls[1].fetch(:headers).fetch("Authorization")
    refute @http.calls.any? { |call| call.fetch(:url).include?("+") }
  end

  def test_unread_listing_uses_distinct_cursor_prefix_and_false_marking
    @http = FakeHttpClient.new(
      responses: [
        response({ access_token: "token", token_type: "bearer", expires_in: 1, scope: "*" }),
        listing(children: [], after: "t4_next"),
        listing(children: [], after: nil)
      ]
    )
    session = build_client.authenticate(
      client_id: "client-id", client_secret: "client-secret", refresh_token: "refresh-token", user_agent: valid_user_agent
    )
    pages = []
    @client.each_unread_page(session: session) { |children| pages << children }

    assert_equal 2, pages.length
    uri = URI.parse(@http.calls[1].fetch(:url))
    assert_equal "/message/unread", uri.path
    assert_equal "limit=100&mark=false&max_replies=0&raw_json=1", uri.query
  end

  def test_home_and_subreddit_hot_use_only_documented_paths
    @http = FakeHttpClient.new(
      responses: [
        response({ access_token: "token", token_type: "bearer", expires_in: 1, scope: "*" }),
        listing(children: [], after: nil),
        listing(children: [], after: nil)
      ]
    )
    client = build_client
    session = client.authenticate(client_id: "client-id", client_secret: "client-secret", refresh_token: "refresh-token", user_agent: valid_user_agent)
    assert_empty client.home_hot(session: session)
    assert_empty client.subreddit_hot(session: session, subreddit: "news", operation: :news_hot)

    assert_equal "/hot?limit=100&raw_json=1", URI.parse(@http.calls[1].fetch(:url)).request_uri
    assert_equal "/r/news/hot?limit=100&raw_json=1", URI.parse(@http.calls[2].fetch(:url)).request_uri
    refute @http.calls.any? { |call| call.fetch(:url).include?("+") }
  end

  def test_maps_non_success_response_objects_without_requiring_http_client_to_raise
    @http = FakeHttpClient.new(
      responses: [
        response({ access_token: "token", token_type: "bearer", expires_in: 1, scope: "*" }),
        Response.new(status: 401, headers: {}, body: '{"secret":"body"}')
      ]
    )
    client = build_client
    session = client.authenticate(client_id: "client-id", client_secret: "client-secret", refresh_token: "refresh-token", user_agent: valid_user_agent)

    error = assert_raises(Cybort::RedditApiError) { client.home_hot(session: session) }
    assert_equal :authentication, error.safe_metadata.fetch(:category)
    assert_equal 401, error.safe_metadata.fetch(:status)
    refute_includes error.message, "secret"
    refute_includes error.message, "body"
  end

  def test_session_does_not_expose_access_token_or_client_digest
    session = authenticate

    refute_respond_to session, :access_token
    refute_respond_to session, :client_key
    refute_includes session.instance_variables, :@access_token
    refute_includes session.instance_variables, :@client_key
  end

  def test_maps_http_statuses_to_operation_aware_safe_errors
    [
      [401, :authentication],
      [403, :authorization],
      [429, :rate_limited],
      [500, :http]
    ].each do |status, category|
      http_error = Cybort::HttpError.new(status: status, headers: { "retry-after" => "7" })
      @http = FakeHttpClient.new(responses: [response({ access_token: "token", token_type: "bearer", expires_in: 1, scope: "*" }), http_error])
      # The fake raises values only when configured as an exception.
      @http = FakeHttpClient.new(responses: [response({ access_token: "token", token_type: "bearer", expires_in: 1, scope: "*" })], error: http_error)
      client = build_client
      session = client.authenticate(client_id: "client-id", client_secret: "client-secret", refresh_token: "refresh-token", user_agent: valid_user_agent)
      error = assert_raises(Cybort::RedditApiError) { client.home_hot(session: session) }
      assert_equal :home_hot, error.safe_metadata.fetch(:operation)
      assert_equal category, error.safe_metadata.fetch(:category)
      assert_equal status, error.safe_metadata.fetch(:status)
      refute_includes error.message, "retry-after"
    end
  end

  def test_request_budget_rejects_request_ninety_one
    @http = FakeHttpClient.new(
      responses: [response({ access_token: "token", token_type: "bearer", expires_in: 1, scope: "*" })] +
        Array.new(90) { listing(children: [], after: nil) }
    )
    client = Cybort::RedditClient.new(
      http_client: @http,
      coordinator: Cybort::RedditRateLimitCoordinator.new(clock: @clock.method(:call), sleeper: ->(seconds) { @clock.advance(seconds) }),
      clock: @clock.method(:call),
      deadline_seconds: 120,
      request_limit: 1
    )
    session = client.authenticate(client_id: "client-id", client_secret: "client-secret", refresh_token: "refresh-token", user_agent: valid_user_agent)
    error = assert_raises(Cybort::RedditApiError) { client.home_hot(session: session) }
    assert_equal :request_budget, error.safe_metadata.fetch(:category)
    assert_equal 1, @http.calls.length
  end

  def test_deadline_is_passed_to_http_and_prevents_partial_page_return
    responses = [
      response({ access_token: "token", token_type: "bearer", expires_in: 1, scope: "*" }),
      listing(children: [{ "kind" => "t5", "data" => { "id" => "abc", "name" => "t5_abc" } }], after: "t5_def")
    ]
    @http = FakeHttpClient.new(responses: responses) { |_call| response_for_deadline(@http.calls.length) }
    client = build_client(deadline_seconds: 120)
    session = client.authenticate(client_id: "client-id", client_secret: "client-secret", refresh_token: "refresh-token", user_agent: valid_user_agent)
    @clock.advance(120)

    error = assert_raises(Cybort::RedditApiError) { client.each_subscription_page(session: session) { flunk "must not yield partial data" } }
    assert_equal :deadline, error.safe_metadata.fetch(:category)
    assert_equal 1, @http.calls.length
  end

  def test_old_session_is_rejected_after_sequential_authentication
    @http = FakeHttpClient.new(
      responses: [
        response({ access_token: "one", token_type: "bearer", expires_in: 1, scope: "*" }),
        response({ access_token: "two", token_type: "bearer", expires_in: 1, scope: "*" })
      ]
    )
    client = build_client
    first = client.authenticate(client_id: "client-id", client_secret: "client-secret", refresh_token: "refresh-token", user_agent: valid_user_agent)
    second = client.authenticate(client_id: "client-id", client_secret: "client-secret", refresh_token: "refresh-token", user_agent: valid_user_agent)

    refute_equal first, second
    error = assert_raises(Cybort::ValidationError) { client.home_hot(session: first) }
    refute_includes error.message, "token"
  end

  def test_malformed_listing_and_repeated_cursor_are_safe_shape_errors
    @http = FakeHttpClient.new(
      responses: [
        response({ access_token: "token", token_type: "bearer", expires_in: 1, scope: "*" }),
        response({ kind: "Listing", data: { children: [], after: "t5_abc" } }),
        response({ kind: "Listing", data: { children: [], after: "t5_abc" } })
      ]
    )
    client = build_client
    session = client.authenticate(client_id: "client-id", client_secret: "client-secret", refresh_token: "refresh-token", user_agent: valid_user_agent)
    error = assert_raises(Cybort::RedditApiError) { client.each_subscription_page(session: session) { |_children| } }
    assert_equal :invalid_shape, error.safe_metadata.fetch(:category)
  end

  private

  def authenticate
    @client.authenticate(
      client_id: "client-id",
      client_secret: "client-secret",
      refresh_token: "refresh-token",
      user_agent: valid_user_agent
    )
  end

  def build_client(deadline_seconds: 120)
    @client = Cybort::RedditClient.new(
      http_client: @http,
      coordinator: Cybort::RedditRateLimitCoordinator.new(clock: @clock.method(:call), sleeper: ->(seconds) { @clock.advance(seconds) }),
      clock: @clock.method(:call),
      deadline_seconds: deadline_seconds,
      request_limit: 90
    )
  end

  def valid_user_agent
    "macos:com.example.cybort:v0.1.0 (by /u/test_user)"
  end

  def response(payload)
    Response.new(status: 200, headers: {}, body: JSON.generate(payload))
  end

  def listing(children:, after:)
    response({ "kind" => "Listing", "data" => { "children" => children, "after" => after } })
  end

  def response_for_deadline(call_count)
    if call_count == 1
      response({ access_token: "token", token_type: "bearer", expires_in: 1, scope: "*" })
    else
      @clock.advance(120)
      listing(children: [], after: "t5_abc")
    end
  end
end
