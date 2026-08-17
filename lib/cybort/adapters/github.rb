require "json"
require "time"

module Cybort
  module Adapters
    class GitHub < Base
      DEFAULT_API_URL = "https://api.github.com/notifications"

      def initialize(**kwargs)
        super
        raise ConfigurationError, "github instance requires token" if token.empty?
      end

      private

      def fetch_from_source
        response = http_client.get(
          instance.options.fetch(:api_url, DEFAULT_API_URL),
          headers: {
            "Accept" => "application/vnd.github+json",
            "Authorization" => "Bearer #{token}"
          }
        )
        notifications = JSON.parse(response.body)
        items = notifications.first(instance.num_items_to_fetch).map { |notification| item_from(notification) }

        {
          items: items,
          sync_state: {},
          metadata: { status: response.status }
        }
      end

      def token
        instance.options.fetch(:token, "").to_s
      end

      def item_from(notification)
        subject = notification.fetch("subject")
        repository = notification.fetch("repository")
        repository_name = repository.fetch("full_name")
        repository_url = repository["html_url"]
        subject_url = subject["url"]
        reason = notification.fetch("reason")

        Item.new(
          instance_id: instance.id,
          canonical_id: notification.fetch("id").to_s,
          urls: [subject_url, repository_url].compact,
          fetched_at: clock.call,
          remote_created_at: Time.iso8601(notification.fetch("updated_at")),
          title: subject.fetch("title"),
          body: "#{reason} in #{repository_name}",
          info: { reason: reason, repository: repository_name }
        )
      end
    end
  end
end

