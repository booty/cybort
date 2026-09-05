require "uri"

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

      attr_reader :reddit_client, :coordinator, :include_subreddits, :exclude_subreddits,
                  :joined_effective, :explicit_to_fetch

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
        @joined_effective = [].freeze
        @explicit_to_fetch = [].freeze
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
        @joined_effective = [].freeze
        @explicit_to_fetch = [].freeze

        session = reddit_client.authenticate(
          client_id: option(instance.options, :client_id),
          client_secret: option(instance.options, :client_secret),
          refresh_token: option(instance.options, :refresh_token),
          user_agent: option(instance.options, :user_agent)
        )

        subscriptions, subscription_page_count = discover_subscriptions(session)
        @joined_effective = (subscriptions - exclude_subreddits).sort.freeze
        @explicit_to_fetch = (include_subreddits - exclude_subreddits - subscriptions).sort.freeze
        effective = (@joined_effective + @explicit_to_fetch).uniq

        messages, unread_page_count = collect_unread_messages(session)
        submissions, listing_metadata = collect_submissions(session, effective)
        fetched_at = clock.call
        ranked_threads = RedditActivity.rank(submissions.map(&:candidate), fetched_at: fetched_at)
        selected = RedditActivity.select(
          limit: instance.num_items_to_fetch,
          messages: RedditActivity.assign_message_priority(messages.map(&:to_h)),
          megas: ranked_threads.select(&:megathread?),
          threads: ranked_threads.reject(&:megathread?)
        )

        {
          items: build_items(selected, submissions, fetched_at),
          sync_state: {},
          metadata: build_metadata(
            subscription_page_count: subscription_page_count,
            unread_page_count: unread_page_count,
            listing_metadata: listing_metadata,
            qualifying_message_count: messages.length,
            thread_candidate_count: submissions.length
          ),
          replace_existing_items: true
        }
      end

      SubmissionRecord = Struct.new(:candidate, :canonical_url, :source_rank, keyword_init: true)

      def discover_subscriptions(session)
        names = {}
        page_count = 0
        reddit_client.each_subscription_page(session: session) do |children|
          page_count += 1
          unless children.is_a?(Array)
            raise ValidationError, "Reddit subscription page children must be an array"
          end

          children.each do |child|
            name = validate_subscription(child)
            names[name] = true
          end
        end
        [names.keys.sort, page_count]
      end

      def validate_subscription(child)
        unless child.is_a?(Hash) && value_for(child, :kind) == "t5" && value_for(child, :data).is_a?(Hash)
          raise ValidationError, "invalid Reddit subscription"
        end

        data = value_for(child, :data)
        id = value_for(data, :id)
        name = value_for(data, :name)
        display_name = value_for(data, :display_name)
        unless valid_base36_id?(id) && name == "t5_#{id}" && valid_subreddit_name?(display_name)
          raise ValidationError, "invalid Reddit subscription identity"
        end

        display_name.downcase
      end

      MessageRecord = Struct.new(:fullname, :id, :title, :created_utc, keyword_init: true)

      def collect_unread_messages(session)
        messages = []
        seen = {}
        page_count = 0

        reddit_client.each_unread_page(session: session) do |children|
          page_count += 1
          unless children.is_a?(Array)
            raise ValidationError, "Reddit unread page children must be an array"
          end

          page_messages = children.filter_map { |child| normalize_unread_message(child) }
          page_messages.each do |message|
            next if seen.key?(message.fullname)

            seen[message.fullname] = true
            messages << message
          end
          break if messages.length >= instance.num_items_to_fetch
        end

        [messages, page_count]
      end

      def normalize_unread_message(child)
        return nil unless child.is_a?(Hash) && value_for(child, :kind) == "t4"

        data = value_for(child, :data)
        raise ValidationError, "invalid Reddit unread message" unless data.is_a?(Hash)

        id = value_for(data, :id)
        fullname = value_for(data, :name)
        created_utc = value_for(data, :created_utc)
        unless valid_base36_id?(id) && fullname == "t4_#{id}" && finite_number?(created_utc)
          raise ValidationError, "invalid Reddit unread message identity"
        end

        return nil unless value_for(data, :new) == true
        was_comment = value_for(data, :was_comment)
        return nil unless was_comment.nil? || was_comment == false

        subject = value_for(data, :subject)
        subject = "Unread Reddit message" unless subject.is_a?(String) && !subject.strip.empty?
        MessageRecord.new(fullname: fullname, id: id, title: subject, created_utc: created_utc)
      end

      def collect_submissions(session, effective)
        records = {}
        metadata = {
          home_hot_page_count: 0,
          explicit_subreddit_request_count: 0,
          news_dedicated_request: false
        }

        if !joined_effective.empty?
          metadata[:home_hot_page_count] = 1
          consume_submissions(
            records,
            reddit_client.home_hot(session: session),
            source: :home,
            expected_subreddit: nil,
            allowed_subreddits: joined_effective
          )
        end

        explicit_to_fetch.each do |subreddit|
          metadata[:explicit_subreddit_request_count] += 1
          consume_submissions(
            records,
            reddit_client.subreddit_hot(session: session, subreddit: subreddit, operation: :subreddit_hot),
            source: subreddit == "news" ? :news : :subreddit,
            expected_subreddit: subreddit,
            allowed_subreddits: effective
          )
        end

        if joined_effective.include?("news")
          metadata[:news_dedicated_request] = true
          consume_submissions(
            records,
            reddit_client.subreddit_hot(session: session, subreddit: "news", operation: :news_hot),
            source: :news,
            expected_subreddit: "news",
            allowed_subreddits: effective
          )
        end

        [records.values, metadata]
      end

      def consume_submissions(records, children, source:, expected_subreddit:, allowed_subreddits:)
        unless children.is_a?(Array)
          raise ValidationError, "Reddit hot listing children must be an array"
        end

        children.each do |child|
          record = normalize_submission(child, source: source, expected_subreddit: expected_subreddit)
          next if source == :home && !allowed_subreddits.include?(record.candidate.subreddit)

          if expected_subreddit && record.candidate.subreddit != expected_subreddit
            raise ValidationError, "Reddit subreddit identity mismatch"
          end
          merge_submission_record(records, record)
        end
      end

      def normalize_submission(child, source:, expected_subreddit:)
        unless child.is_a?(Hash) && value_for(child, :kind) == "t3" && value_for(child, :data).is_a?(Hash)
          raise ValidationError, "invalid Reddit submission"
        end

        data = value_for(child, :data)
        id = value_for(data, :id)
        fullname = value_for(data, :name)
        subreddit = value_for(data, :subreddit)
        title = value_for(data, :title)
        score = value_for(data, :score)
        comments = value_for(data, :num_comments)
        created_utc = value_for(data, :created_utc)
        permalink = value_for(data, :permalink)
        stickied = data.key?("stickied") ? data["stickied"] : data[:stickied]
        stickied = false if stickied.nil?

        unless valid_base36_id?(id) && fullname == "t3_#{id}" && valid_subreddit_name?(subreddit) &&
               title.is_a?(String) && !title.strip.empty? && score.is_a?(Integer) &&
               comments.is_a?(Integer) && finite_number?(created_utc) &&
               (stickied == true || stickied == false)
          raise ValidationError, "invalid Reddit submission identity or fields"
        end

        subreddit = subreddit.downcase
        if expected_subreddit && subreddit != expected_subreddit
          raise ValidationError, "Reddit subreddit identity mismatch"
        end
        canonical_url = canonical_submission_url(permalink, subreddit: subreddit, id: id)
        candidate = RedditActivity.candidate(
          fullname: fullname,
          subreddit: subreddit,
          title: title,
          votes: score,
          comments: comments,
          created_utc: created_utc,
          stickied: stickied
        )
        SubmissionRecord.new(
          candidate: candidate,
          canonical_url: canonical_url,
          source_rank: { home: 0, subreddit: 1, news: 2 }.fetch(source)
        )
      end

      def merge_submission_record(records, record)
        fullname = record.candidate.fullname
        existing = records[fullname]
        unless existing
          records[fullname] = record
          return
        end

        if existing.candidate.subreddit != record.candidate.subreddit ||
           existing.canonical_url != record.canonical_url
          raise ValidationError, "Reddit duplicate submission identity mismatch"
        end
        records[fullname] = record if record.source_rank > existing.source_rank
      end

      def build_items(selected, submissions, fetched_at)
        records = submissions.to_h { |record| [record.candidate.fullname, record] }
        selected.map do |value|
          if value.is_a?(Hash) && value.fetch(:fullname).start_with?("t4_")
            Item.new(
              instance_id: instance.id,
              canonical_id: value.fetch(:fullname),
              urls: ["https://www.reddit.com/message/messages/#{value.fetch(:fullname).delete_prefix("t4_")}"],
              fetched_at: fetched_at,
              remote_created_at: Time.at(value.fetch(:created_utc)).utc,
              title: value.fetch(:title),
              body: nil,
              priority: value.fetch(:priority),
              action_item: true,
              info: {
                kind: "legacy_private_message",
                unread: true,
                selection_rank: value.fetch(:selection_rank)
              }
            )
          else
            candidate = value
            record = records.fetch(candidate.fullname)
            Item.new(
              instance_id: instance.id,
              canonical_id: candidate.fullname,
              urls: [record.canonical_url],
              fetched_at: fetched_at,
              remote_created_at: Time.at(candidate.created_utc).utc,
              title: candidate.title,
              body: nil,
              priority: candidate.priority,
              action_item: false,
              info: {
                kind: "submission",
                subreddit: candidate.subreddit,
                vote_score: candidate.vote_score,
                comment_count: candidate.comment_count,
                activity_score_milli: candidate.activity_score_milli,
                megathread: candidate.megathread,
                stickied: candidate.stickied,
                selection_rank: candidate.selection_rank
              }
            )
          end
        end
      end

      def build_metadata(subscription_page_count:, unread_page_count:, listing_metadata:, qualifying_message_count:, thread_candidate_count:)
        metadata = {
          chat_collection: "unsupported_by_documented_data_api",
          coverage_mode: "personalized_home_plus_explicit_single_subreddit",
          subscription_page_count: subscription_page_count,
          unread_page_count: unread_page_count,
          home_hot_page_count: listing_metadata.fetch(:home_hot_page_count),
          explicit_subreddit_request_count: listing_metadata.fetch(:explicit_subreddit_request_count),
          news_dedicated_request: listing_metadata.fetch(:news_dedicated_request),
          qualifying_message_count: qualifying_message_count,
          thread_candidate_count: thread_candidate_count
        }
        safe_metadata = reddit_client.respond_to?(:safe_metadata) ? reddit_client.safe_metadata : {}
        %i[ratelimit_used ratelimit_remaining ratelimit_reset_seconds].each do |key|
          value = safe_metadata[key] || safe_metadata[key.to_s]
          metadata[key] = value if finite_nonnegative_number?(value)
        end
        metadata
      end

      def canonical_submission_url(permalink, subreddit:, id:)
        unless permalink.is_a?(String) && permalink.valid_encoding? && !permalink.empty? &&
               !permalink.match?(RedditClient::CONTROL_PATTERN) && !permalink.include?("\\") &&
               !permalink.include?("?") && !permalink.include?("#") && permalink.start_with?("/") &&
               !permalink.start_with?("//") && !permalink.match?(/%(?![0-9A-Fa-f]{2})/) &&
               !permalink.match?(/%(?:2f|5c|3f|23)/i)
          raise ValidationError, "invalid Reddit permalink"
        end

        decoded = URI::RFC2396_PARSER.unescape(permalink)
        unless decoded.valid_encoding? && !decoded.match?(RedditClient::CONTROL_PATTERN) && !decoded.include?("\\")
          raise ValidationError, "invalid Reddit permalink"
        end

        segments = decoded.split("/", -1)
        expected = ["", "r", subreddit, "comments", id]
        unless segments.length >= expected.length && segments.first(expected.length) == expected
          raise ValidationError, "Reddit permalink identity mismatch"
        end
        path_segments = segments.drop(1)
        path_segments.each_with_index do |segment, index|
          if segment == "." || segment == ".." || (segment.empty? && index < path_segments.length - 1)
            raise ValidationError, "invalid Reddit permalink"
          end
        end

        encoded = path_segments.map { |segment| URI::RFC2396_PARSER.escape(segment, /[^A-Za-z0-9._~-]/) }
        "https://www.reddit.com/#{encoded.join("/")}"
      rescue ArgumentError, Encoding::InvalidByteSequenceError
        raise ValidationError, "invalid Reddit permalink"
      end

      def valid_subreddit_name?(value)
        value.is_a?(String) && value.valid_encoding? && value.match?(RedditClient::SUBREDDIT_PATTERN)
      end

      def valid_base36_id?(value)
        return false unless value.is_a?(String) && value.match?(/\A[0-9a-z]+\z/)

        Integer(value, 36).to_s(36) == value
      rescue ArgumentError
        false
      end

      def finite_number?(value)
        (value.is_a?(Integer) || value.is_a?(Float)) && value.finite?
      end

      def finite_nonnegative_number?(value)
        finite_number?(value) && value >= 0
      end

      def value_for(hash, key)
        return hash[key] if hash.key?(key)
        return hash[key.to_s] if hash.key?(key.to_s)

        nil
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
