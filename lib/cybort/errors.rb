module Cybort
  class HttpError < SourceError
    attr_reader :safe_metadata

    def initialize(status:, headers: {})
      @status = normalize_status(status)
      @safe_metadata = { status: @status }.merge(RateLimitHeaders.parse(headers)).freeze
      super("HTTP request failed with status #{@status}")
    end

    private

    def normalize_status(status)
      value = Integer(status)
      raise ArgumentError, "HTTP status must be an integer" unless value.positive?

      value
    rescue ArgumentError, TypeError
      raise ArgumentError, "HTTP status must be an integer"
    end
  end

  class HttpTransportError < SourceError
    CATEGORIES = %i[network timeout response_too_large].freeze

    attr_reader :safe_metadata

    def initialize(category:)
      category = category.to_sym
      raise ArgumentError, "unsupported HTTP transport error category" unless CATEGORIES.include?(category)

      @safe_metadata = { category: category }.freeze
      super("HTTP transport failed (#{category})")
    end
  end

  class GmailApiError < SourceError
    OPERATIONS = %i[credentials token list get].freeze
    HINTS = {
      missing: "Configure credentials_file using README Gmail setup.",
      unreadable: "Check credential ownership and private file permissions.",
      invalid_credentials: "Use authorized_user JSON, not downloaded OAuth client JSON.",
      authentication: "Reauthorize Gmail credentials.",
      token_expired: "Run collection again; reauthorize if it persists.",
      scope: "Authorize gmail.readonly explicitly.",
      authorization: "Check Gmail scope, API enablement, and account/admin policy.",
      rate_limited: "Try again later.",
      http: "Gmail request failed; retry later or inspect setup.",
      network: "Gmail network request failed; retry later.",
      timeout: "Gmail request timed out; try again later.",
      response_too_large: "Gmail response was too large; try again later.",
      invalid_json: "Unexpected Gmail response.",
      invalid_shape: "Unexpected Gmail response.",
      invalid_identity: "Unexpected Gmail response.",
      deadline: "Fetch budget exhausted; try a smaller item limit."
    }.freeze
    CATEGORIES = HINTS.keys.freeze

    attr_reader :safe_metadata

    def initialize(operation:, category:, status: nil)
      operation = operation.to_sym if operation.respond_to?(:to_sym)
      category = category.to_sym if category.respond_to?(:to_sym)

      unless OPERATIONS.include?(operation)
        raise ArgumentError, "unsupported Gmail API operation"
      end
      unless CATEGORIES.include?(category)
        raise ArgumentError, "unsupported Gmail API error category"
      end
      unless status.nil? || (status.is_a?(Integer) && (100..599).cover?(status))
        raise ArgumentError, "Gmail API error status must be an integer between 100 and 599"
      end

      @safe_metadata = {
        source: "gmail_api", operation: operation, category: category
      }
      @safe_metadata[:status] = status unless status.nil?
      @safe_metadata.freeze

      suffix = status ? ", HTTP #{status}" : ""
      super("Gmail #{operation} failed (#{category}#{suffix}). #{HINTS.fetch(category)}")
    end
  end

  class RedditApiError < SourceError
    OPERATIONS = %i[token subscriptions unread_messages home_hot subreddit_hot news_hot].freeze
    CATEGORIES = %i[
      authentication authorization rate_limited http invalid_json invalid_shape
      invalid_identity request_budget deadline timeout response_too_large
    ].freeze

    attr_reader :safe_metadata

    def initialize(operation:, category:, status: nil, rate_metadata: {}, **_ignored)
      operation = operation.to_sym
      category = category.to_sym
      unless OPERATIONS.include?(operation)
        raise ArgumentError, "unsupported Reddit API operation"
      end
      unless CATEGORIES.include?(category)
        raise ArgumentError, "unsupported Reddit API error category"
      end

      @safe_metadata = { operation: operation, category: category }
      @safe_metadata[:status] = Integer(status) unless status.nil?
      @safe_metadata.merge!(RateLimitHeaders.parse(rate_metadata))
      @safe_metadata = @safe_metadata.freeze

      message = "Reddit #{operation} request failed (#{category}"
      message += ", status #{@safe_metadata[:status]}" if @safe_metadata.key?(:status)
      super("#{message})")
    rescue ArgumentError, TypeError => error
      raise error if error.message.start_with?("unsupported Reddit API")

      raise ArgumentError, "Reddit API error status must be an integer"
    end
  end

  class CommandError < SourceError
    ALLOWED_METADATA = %i[
      tool operation command_index exit_category exit_code tool_version category auth_hint
    ].freeze
    MAX_STRING_BYTES = 256

    attr_reader :safe_metadata

    def initialize(message, metadata: {})
      message = message.to_s
      unless message.bytesize <= MAX_STRING_BYTES && message.each_codepoint.none?(&:zero?) && message !~ /[\x00-\x1F\x7F]/
        raise ArgumentError, "command error message must be short and printable"
      end

      @safe_metadata = normalize_metadata(metadata).freeze
      super(message)
    end

    private

    def normalize_metadata(metadata)
      raise ArgumentError, "command error metadata must be a hash" unless metadata.is_a?(Hash)

      metadata.each_with_object({}) do |(key, value), result|
        key = key.to_sym
        raise ArgumentError, "unsupported command error metadata: #{key}" unless ALLOWED_METADATA.include?(key)
        unless value.nil? || value.is_a?(String) || value.is_a?(Integer) || value == true || value == false
          raise ArgumentError, "command error metadata must contain scalar values"
        end
        if value.is_a?(String) && value.bytesize > MAX_STRING_BYTES
          raise ArgumentError, "command error metadata value is too long"
        end

        result[key] = value
      end
    end
  end
end
