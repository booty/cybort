require "time"

module Cybort
  module Adapters
    class Gmail < Base
      MAX_RESULTS = 500
      ADAPTER_BUDGET_SECONDS = 300
      DEFAULT_USER_ID = "me"

      def self.validate_configuration!(instance)
        options = instance.options || {}
        user_id = options.fetch(:user_id, DEFAULT_USER_ID)
        query = options.fetch(:query, "")

        valid_query = query.is_a?(String) && query.valid_encoding? &&
          query.bytesize <= 4_096 && !query.match?(/[\x00-\x1F\x7F]/)
        raise ConfigurationError, "gmail query must be valid UTF-8 without control characters" unless valid_query

        valid_user = GmailCredentials.printable?(user_id, 320) &&
          (user_id == DEFAULT_USER_ID || user_id.match?(%r{\A[^@\s/\\?#]+@[^@\s/\\?#]+\z}))
        raise ConfigurationError, "gmail user_id must be 'me' or a valid email address" unless valid_user

        unless instance.num_items_to_fetch.is_a?(Integer) && instance.num_items_to_fetch.between?(1, MAX_RESULTS)
          raise ConfigurationError, "gmail num_items_to_fetch must be an integer from 1 through #{MAX_RESULTS}"
        end

        if options.key?(:credentials_file)
          path = options[:credentials_file]
          valid_path = GmailCredentials.printable?(path, 4_096) &&
            (path.start_with?("/") || path.start_with?("~/"))
          raise ConfigurationError, "gmail credentials_file must be an absolute or ~/ path" unless valid_path
        end

        include_spam_trash = options.fetch(:include_spam_trash, false)
        unless include_spam_trash == true || include_spam_trash == false
          raise ConfigurationError, "gmail include_spam_trash must be a boolean"
        end
      end

      def fetch_from_source
        deadline = monotonic_clock.call + ADAPTER_BUDGET_SECONDS
        fetched_at = clock.call
        credentials = GmailCredentials.load(path: instance.options[:credentials_file])
        client = GmailClient.new(
          http_client: http_client,
          monotonic_clock: monotonic_clock,
          deadline_monotonic: deadline
        )
        client.authenticate(credentials: credentials)
        ids = client.list_message_ids(
          user_id: user_id,
          query: query,
          limit: instance.num_items_to_fetch,
          include_spam_trash: instance.options.fetch(:include_spam_trash, false)
        )
        items = ids.map do |id|
          item_from(client.get_message(user_id: user_id, message_id: id), id, fetched_at)
        end
        if monotonic_clock.call >= deadline
          raise GmailApiError.new(operation: :get, category: :deadline)
        end

        {
          items: items,
          sync_state: {},
          replace_existing_items: false,
          metadata: {
            source: "gmail_api",
            limit: instance.num_items_to_fetch,
            message_count: items.length
          }
        }
      end

      private

      def user_id
        instance.options.fetch(:user_id, DEFAULT_USER_ID).to_s
      end

      def query
        instance.options.fetch(:query, "").to_s
      end

      def item_from(message, requested_id, fetched_at)
        headers = message.dig("payload", "headers") || []
        values = headers.each_with_object({}) do |header, result|
          name = header["name"].downcase
          value = header["value"]
          result[name] ||= value if !value.strip.empty?
        end
        subject = values["subject"].to_s.strip
        subject = "(no subject)" if subject.empty?
        info = {
          from: values["from"],
          date_header: values["date"],
          message_id: values["message-id"],
          thread_id: message["threadId"],
          label_ids: message["labelIds"]
        }.compact

        Item.new(
          instance_id: instance.id,
          canonical_id: requested_id,
          urls: [],
          fetched_at: fetched_at,
          remote_created_at: parse_internal_date(message["internalDate"]),
          title: subject,
          body: message["snippet"],
          info: info
        )
      end

      def parse_internal_date(value)
        return nil unless value.is_a?(String) && value.match?(/\A[1-9]\d*\z/)

        Time.at(value.to_i / 1_000.0).utc
      rescue ArgumentError, RangeError
        nil
      end
    end
  end
end
