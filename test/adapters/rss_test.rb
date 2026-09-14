require "test_helper"

class RssAdapterTest < Minitest::Test
  class StubHttpClient
    attr_reader :calls

    def initialize(body)
      @body = body
      @calls = []
    end

    def get(url, headers: {})
      @calls << [url, headers]
      Cybort::HttpResponse.new(status: 200, headers: {}, body: @body)
    end
  end

  def instance(num_items_to_fetch: 2, url: "https://example.test/feed.xml")
    Cybort::Configuration::Instance.new(
      id: "rss",
      name: "RSS",
      adapter: "rss",
      ttl_minutes: 30,
      num_items_to_fetch: num_items_to_fetch,
      options: { url: url }
    )
  end

  def adapter(body, num_items_to_fetch: 2, url: "https://example.test/feed.xml")
    Cybort::Adapters::RSS.new(
      instance: instance(num_items_to_fetch: num_items_to_fetch, url: url),
      context: { items: [], last_successful_fetch: nil, sync_state: nil },
      http_client: StubHttpClient.new(body),
      clock: -> { Time.utc(2026, 8, 16, 12) }
    )
  end

  def test_maps_rss_fields_and_limits_items
    result = adapter(File.read(File.expand_path("../fixtures/rss/basic.xml", __dir__)), num_items_to_fetch: 1).fetch
    item = result.items.first

    assert result.success?
    assert result.source_fetched
    assert_equal 1, result.items.length
    assert_equal "First article", item.title
    assert_equal "First article body", item.body
    assert_equal ["https://example.test/first"], item.urls
    assert_equal "guid-1", item.canonical_id
    assert_equal Time.utc(2026, 8, 16, 11), item.remote_created_at
  end

  def test_uses_stable_hash_when_guid_is_missing
    body = File.read(File.expand_path("../fixtures/rss/no_guid.xml", __dir__))
    first = adapter(body).fetch.items.first.canonical_id
    second = adapter(body).fetch.items.first.canonical_id

    assert_match(/\A[0-9a-f]{64}\z/, first)
    assert_equal first, second
  end

  def test_maps_rdf_items_with_dublin_core_dates
    body = File.read(File.expand_path("../fixtures/rss/rdf.xml", __dir__))

    result = adapter(body).fetch
    item = result.items.first

    assert result.success?
    assert_equal "RDF article", item.title
    assert_equal "https://example.test/rdf-first", item.canonical_id
    assert_equal Time.utc(2026, 8, 16, 11), item.remote_created_at
  end

  def test_maps_atom_content_when_description_is_unavailable
    body = File.read(File.expand_path("../fixtures/rss/atom.xml", __dir__))

    result = adapter(body).fetch
    item = result.items.first

    assert result.success?
    assert_equal "Atom article", item.title
    assert_equal ["https://example.test/atom-first"], item.urls
    assert_equal "Article body from Atom", item.body
    assert_equal "Example Atom Feed", item.info.fetch(:feed_title)
  end

  def test_uses_atom_id_before_link_for_canonical_identity
    body = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <feed xmlns="http://www.w3.org/2005/Atom">
        <title>Example Atom Feed</title>
        <entry>
          <id>tag:example.test,2026:stable-entry</id>
          <title>Edited article</title>
          <link href="https://example.test/edited-link"/>
          <updated>2026-08-16T11:00:00Z</updated>
        </entry>
      </feed>
    XML

    result = adapter(body).fetch

    assert result.success?
    assert_equal "tag:example.test,2026:stable-entry", result.items.first.canonical_id
  end

  def test_malformed_feed_is_a_failure
    secret = "token=super-secret"
    result = adapter("<rss><channel>#{secret}", url: "https://user:password@example.test/feed?#{secret}").fetch

    refute result.success?
    assert_instance_of Cybort::RSSParseError, result.error
    refute_includes result.error.message, secret
    refute_includes result.metadata.to_s, secret
    refute_includes result.metadata.to_s, "password"
  end
end
