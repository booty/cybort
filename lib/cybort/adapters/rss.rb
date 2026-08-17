require "digest"
require "rss"
require "time"

module Cybort
  module Adapters
    class RSS < Base
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
        remote_created_at = entry.pubDate || entry.dc_date
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

      def entry_guid(entry)
        guid = entry.guid
        value = guid.respond_to?(:content) ? guid.content : guid
        value.to_s unless value.nil? || value.to_s.empty?
      end
    end
  end
end

