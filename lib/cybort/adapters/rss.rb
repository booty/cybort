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
        feed = ::RSS::Parser.parse(response.body, false)
        items = feed.items.first(instance.num_items_to_fetch).map { |entry| item_from(entry, feed, url) }

        {
          items: items,
          sync_state: {},
          metadata: { url: url, status: response.status }
        }
      end

      def item_from(entry, feed, url)
        title = entry.title.to_s
        link = entry.link.to_s
        remote_created_at = entry_date(entry)
        canonical_id = entry_guid(entry) || Digest::SHA256.hexdigest([link, remote_created_at, title].join("\0"))

        Item.new(
          instance_id: instance.id,
          canonical_id: canonical_id,
          urls: link.empty? ? [] : [link],
          fetched_at: clock.call,
          remote_created_at: remote_created_at,
          title: title,
          body: entry.description,
          info: { feed_title: feed.channel.title, feed_url: url }
        )
      end

      def entry_date(entry)
        %i[pubDate dc_date date published updated].each do |method_name|
          next unless entry.respond_to?(method_name)

          value = entry.public_send(method_name)
          return value unless value.nil?
        end
        nil
      end

      def entry_guid(entry)
        guid = if entry.respond_to?(:guid)
                 entry.guid
               elsif entry.respond_to?(:about)
                 entry.about
               elsif entry.respond_to?(:dc_identifier)
                 entry.dc_identifier
               end
        value = guid.respond_to?(:content) ? guid.content : guid
        value.to_s unless value.nil? || value.to_s.empty?
      end
    end
  end
end
