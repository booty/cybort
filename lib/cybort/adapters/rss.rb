require "digest"
require "rss"
require "time"
require "uri"

module Cybort
  module Adapters
    class RSS < Base
      def self.validate_configuration!(instance)
        url = instance.options.fetch(:url, "").to_s
        uri = URI.parse(url)
        return if %w[http https].include?(uri.scheme) && !uri.host.to_s.empty?

        raise ConfigurationError, "rss instance requires an HTTP(S) url"
      rescue URI::InvalidURIError
        raise ConfigurationError, "rss instance requires an HTTP(S) url"
      end

      private

      def fetch_from_source
        url = instance.options.fetch(:url)
        response = http_client.get(url)
        feed = parse_feed(response.body)
        items = begin
          feed.items.first(instance.num_items_to_fetch).map { |entry| item_from(entry, feed) }
        rescue StandardError
          raise RSSParseError.new(category: :invalid_shape), cause: nil
        end

        {
          items: items,
          sync_state: {},
          metadata: { status: response.status }
        }
      end

      def parse_feed(body)
        ::RSS::Parser.parse(body, false)
      rescue StandardError
        raise RSSParseError.new(category: :invalid_feed), cause: nil
      end

      def item_from(entry, feed)
        title = text_value(entry.title).to_s
        link = entry_link(entry)
        remote_created_at = entry_date(entry)
        canonical_id = entry_guid(entry) || Digest::SHA256.hexdigest([link, remote_created_at, title].join("\0"))

        Item.new(
          instance_id: instance.id,
          canonical_id: canonical_id,
          urls: link.empty? ? [] : [link],
          fetched_at: clock.call,
          remote_created_at: remote_created_at,
          title: title,
          body: entry_body(entry),
          info: { feed_title: feed_title(feed) }
        )
      end

      def feed_title(feed)
        title = if feed.respond_to?(:channel)
                  feed.channel&.title
                elsif feed.respond_to?(:title)
                  feed.title
                end
        text_value(title)
      end

      def entry_link(entry)
        link = entry.link if entry.respond_to?(:link)
        link = link.first if link.is_a?(Array)
        link = link.href if link.respond_to?(:href)
        text_value(link).to_s
      end

      def entry_body(entry)
        description = entry.description if entry.respond_to?(:description)
        return text_value(description) unless description.nil?

        content = entry.content if entry.respond_to?(:content)
        text_value(content)
      end

      def entry_date(entry)
        %i[pubDate dc_date date published updated].each do |method_name|
          next unless entry.respond_to?(method_name)

          value = entry.public_send(method_name)
          return value.content if value.respond_to?(:content)
          return value unless value.nil?
        end
        nil
      end

      def text_value(value)
        return nil if value.nil?

        value = value.content if value.respond_to?(:content)
        value.to_s
      end

      def entry_guid(entry)
        values = []
        values << entry.id if entry.respond_to?(:id)
        values << entry.guid if entry.respond_to?(:guid)
        values << entry.about if entry.respond_to?(:about)
        values << entry.dc_identifier if entry.respond_to?(:dc_identifier)
        values.each do |candidate|
          value = candidate.respond_to?(:content) ? candidate.content : candidate
          return value.to_s unless value.nil? || value.to_s.empty?
        end
        nil
      end
    end
  end
end
