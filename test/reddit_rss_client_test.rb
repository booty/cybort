require "test_helper"
require_relative "support/reddit_rss_fixture"

class RedditRssClientTest < Minitest::Test
  include RedditRssFixture

  def parse(xml, subreddits: ["ruby"], operation: :new)
    Cybort::RedditRssClient.parse(body: xml, subreddits: subreddits, operation: operation)
  end

  def assert_rss_error(xml, category: :invalid_feed, subreddits: ["ruby"], operation: :new)
    error = assert_raises(Cybort::RedditRssError) do
      parse(xml, subreddits: subreddits, operation: operation)
    end
    assert_equal category, error.safe_metadata.fetch(:category)
    assert_nil error.cause
    refute_match(/sentinel|secret|private|file:/i, error.message)
    refute error.safe_metadata.values.any? { |value| value.to_s.match?(/sentinel|secret|private|file:/i) }
    error
  end

  def test_published_and_raw_rank_are_preserved
    xml = atom([atom_entry, atom_entry, atom_entry(id: "t3_def")])
    page = parse(xml)

    assert_equal 3, page.raw_entry_count
    assert_equal ["t3_abc", "t3_def"], page.entries.map(&:id)
    assert_equal [1, 3], page.entries.map(&:rank)
    assert_equal Time.utc(2026, 9, 6, 11), page.entries.first.published_at
    assert page.frozen?
    assert page.entries.frozen?
    assert page.entries.all? { |entry| entry.frozen? && entry.id.frozen? && entry.title.frozen? }
  end

  def test_basic_fixture_decodes_atom_entries
    page = parse(File.read(File.expand_path("fixtures/reddit_rss/basic.atom", __dir__)))

    assert_equal 2, page.raw_entry_count
    assert_equal %w[t3_abc t3_def], page.entries.map(&:id)
    assert_equal "ruby", page.entries.first.subreddit
  end

  def test_valid_empty_atom_returns_empty_page
    page = parse(atom([]))

    assert_empty page.entries
    assert_equal 0, page.raw_entry_count
  end

  def test_missing_published_does_not_fallback_to_updated
    entry = atom_entry.sub(/<published>.*?<\/published>\n/, "")
    assert_rss_error(atom([entry]), category: :invalid_feed)
  end

  def test_malformed_published_is_an_invalid_entry
    assert_rss_error(atom([atom_entry(published: "not-a-time")]), category: :invalid_entry)
  end

  def test_rejects_foreign_root_namespace
    assert_rss_error(atom([], namespace: "urn:foreign"))
  end

  def test_rejects_foreign_structural_child_namespace
    xml = atom([atom_entry.sub("<title>", '<title xmlns="urn:foreign">')])
    assert_rss_error(xml)
  end

  def test_accepts_prefixed_atom_namespace
    xml = <<~XML
      <a:feed xmlns:a="http://www.w3.org/2005/Atom">
        <a:id>https://www.reddit.com/r/ruby/</a:id><a:title>Fixture</a:title>
        <a:updated>2026-09-06T12:00:00Z</a:updated>
        <a:entry><a:id>t3_abc</a:id><a:title>Release</a:title>
          <a:published>2026-09-06T11:00:00Z</a:published>
          <a:link href="https://www.reddit.com/r/ruby/comments/abc/title/"/>
        </a:entry>
      </a:feed>
    XML

    assert_equal ["t3_abc"], parse(xml).entries.map(&:id)
  end

  def test_rejects_html_error_document_and_malformed_xml
    assert_rss_error("<html><body>sentinel</body></html>")
    assert_rss_error(atom([atom_entry]).sub("</feed>", ""))
  end

  def test_rejects_dtd_internal_and_external_entities_before_xml_parsing
    internal = <<~XML
      <!DOCTYPE feed [<!ENTITY sentinel "secret">]>
      #{atom([atom_entry(title: "&sentinel;")])}
    XML
    external = <<~XML
      <!DOCTYPE feed SYSTEM "file:///private/sentinel">
      #{atom([atom_entry])}
    XML

    assert_rss_error(internal)
    assert_rss_error(external)
  end

  def test_ignores_content_src_and_author_without_dereferencing
    xml = atom([atom_entry.sub(
      "<updated>",
      '<content src="file:///private/sentinel"><author><name>sentinel</name></author></content><updated>'
    )])

    page = parse(xml)
    assert_equal ["t3_abc"], page.entries.map(&:id)
    refute_match(/sentinel/, page.entries.first.title)
  end

  def test_rejects_wrong_entry_identity_and_comment_permalink
    assert_rss_error(atom([atom_entry(id: "t2_abc")]), category: :invalid_entry)
    xml = atom([atom_entry.sub("/comments/abc/", "/comments/abc/comment/123/")])
    assert_rss_error(xml, category: :invalid_entry)
  end

  def test_rejects_unsafe_links
    bad_links = [
      "https://www.reddit.com:443/r/ruby/comments/abc/title/",
      "https://user:pass@www.reddit.com/r/ruby/comments/abc/title/",
      "//www.reddit.com/r/ruby/comments/abc/title/",
      "https://www.reddit.com/r/ruby/comments/abc/title/?tracking=1",
      "https://www.reddit.com/r/ruby/comments/abc/title/#part",
      "https://www.reddit.com/r/ruby/comments/abc%2Fdef/title/",
      "https://www.reddit.com/r/ruby/comments/abc/%ZZ/",
      "https://www.reddit.com/r/ruby/comments/abc/../title/"
    ]
    bad_links.each do |href|
      xml = atom([atom_entry.sub(%r{https://www\.reddit\.com/r/ruby/comments/abc/title/}, href)])
      assert_rss_error(xml, category: :invalid_entry)
    end
  end

  def test_rejects_foreign_subreddit_and_accepts_case_insensitive_group
    assert_rss_error(atom([atom_entry(subreddit: "rails")]), subreddits: ["ruby"], category: :invalid_entry)
    page = parse(atom([atom_entry(subreddit: "Ruby")]), subreddits: ["RUBY"])
    assert_equal "ruby", page.entries.first.subreddit
  end

  def test_rejects_empty_control_and_oversized_titles
    assert_rss_error(atom([atom_entry(title: "")]), category: :invalid_entry)
    assert_rss_error(atom([atom_entry(title: "\u0001bad")]), category: :invalid_feed)
    assert_rss_error(atom([atom_entry(title: "x" * 2049)]), category: :invalid_entry)
  end

  def test_rejects_typed_html_or_xhtml_titles
    ["html", "xhtml"].each do |type|
      xml = atom([atom_entry.sub("<title>", "<title type=\"#{type}\">")])
      assert_rss_error(xml, category: :invalid_entry)
    end
  end

  def test_rejects_conflicting_duplicate_identity
    first = atom_entry
    second = atom_entry(title: "Different")
    assert_rss_error(atom([first, second]), category: :invalid_entry)
  end

  def test_only_first_hundred_entries_are_inspected
    entries = Array.new(100) { |index| atom_entry(id: "t3_#{index.to_s(36).sub(/^0+/, "")}") }
    entries[0] = atom_entry(id: "t3_abc")
    entries[100] = "<entry><id>t3_bad</id><title>bad</title></entry>"

    page = parse(atom(entries))
    assert_equal 100, page.raw_entry_count
  end

  def test_rejects_duplicate_structural_children
    xml = atom([atom_entry.sub("</entry>", "<title>duplicate</title></entry>")])
    assert_rss_error(xml)
  end

  def test_rejects_non_string_or_oversized_bodies
    assert_raises(Cybort::RedditRssError) { Cybort::RedditRssClient.parse(body: nil, subreddits: ["ruby"], operation: :new) }
    assert_rss_error("x" * 1_048_577, category: :response_too_large)
  end
end
