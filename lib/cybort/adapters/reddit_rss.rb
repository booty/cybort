module Cybort
  module Adapters
    class RedditRSS < Base
      MAX_SUBREDDITS = 10
      MAX_ITEMS_TO_FETCH = 100
      MAX_USER_AGENT_BYTES = 256
      SOURCE_OPTION_NAMES = %w[subreddits user_agent activity_weights].freeze
      WEIGHT_NAMES = %w[top rising momentum persistence].freeze
      DEFAULT_WEIGHTS = RedditRssActivity::DEFAULT_WEIGHTS.freeze
      ATTEMPT_DEADLINE_SECONDS = 180
      CONTROL_PATTERN = /[\x00-\x1F\x7F]/.freeze

      attr_reader :subreddits, :user_agent, :weights, :coordinator

      def self.executable_dependencies
        [].freeze
      end

      def self.validate_configuration!(instance)
        options = source_options(instance)
        normalized = normalize_source_options(options)
        validate_limit!(instance.num_items_to_fetch)
        validate_subreddits!(normalized.fetch("subreddits"))
        validate_user_agent!(normalized.fetch("user_agent"))
        validate_weights!(normalized.fetch("activity_weights"))
        true
      end

      def initialize(coordinator: RedditRssCoordinator.default, **kwargs)
        super(**kwargs)
        self.class.validate_configuration!(instance)
        normalized = self.class.send(:normalize_source_options, instance.options)
        @subreddits = normalized.fetch("subreddits").map(&:downcase).uniq.sort.freeze
        @user_agent = normalized.fetch("user_agent").dup.freeze
        @weights = normalized.fetch("activity_weights").dup.freeze
        @coordinator = coordinator
      end

      def executable_dependencies
        self.class.executable_dependencies
      end

      private

      def fetch_from_source
        deadline = monotonic_now + ATTEMPT_DEADLINE_SECONDS
        state = RedditRssState.new(
          raw: context[:sync_state], subreddits: @subreddits, weights: @weights
        )
        ensure_attempt!(deadline, :state)

        client = RedditRssClient.new(
          http_client: http_client,
          monotonic_clock: monotonic_clock,
          coordinator: @coordinator
        )
        pages = {}
        %w[new rising top].each do |sort|
          pages[sort] = client.fetch(
            sort: sort,
            subreddits: @subreddits,
            user_agent: @user_agent,
            deadline_monotonic: deadline
          )
        end

        fetched_at = clock.call
        transition = state.advance(pages: pages, now: fetched_at)
        ensure_attempt!(deadline, :state)
        selection = RedditRssActivity.select(
          transition: transition,
          pages: pages,
          weights: @weights,
          now: fetched_at,
          limit: instance.num_items_to_fetch
        )
        items = selection.fetch(:selected).map { |row| item_from(row, fetched_at) }
        ensure_attempt!(deadline, :selection)

        {
          items: items,
          sync_state: transition.state,
          metadata: selection.fetch(:metadata),
          replace_existing_items: true
        }
      end

      def item_from(row, fetched_at)
        id = row.fetch(:id)
        subreddit = row.fetch(:subreddit)
        short_id = id.delete_prefix("t3_")
        Item.new(
          instance_id: instance.id,
          canonical_id: id,
          urls: ["https://www.reddit.com/r/#{subreddit}/comments/#{short_id}/"],
          fetched_at: fetched_at,
          remote_created_at: row.fetch(:published_at),
          title: row.fetch(:title),
          body: nil,
          action_item: false,
          priority: row.fetch(:priority),
          info: row.fetch(:info)
        )
      end

      def ensure_attempt!(deadline, operation)
        raise RedditRssError.new(operation: operation, category: :deadline), cause: nil unless monotonic_now < deadline
      end

      def monotonic_now
        value = Float(monotonic_clock.call)
        raise ArgumentError, "monotonic clock must return a finite number" unless value.finite?

        value
      rescue ArgumentError, TypeError
        raise ArgumentError, "monotonic clock must return a finite number"
      end

      class << self
        private

        def source_options(instance)
          options = instance.options if instance.respond_to?(:options)
          raise ConfigurationError, "reddit_rss options must be a table" unless options.is_a?(Hash)

          options
        end

        def normalize_source_options(options)
          logical = {}
          options.each_pair do |key, value|
            unless key.is_a?(String) || key.is_a?(Symbol)
              raise ConfigurationError, "reddit_rss options contain unsupported keys"
            end

            name = key.to_s
            raise ConfigurationError, "reddit_rss options contain duplicate keys" if logical.key?(name)
            unless SOURCE_OPTION_NAMES.include?(name)
              raise ConfigurationError, "reddit_rss options contain unsupported keys"
            end

            logical[name] = value
          end

          unless logical.key?("subreddits") && logical.key?("user_agent")
            raise ConfigurationError, "reddit_rss requires subreddits and user_agent"
          end

          {
            "subreddits" => normalized_subreddits(logical.fetch("subreddits")),
            "user_agent" => normalized_user_agent(logical.fetch("user_agent")),
            "activity_weights" => normalized_weights(logical.fetch("activity_weights", DEFAULT_WEIGHTS))
          }
        end

        def normalized_subreddits(value)
          validate_subreddits!(value)
          value.map(&:downcase).uniq.sort
        end

        def normalized_user_agent(value)
          validate_user_agent!(value)
          value.dup
        end

        def normalized_weights(value)
          validate_weights!(value)
          normalized = {}
          value.each_pair { |key, weight| normalized[key.to_s] = weight }
          WEIGHT_NAMES.to_h { |name| [name, normalized.fetch(name)] }
        end

        def validate_limit!(value)
          return if value.is_a?(Integer) && value.between?(1, MAX_ITEMS_TO_FETCH)

          raise ConfigurationError, "reddit_rss num_items_to_fetch must be an integer from 1 through #{MAX_ITEMS_TO_FETCH}"
        end

        def validate_subreddits!(value)
          unless value.is_a?(Array) && value.length.between?(1, MAX_SUBREDDITS)
            raise ConfigurationError, "reddit_rss subreddits must be an array of 1 through #{MAX_SUBREDDITS} names"
          end
          unless value.all? do |name|
            name.is_a?(String) && name.valid_encoding? && RedditRssClient::SUBREDDIT_PATTERN.match?(name)
          end
            raise ConfigurationError, "reddit_rss subreddits contain an invalid name"
          end
        end

        def validate_user_agent!(value)
          unless value.is_a?(String) && value.valid_encoding? && !value.strip.empty? &&
                 value.bytesize <= MAX_USER_AGENT_BYTES && !value.match?(CONTROL_PATTERN) &&
                 value.match?(RedditClient::USER_AGENT_PATTERN)
            raise ConfigurationError, "reddit_rss user_agent must be a printable identifying string of at most #{MAX_USER_AGENT_BYTES} bytes"
          end
        end

        def validate_weights!(value)
          unless value.is_a?(Hash)
            raise ConfigurationError, "reddit_rss activity_weights must be a table"
          end

          normalized = {}
          value.each_pair do |key, weight|
            unless key.is_a?(String) || key.is_a?(Symbol)
              raise ConfigurationError, "reddit_rss activity_weights contain unsupported keys"
            end

            name = key.to_s
            if normalized.key?(name)
              raise ConfigurationError, "reddit_rss activity_weights contain duplicate keys"
            end
            unless WEIGHT_NAMES.include?(name)
              raise ConfigurationError, "reddit_rss activity_weights contain unsupported keys"
            end
            unless weight.is_a?(Integer) && weight.between?(0, 1_000)
              raise ConfigurationError, "reddit_rss activity_weights contain invalid values"
            end

            normalized[name] = weight
          end

          unless normalized.keys.sort == WEIGHT_NAMES.sort && normalized.values.sum == 1_000 &&
                 normalized.fetch("top") + normalized.fetch("rising") > 0
            raise ConfigurationError, "reddit_rss activity_weights must contain four integers summing to 1000"
          end
        end
      end
    end
  end
end
