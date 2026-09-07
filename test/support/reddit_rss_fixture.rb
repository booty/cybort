require "cgi/escape"

module RedditRssFixture
  def atom_entry(id: "t3_abc", subreddit: "ruby", title: "Release notes",
                 published: "2026-09-06T11:00:00Z")
    short_id = id.delete_prefix("t3_")
    safe_subreddit = CGI.escapeHTML(subreddit.to_s)
    href = CGI.escapeHTML(
      "https://www.reddit.com/r/#{subreddit}/comments/#{short_id}/title/"
    )
    <<~XML
      <entry><id>#{CGI.escapeHTML(id)}</id>
      <title>#{CGI.escapeHTML(title)}</title>
      <published>#{CGI.escapeHTML(published)}</published>
      <updated>2026-09-06T12:00:00Z</updated>
      <link rel="alternate" href="#{href}" data-subreddit="#{safe_subreddit}"/>
      </entry>
    XML
  end

  def atom(entries, namespace: "http://www.w3.org/2005/Atom")
    <<~XML
      <feed xmlns="#{CGI.escapeHTML(namespace)}">
      <id>https://www.reddit.com/r/ruby/</id><title>Fixture</title>
      <updated>2026-09-06T12:00:00Z</updated>#{entries.join}</feed>
    XML
  end
end
