require "json"
require "uri"

module Cybort
  class GmailClient
    TOKEN_URL = "https://oauth2.googleapis.com/token".freeze
    DATA_URL = "https://gmail.googleapis.com/gmail/v1".freeze
    READONLY_SCOPE = "https://www.googleapis.com/auth/gmail.readonly".freeze
    REQUEST_TIMEOUT_SECONDS = 30

    def initialize(http_client:, monotonic_clock:, deadline_monotonic:)
      @http_client = http_client
      @monotonic_clock = monotonic_clock
      @deadline_monotonic = deadline_monotonic
      @access_token = nil
      @expires_at_monotonic = nil
    end

    def authenticate(credentials:)
      @access_token = nil
      @expires_at_monotonic = nil
      started_at = @monotonic_clock.call
      payload = request_json(
        operation: :token,
        url: TOKEN_URL,
        form: {
          grant_type: "refresh_token",
          client_id: credentials.client_id,
          client_secret: credentials.client_secret,
          refresh_token: credentials.refresh_token
        }
      )

      unless GmailCredentials.printable?(payload["access_token"], 8_192) &&
             payload["token_type"].is_a?(String) && payload["token_type"].casecmp?("Bearer") &&
             payload["expires_in"].is_a?(Integer) && payload["expires_in"].positive?
        fail_api(:token, :invalid_shape)
      end

      if payload.key?("scope") &&
         (!payload["scope"].is_a?(String) || !payload["scope"].valid_encoding? ||
          !payload["scope"].split.include?(READONLY_SCOPE))
        fail_api(:token, :scope)
      end

      @access_token = payload.fetch("access_token").dup.freeze
      @expires_at_monotonic = started_at + payload.fetch("expires_in")
      nil
    end

    def list_message_ids(user_id:, query:, limit:, include_spam_trash:)
      params = {
        "maxResults" => limit,
        "includeSpamTrash" => include_spam_trash
      }
      params["q"] = query unless query.strip.empty?

      payload = get_json(
        operation: :list,
        path: "/users/#{segment(user_id)}/messages",
        params: params
      )
      messages = payload.fetch("messages", [])
      fail_api(:list, :invalid_shape) unless messages.is_a?(Array)

      messages.first(limit).map do |message|
        fail_api(:list, :invalid_identity) unless message.is_a?(Hash) && valid_id?(message["id"])

        message.fetch("id")
      end.uniq
    end

    def get_message(user_id:, message_id:)
      fail_api(:get, :invalid_identity) unless valid_id?(message_id)

      params = [
        ["format", "metadata"],
        ["fields", "id,threadId,labelIds,snippet,internalDate,payload/headers"]
      ]
      %w[Subject From Date Message-ID].each do |name|
        params << ["metadataHeaders", name]
      end

      payload = get_json(
        operation: :get,
        path: "/users/#{segment(user_id)}/messages/#{segment(message_id)}",
        params: params
      )
      fail_api(:get, :invalid_identity) unless payload["id"] == message_id
      validate_optional_fields!(payload)
      payload
    end

    def inspect
      "#<Cybort::GmailClient [REDACTED]>"
    end

    alias to_s inspect

    private

    def get_json(operation:, path:, params:)
      now = ensure_deadline!(operation)
      fail_api(operation, :authentication) unless @access_token
      fail_api(operation, :token_expired) if now >= @expires_at_monotonic

      request_json(
        operation: operation,
        url: "#{DATA_URL}#{path}?#{URI.encode_www_form(params)}",
        headers: { "Authorization" => "Bearer #{@access_token}" }
      )
    end

    def segment(value)
      URI.encode_www_form_component(value).gsub("+", "%20")
    end

    def valid_id?(value)
      GmailCredentials.printable?(value, 256) && !%w[. ..].include?(value)
    end

    def validate_optional_fields!(payload)
      %w[snippet threadId].each do |key|
        fail_api(:get, :invalid_shape) unless payload[key].nil? || payload[key].is_a?(String)
      end

      labels = payload["labelIds"]
      unless labels.nil? || (labels.is_a?(Array) && labels.all? { |label| label.is_a?(String) })
        fail_api(:get, :invalid_shape)
      end

      part = payload["payload"]
      fail_api(:get, :invalid_shape) unless part.nil? || part.is_a?(Hash)

      headers = part && part["headers"]
      unless headers.nil? || (headers.is_a?(Array) && headers.all? { |header|
        header.is_a?(Hash) && header["name"].is_a?(String) && header["value"].is_a?(String)
      })
        fail_api(:get, :invalid_shape)
      end
    end

    def request_json(operation:, url:, form: nil, headers: {})
      now = ensure_deadline!(operation)
      request_deadline = [@deadline_monotonic, now + REQUEST_TIMEOUT_SECONDS].min
      options = {
        headers: headers,
        timeout_seconds: request_deadline - now,
        deadline_monotonic: request_deadline
      }
      response = if form
        @http_client.post_form(url, form: form, **options)
      else
        @http_client.get(url, **options)
      end
      now = ensure_deadline!(operation)
      fail_api(operation, :timeout) if now >= request_deadline
      payload = JSON.parse(response.body)
      fail_api(operation, :invalid_shape) unless payload.is_a?(Hash)
      payload
    rescue HttpError => error
      status = error.safe_metadata.fetch(:status)
      category = if status == 401 || (operation == :token && status == 400)
        :authentication
      elsif status == 403
        :authorization
      elsif status == 429
        :rate_limited
      else
        :http
      end
      fail_api(operation, category, status: status)
    rescue HttpTransportError => error
      fail_api(operation, error.safe_metadata.fetch(:category))
    rescue JSON::ParserError, EncodingError
      fail_api(operation, :invalid_json)
    end

    def fail_api(operation, category, status: nil)
      raise GmailApiError.new(operation: operation, category: category, status: status), cause: nil
    end

    def ensure_deadline!(operation)
      now = @monotonic_clock.call
      fail_api(operation, :deadline) if now >= @deadline_monotonic

      now
    end
  end
end
