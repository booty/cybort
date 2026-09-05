module Cybort
  module Adapters
    class Reddit < Base
      MAX_ITEMS_TO_FETCH = 100
      MAX_SUBREDDITS = 50
      CREDENTIAL_LIMITS = {
        client_id: 256,
        client_secret: 1_024,
        refresh_token: 4_096,
        user_agent: 256
      }.freeze

      attr_reader :reddit_client, :coordinator, :include_subreddits, :exclude_subreddits

      def self.executable_dependencies
        [].freeze
      end

      def self.validate_configuration!(instance)
        options = configuration_options(instance)
        CREDENTIAL_LIMITS.each do |key, maximum_bytes|
          value = option(options, key)
          validate_credential!(value, key, maximum_bytes)
        end
        validate_user_agent!(option(options, :user_agent))
        validate_subreddits!(option(options, :include_subreddits, []), :include_subreddits)
        validate_subreddits!(option(options, :exclude_subreddits, []), :exclude_subreddits)

        limit = instance.num_items_to_fetch
        unless limit.is_a?(Integer) && limit.between?(1, MAX_ITEMS_TO_FETCH)
          raise ConfigurationError,
                "reddit num_items_to_fetch must be an integer from 1 through #{MAX_ITEMS_TO_FETCH}"
        end

        true
      end

      def initialize(reddit_client: nil, coordinator: RedditRateLimitCoordinator.default, **kwargs)
        super(**kwargs)
        self.class.validate_configuration!(instance)

        options = instance.options
        @include_subreddits = normalized_subreddits(option(options, :include_subreddits, []))
        @exclude_subreddits = normalized_subreddits(option(options, :exclude_subreddits, []))
        @include_subreddits = (@include_subreddits - @exclude_subreddits).freeze
        @exclude_subreddits.freeze
        @coordinator = coordinator
        @reddit_client = reddit_client || RedditClient.new(
          http_client: http_client,
          coordinator: coordinator,
          clock: monotonic_clock
        )
      end

      def executable_dependencies
        self.class.executable_dependencies
      end

      private

      def fetch_from_source
        raise SourceError, "Reddit adapter fetch pipeline is not implemented"
      end

      class << self
        private

        def configuration_options(instance)
          options = instance.options if instance.respond_to?(:options)
          return options if options.is_a?(Hash)

          raise ConfigurationError, "reddit options must be a table"
        end

        def option(options, key, default = nil)
          return options.fetch(key) if options.key?(key)
          return options.fetch(key.to_s) if options.key?(key.to_s)

          default
        end

        def validate_credential!(value, key, maximum_bytes)
          unless value.is_a?(String) && value.valid_encoding? && !value.strip.empty? &&
                 value.bytesize <= maximum_bytes && !value.match?(RedditClient::CONTROL_PATTERN)
            raise ConfigurationError, "reddit #{key} must be a nonblank printable string of at most #{maximum_bytes} bytes"
          end
        end

        def validate_user_agent!(value)
          validate_credential!(value, :user_agent, CREDENTIAL_LIMITS.fetch(:user_agent))
          return if value.match?(RedditClient::USER_AGENT_PATTERN)

          raise ConfigurationError, "reddit user_agent has an invalid format"
        end

        def validate_subreddits!(value, key)
          unless value.is_a?(Array)
            raise ConfigurationError, "reddit #{key} must be an array"
          end
          if value.length > MAX_SUBREDDITS
            raise ConfigurationError, "reddit #{key} must contain at most #{MAX_SUBREDDITS} names"
          end

          value.each do |name|
            unless name.is_a?(String) && name.match?(RedditClient::SUBREDDIT_PATTERN)
              raise ConfigurationError, "reddit #{key} contains an invalid subreddit"
            end
          end
        end

      end

      def option(options, key, default = nil)
        return options.fetch(key) if options.key?(key)
        return options.fetch(key.to_s) if options.key?(key.to_s)

        default
      end

      def normalized_subreddits(value)
        value.map(&:downcase).uniq
      end
    end
  end
end
