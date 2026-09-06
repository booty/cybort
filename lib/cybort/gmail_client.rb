require "json"

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

    def inspect
      "#<Cybort::GmailClient [REDACTED]>"
    end

    alias to_s inspect

    private

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
