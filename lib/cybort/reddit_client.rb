require "json"
require "uri"

module Cybort
  class RedditClient
    TOKEN_URL = "https://www.reddit.com/api/v1/access_token"
    DATA_URL = "https://oauth.reddit.com"
    DEFAULT_DEADLINE_SECONDS = 120
    DEFAULT_REQUEST_LIMIT = 90
    REQUIRED_SCOPES = %w[read mysubreddits privatemessages].freeze
    SUBREDDIT_PATTERN = /\A[A-Za-z0-9_]{2,21}\z/.freeze
    USER_AGENT_PATTERN = /\A[^:\s]+:[^:\s]+:[^\s()]+ \(by \/u\/[A-Za-z0-9_-]+\)\z/.freeze
    CONTROL_PATTERN = /[\x00-\x1F\x7F]/.freeze
    CURSOR_PATTERN = /\At[1-6]_[0-9a-z]+\z/.freeze
    SUBSCRIPTION_CURSOR_PATTERN = /\At5_[0-9a-z]+\z/.freeze
    UNREAD_CURSOR_PATTERN = /\At(?:1|4)_[0-9a-z]+\z/.freeze

    class Session
      attr_reader :generation, :deadline_monotonic

      def initialize(generation:, deadline_monotonic:)
        @generation = generation
        @deadline_monotonic = deadline_monotonic
        freeze
      end
    end

    def initialize(http_client:, coordinator: RedditRateLimitCoordinator.default,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                   deadline_seconds: DEFAULT_DEADLINE_SECONDS,
                   request_limit: DEFAULT_REQUEST_LIMIT)
      @http_client = http_client
      @coordinator = coordinator
      @clock = callable(clock, :clock)
      @deadline_seconds = positive_number(deadline_seconds, :deadline_seconds)
      @request_limit = positive_integer(request_limit, :request_limit)
      @state_mutex = Mutex.new
      @generation = 0
      @session = nil
      @authenticating = false
      @request_count = 0
      @safe_metadata = {}.freeze
    end

    def authenticate(client_id:, client_secret:, refresh_token:, user_agent:)
      client_id = validate_credential(client_id, :client_id, 256)
      client_secret = validate_credential(client_secret, :client_secret, 1_024)
      refresh_token = validate_credential(refresh_token, :refresh_token, 4_096)
      user_agent = validate_user_agent(user_agent)

      state = nil
      started_authentication = false
      state = begin_authentication(client_id: client_id, user_agent: user_agent)
      started_authentication = true
      response = request_json(
        operation: :token,
        session: state,
        method: :post_form,
        url: TOKEN_URL,
        form: { grant_type: "refresh_token", refresh_token: refresh_token },
        headers: {
          "Authorization" => "Basic #{basic_auth(client_id, client_secret)}",
          "User-Agent" => user_agent
        }
      )
      access_token = validate_token_response(response)

      @state_mutex.synchronize do
        @access_token = access_token
        @session = state
      end
      state
    rescue RedditApiError
      @state_mutex.synchronize do
        if @session&.generation == state&.generation
          @session = nil
          @access_token = nil
        end
      end
      raise
    ensure
      @state_mutex.synchronize { @authenticating = false } if started_authentication
    end

    def each_subscription_page(session:)
      return enum_for(__method__, session: session) unless block_given?

      each_listing_page(
        session: session,
        operation: :subscriptions,
        path: "/subreddits/mine/subscriber",
        query: { "limit" => 100, "raw_json" => 1 },
        cursor_pattern: SUBSCRIPTION_CURSOR_PATTERN
      ) { |children| yield children }
    end

    def each_unread_page(session:)
      return enum_for(__method__, session: session) unless block_given?

      each_listing_page(
        session: session,
        operation: :unread_messages,
        path: "/message/unread",
        query: { "limit" => 100, "mark" => "false", "max_replies" => 0, "raw_json" => 1 },
        cursor_pattern: UNREAD_CURSOR_PATTERN
      ) { |children| yield children }
    end

    def home_hot(session:)
      listing_page(
        session: session,
        operation: :home_hot,
        path: "/hot",
        query: { "limit" => 100, "raw_json" => 1 }
      ).fetch(:children)
    end

    def subreddit_hot(session:, subreddit:, operation: :subreddit_hot)
      operation = normalize_listing_operation(operation)
      subreddit = validate_subreddit(subreddit)
      if operation == :news_hot && subreddit != "news"
        raise ValidationError, "news_hot requires the news subreddit"
      end

      listing_page(
        session: session,
        operation: operation,
        path: "/r/#{subreddit}/hot",
        query: { "limit" => 100, "raw_json" => 1 }
      ).fetch(:children)
    end

    def safe_metadata
      @state_mutex.synchronize { @safe_metadata.dup.freeze }
    end

    private

    def begin_authentication(client_id:, user_agent:)
      @state_mutex.synchronize do
        raise ValidationError, "Reddit authentication is already in progress" if @authenticating

        @authenticating = true
        @generation += 1
        @request_count = 0
        @safe_metadata = {}.freeze
        deadline = monotonic_now + @deadline_seconds
        session = Session.new(
          generation: @generation,
          deadline_monotonic: deadline
        )
        @client_key = @coordinator.key_for(client_id)
        @user_agent = user_agent
        @access_token = nil
        @session = session
        session
      end
    end

    def each_listing_page(session:, operation:, path:, query:, cursor_pattern: nil)
      ensure_session!(session)
      cursor = nil
      seen_cursors = {}

      loop do
        page_query = cursor ? query.merge("after" => cursor) : query
        payload = listing_page(
          session: session,
          operation: operation,
          path: path,
          query: page_query
        )
        after = payload.fetch(:after)
        validate_cursor!(after, cursor_pattern, operation) unless after.nil?
        if after && seen_cursors.key?(after)
          raise_api(operation, :invalid_shape)
        end

        yield payload.fetch(:children)
        break if after.nil?

        seen_cursors[after] = true
        cursor = after
      end
      nil
    end

    def listing_page(session:, operation:, path:, query:)
      payload = request_json(
        operation: operation,
        session: session,
        method: :get,
        url: data_url(path, query),
        headers: data_headers(session)
      )
      validate_listing(payload, operation)
    end

    def validate_listing(payload, operation)
      unless payload.is_a?(Hash) && payload["kind"] == "Listing" && payload["data"].is_a?(Hash)
        raise_api(operation, :invalid_shape)
      end

      children = payload["data"]["children"]
      after = payload["data"]["after"]
      unless children.is_a?(Array) && (after.nil? || after.is_a?(String))
        raise_api(operation, :invalid_shape)
      end
      validate_cursor!(after, nil, operation) unless after.nil?

      { children: children, after: after }.freeze
    end

    def request_json(operation:, session:, method:, url:, headers:, form: nil)
      ensure_session!(session, allow_unauthed: operation == :token)
      count_request!(operation, session)
      lease = nil
      begin
        remaining = remaining_deadline!(operation, session)
        lease = @coordinator.acquire(
          key: current_client_key,
          deadline_monotonic: session.deadline_monotonic,
          operation: operation
        )
        remaining = remaining_deadline!(operation, session)
        response = request_http(
          method: method,
          url: url,
          headers: headers,
          form: form,
          timeout_seconds: remaining,
          deadline_monotonic: session.deadline_monotonic
        )
        rate_metadata = RateLimitHeaders.parse(response.respond_to?(:headers) ? response.headers : {})
        status = response.respond_to?(:status) ? response.status.to_i : 0
        observe_rate(lease, rate_metadata, status)
        unless status.between?(200, 299)
          raise_api(operation, http_category(status), status: status, rate_metadata: rate_metadata)
        end
        remaining_deadline!(operation, session)
        parse_json(response.respond_to?(:body) ? response.body : nil, operation)
      rescue HttpError => error
        metadata = error.safe_metadata
        observe_rate(lease, metadata, metadata[:status])
        raise_api(operation, http_category(metadata[:status]), status: metadata[:status], rate_metadata: metadata)
      rescue HttpTransportError => error
        raise_api(operation, transport_category(error.safe_metadata[:category]))
      ensure
        lease&.release
      end
    rescue RedditApiError
      raise
    rescue JSON::ParserError
      raise_api(operation, :invalid_json)
    end

    def observe_rate(lease, metadata, status)
      rate_metadata = RateLimitHeaders.parse(metadata)
      update_safe_metadata(rate_metadata)
      lease&.observe(metadata: rate_metadata, status: status)
    end

    def request_http(method:, url:, headers:, form:, timeout_seconds:, deadline_monotonic:)
      arguments = { headers: headers, timeout_seconds: timeout_seconds }
      arguments[:form] = form if method == :post_form
      if http_method_accepts_keyword?(method, :deadline_monotonic)
        arguments[:deadline_monotonic] = deadline_monotonic
      end
      @http_client.public_send(method, url, **arguments)
    end

    def http_method_accepts_keyword?(method, keyword)
      parameters = @http_client.method(method).parameters
      parameters.any? { |kind, name| kind == :keyrest || name == keyword }
    rescue NameError
      false
    end

    def parse_json(body, operation)
      JSON.parse(body.to_s)
    rescue JSON::ParserError
      raise_api(operation, :invalid_json)
    end

    def validate_token_response(payload)
      unless payload.is_a?(Hash)
        raise_api(:token, :invalid_shape)
      end

      access_token = payload["access_token"]
      token_type = payload["token_type"]
      expires_in = payload["expires_in"]
      scope = payload["scope"]
      unless valid_nonblank_string?(access_token) && token_type.is_a?(String) && token_type.casecmp?("bearer")
        raise_api(:token, :invalid_shape)
      end
      expires = Float(expires_in)
      unless expires.finite? && expires.positive?
        raise_api(:token, :invalid_shape)
      end
      unless scope.is_a?(String)
        raise_api(:token, :invalid_shape)
      end

      scopes = scope.split
      unless scopes.include?("*") || REQUIRED_SCOPES.all? { |required| scopes.include?(required) }
        raise_api(:token, :authorization)
      end

      access_token
    rescue ArgumentError, TypeError
      raise_api(:token, :invalid_shape)
    end

    def validate_cursor!(cursor, pattern, operation)
      unless cursor.is_a?(String) && cursor.match?(CURSOR_PATTERN) && base36_fullname?(cursor)
        raise_api(operation, :invalid_shape)
      end
      if pattern && !cursor.match?(pattern)
        raise_api(operation, :invalid_shape)
      end
    end

    def base36_fullname?(fullname)
      id = fullname.split("_", 2).last
      Integer(id, 36).to_s(36) == id
    rescue ArgumentError
      false
    end

    def ensure_session!(session, allow_unauthed: false)
      valid = @state_mutex.synchronize { @session.equal?(session) }
      unless valid && session.is_a?(Session) && (allow_unauthed || valid_nonblank_string?(current_access_token))
        raise ValidationError, "Reddit session is not current"
      end
    end

    def count_request!(operation, session)
      @state_mutex.synchronize do
        unless @request_count < @request_limit
          raise_api(operation, :request_budget)
        end

        @request_count += 1
      end
    end

    def remaining_deadline!(operation, session)
      remaining = session.deadline_monotonic - monotonic_now
      raise_api(operation, :deadline) unless remaining.positive?

      remaining
    end

    def data_headers(session)
      {
        "Authorization" => "Bearer #{current_access_token}",
        "User-Agent" => current_user_agent
      }
    end

    def current_access_token
      @state_mutex.synchronize { @access_token }
    end

    def current_client_key
      @state_mutex.synchronize { @client_key }
    end

    def current_user_agent
      @state_mutex.synchronize { @user_agent }
    end

    def data_url(path, query)
      "#{DATA_URL}#{path}?#{URI.encode_www_form(query)}"
    end

    def http_category(status)
      case status.to_i
      when 401 then :authentication
      when 403 then :authorization
      when 429 then :rate_limited
      else :http
      end
    end

    def transport_category(category)
      %i[timeout response_too_large].include?(category.to_sym) ? category.to_sym : :http
    end

    def raise_api(operation, category, status: nil, rate_metadata: {})
      raise RedditApiError.new(operation: operation, category: category, status: status, rate_metadata: rate_metadata)
    end

    def update_safe_metadata(metadata)
      metadata = RateLimitHeaders.parse(metadata)
      return if metadata.empty?

      @state_mutex.synchronize { @safe_metadata = @safe_metadata.merge(metadata).freeze }
    end

    def normalize_listing_operation(operation)
      operation = operation.to_sym
      return operation if %i[subreddit_hot news_hot].include?(operation)

      raise ValidationError, "unsupported Reddit listing operation"
    rescue NoMethodError
      raise ValidationError, "unsupported Reddit listing operation"
    end

    def validate_subreddit(value)
      unless value.is_a?(String) && value.match?(SUBREDDIT_PATTERN)
        raise ValidationError, "invalid Reddit subreddit"
      end

      value.downcase
    end

    def validate_user_agent(value)
      value = validate_credential(value, :user_agent, 256)
      unless value.match?(USER_AGENT_PATTERN)
        raise ValidationError, "invalid Reddit user_agent"
      end

      value
    end

    def validate_credential(value, name, maximum_bytes)
      unless value.is_a?(String) && value.valid_encoding? && !value.strip.empty? &&
             value.bytesize <= maximum_bytes && !value.match?(CONTROL_PATTERN)
        raise ValidationError, "invalid Reddit #{name}"
      end

      value
    end

    def valid_nonblank_string?(value)
      value.is_a?(String) && value.valid_encoding? && !value.strip.empty? && !value.match?(CONTROL_PATTERN)
    end

    def basic_auth(client_id, client_secret)
      ["#{client_id}:#{client_secret}"].pack("m0")
    end

    def positive_number(value, name)
      number = Float(value)
      raise ArgumentError, "#{name} must be positive and finite" unless number.finite? && number.positive?

      number
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{name} must be positive and finite"
    end

    def positive_integer(value, name)
      number = Integer(value)
      raise ArgumentError, "#{name} must be a positive integer" unless number.positive?

      number
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{name} must be a positive integer"
    end

    def monotonic_now
      value = Float(@clock.call)
      raise ArgumentError, "clock must return a finite number" unless value.finite?

      value
    rescue ArgumentError, TypeError
      raise ArgumentError, "clock must return a finite number"
    end

    def callable(value, name)
      raise ArgumentError, "#{name} must be callable" unless value.respond_to?(:call)

      value
    end
  end
end
