require "rss"
require "rexml/document"
require "stringio"
require "time"
require "uri"

module Cybort
  class RedditRssClient
    ATOM_NAMESPACE = "http://www.w3.org/2005/Atom".freeze
    MAX_BODY_BYTES = 1_048_576
    MAX_ENTRIES = 100
    MAX_TITLE_BYTES = 2_048
    MAX_LINK_BYTES = 2_048
    SUBREDDIT_PATTERN = /\A[A-Za-z0-9_]{2,21}\z/.freeze
    SHORT_ID_PATTERN = /\A[1-9a-z][0-9a-z]{0,15}\z/.freeze
    CANONICAL_PATH_PATTERN = %r{\A/r/([A-Za-z0-9_]{2,21})/comments/([1-9a-z][0-9a-z]{0,15})(?:/[^/]+)?/?\z}.freeze
    FEED_STRUCTURAL_NAMES = %w[entry id title updated].freeze
    ENTRY_STRUCTURAL_NAMES = %w[id title published updated link].freeze
    SINGLETON_ENTRY_NAMES = %w[id title published updated].freeze
    INVALID_PERCENT_ESCAPE = /%(?![0-9A-Fa-f]{2})/.freeze
    ENCODED_UNSAFE_SEGMENT = /%(?:2f|5c|2e)/i.freeze

    Entry = Struct.new(:id, :subreddit, :title, :published_at, :rank, keyword_init: true)
    Page = Struct.new(:entries, :raw_entry_count, keyword_init: true)
    DEFAULT_CLOCK = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    ACCEPT_HEADER = "application/atom+xml, application/xml"
    USER_AGENT_MAX_BYTES = 256
    INVALID_ARGUMENTS_MESSAGE = "invalid Reddit RSS fetch arguments"
    SORT_OPERATIONS = { "new" => :new, "rising" => :rising, "top" => :top }.freeze

    def initialize(http_client:, coordinator: RedditRssCoordinator.default, monotonic_clock: DEFAULT_CLOCK)
      @http_client = http_client
      @coordinator = coordinator
      @monotonic_clock = callable(monotonic_clock, :monotonic_clock)
    end

    def fetch(sort:, subreddits:, user_agent:, deadline_monotonic:)
      operation, deadline = validate_fetch_arguments(
        sort: sort,
        subreddits: subreddits,
        user_agent: user_agent,
        deadline_monotonic: deadline_monotonic
      )
      group = subreddits.join("+")
      params = sort == "top" ? { "t" => "day", "limit" => 100 } : { "limit" => 100 }
      url = "https://www.reddit.com/r/#{group}/#{sort}/.rss?#{URI.encode_www_form(params)}"
      lease = @coordinator.acquire(operation: operation, deadline_monotonic: deadline)
      begin
        now = monotonic_now
        request_deadline = [deadline, now + 30].min
        ensure_before!(now, request_deadline, operation)
        response = @http_client.get(
          url,
          headers: { "User-Agent" => user_agent, "Accept" => ACCEPT_HEADER },
          timeout_seconds: request_deadline - now,
          deadline_monotonic: request_deadline
        )
        status = response.status.to_i
        metadata = RateLimitHeaders.parse(response.headers)
        lease.observe(metadata: metadata, status: status)
        raise_http_error(status, metadata, operation) unless status.between?(200, 299)

        ensure_before!(monotonic_now, request_deadline, operation)
        page = self.class.parse(body: response.body, subreddits: subreddits, operation: operation)
        ensure_before!(monotonic_now, deadline, operation)
        page
      rescue HttpError => error
        metadata = error.safe_metadata
        lease.observe(metadata: metadata, status: metadata[:status])
        raise_http_error(metadata[:status], metadata, operation)
      rescue HttpTransportError => error
        category = error.safe_metadata.fetch(:category)
        category = :network unless %i[network timeout response_too_large].include?(category)
        raise RedditRssError.new(operation: operation, category: category), cause: nil
      ensure
        lease.release
      end
    end

    class InvalidFeed < StandardError; end
    class InvalidEntry < StandardError; end

    class << self
      def parse(body:, subreddits:, operation:)
        unless body.is_a?(String) && body.bytesize <= MAX_BODY_BYTES
          raise_rss_error(operation, :response_too_large)
        end

        xml = body.dup.force_encoding(Encoding::UTF_8)
        if !xml.valid_encoding? || xml.match?(/<!DOCTYPE|<!ENTITY/i)
          raise_rss_error(operation, :invalid_feed)
        end

        validate_atom_structure!(StringIO.new(xml))
        feed = ::RSS::Parser.parse(StringIO.new(xml), false)
        raise InvalidFeed unless feed.is_a?(::RSS::Atom::Feed)

        configured_subreddits = normalize_subreddits(subreddits)
        prefix = feed.entries.first(MAX_ENTRIES)
        records = {}
        prefix.each_with_index do |entry, index|
          record = normalize_entry(
            entry,
            rank: index + 1,
            subreddits: configured_subreddits
          )
          previous = records[record.id]
          if previous && [previous.subreddit, previous.published_at, previous.title] !=
                         [record.subreddit, record.published_at, record.title]
            raise InvalidEntry
          end
          records[record.id] ||= record
        end

        Page.new(entries: records.values.freeze, raw_entry_count: prefix.length).freeze
      rescue InvalidEntry
        raise_rss_error(operation, :invalid_entry)
      rescue InvalidFeed, ::RSS::Error, REXML::ParseException, REXML::UndefinedNamespaceException,
             ArgumentError, EncodingError
        raise_rss_error(operation, :invalid_feed)
      end

      private

      def raise_rss_error(operation, category)
        raise RedditRssError.new(operation: operation, category: category), cause: nil
      end

      def validate_atom_structure!(io)
        document = REXML::Document.new(io)
        root = document.root
        raise InvalidFeed unless root && root.name == "feed" && root.namespace == ATOM_NAMESPACE

        root_children = root.elements.to_a
        validate_feed_children!(root_children)
        entries = root_children.select { |child| child.name == "entry" }
        entries.first(MAX_ENTRIES).each { |entry| validate_entry_children!(entry) }
      end

      def validate_feed_children!(children)
        counts = Hash.new(0)
        children.each do |child|
          next unless FEED_STRUCTURAL_NAMES.include?(child.name)

          raise InvalidFeed unless child.namespace == ATOM_NAMESPACE

          counts[child.name] += 1
          raise InvalidFeed if %w[id title updated].include?(child.name) && counts[child.name] > 1
        end
      end

      def validate_entry_children!(entry)
        raise InvalidFeed unless entry.namespace == ATOM_NAMESPACE

        counts = Hash.new(0)
        entry.elements.to_a.each do |child|
          next unless ENTRY_STRUCTURAL_NAMES.include?(child.name)

          raise InvalidFeed unless child.namespace == ATOM_NAMESPACE

          counts[child.name] += 1
          raise InvalidFeed if SINGLETON_ENTRY_NAMES.include?(child.name) && counts[child.name] > 1
        end

        %w[id title published].each do |name|
          raise InvalidFeed unless counts[name] == 1
        end
      end

      def normalize_subreddits(subreddits)
        raise InvalidEntry unless subreddits.is_a?(Array)

        subreddits.each_with_object({}) do |name, normalized|
          raise InvalidEntry unless name.is_a?(String) && name.valid_encoding? && SUBREDDIT_PATTERN.match?(name)

          normalized[name.downcase] = true
        end.freeze
      end

      def normalize_entry(entry, rank:, subreddits:)
        entry_id = content_string(entry.id)
        title = normalize_title(entry.title)
        published_at = normalize_published(entry.published)
        href = normalize_alternate_link(entry.links)
        subreddit, short_id = normalize_link(href, subreddits)
        canonical_id = "t3_#{short_id}"
        raise InvalidEntry unless entry_id == canonical_id

        Entry.new(
          id: canonical_id.freeze,
          subreddit: subreddit.freeze,
          title: title.freeze,
          published_at: published_at,
          rank: rank
        ).freeze
      rescue NoMethodError, TypeError, URI::InvalidURIError
        raise InvalidEntry
      end

      def content_string(value)
        content = value&.content
        raise InvalidEntry unless content.is_a?(String) && content.valid_encoding?

        content
      end

      def normalize_title(title)
        raise InvalidEntry unless title
        raise InvalidEntry unless title.type.nil? || title.type == "text"
        raise InvalidEntry if title.respond_to?(:xhtml) && !title.xhtml.nil?

        value = content_string(title)
        raise InvalidEntry if value.empty? || value.strip.empty? || value.bytesize > MAX_TITLE_BYTES
        raise InvalidEntry if unsafe_controls?(value)

        value
      end

      def normalize_published(published)
        value = published&.content
        raise InvalidEntry unless value.is_a?(Time)

        value.getutc
      end

      def normalize_alternate_link(links)
        alternates = Array(links).select do |link|
          link.rel.nil? || link.rel == "alternate"
        end
        hrefs = alternates.map do |link|
          href = link.href
          raise InvalidEntry unless href.is_a?(String)

          href
        end.uniq
        raise InvalidEntry unless hrefs.length == 1

        hrefs.first
      end

      def normalize_link(href, subreddits)
        raise InvalidEntry unless href.valid_encoding? && href.bytesize <= MAX_LINK_BYTES
        raise InvalidEntry if unsafe_controls?(href)
        raise InvalidEntry if href.start_with?("//")
        raise InvalidEntry if href.include?("\\")
        raise InvalidEntry if href.match?(INVALID_PERCENT_ESCAPE)
        raise InvalidEntry if href.match?(ENCODED_UNSAFE_SEGMENT)

        uri = URI.parse(href)
        if href.start_with?("/")
          raise InvalidEntry unless uri.scheme.nil? && uri.host.nil? && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
        else
          authority = href.sub(%r{\Ahttps://}, "").split("/", 2).first
          raise InvalidEntry unless href.start_with?("https://") && authority == "www.reddit.com"
          raise InvalidEntry unless uri.scheme == "https" && uri.host == "www.reddit.com"
          raise InvalidEntry if uri.userinfo || uri.query || uri.fragment
        end

        path = uri.path
        segments = path.split("/", -1)
        raise InvalidEntry if segments.each_with_index.any? do |segment, index|
          interior = index.positive? && index < segments.length - 1
          interior && segment.empty?
        end
        raise InvalidEntry if segments.any? { |segment| segment == "." || segment == ".." }

        match = CANONICAL_PATH_PATTERN.match(path)
        raise InvalidEntry unless match

        subreddit = match[1].downcase
        short_id = match[2]
        raise InvalidEntry unless SUBREDDIT_PATTERN.match?(subreddit) && SHORT_ID_PATTERN.match?(short_id)
        raise InvalidEntry unless subreddits.key?(subreddit)

        [subreddit, short_id]
      end

      def unsafe_controls?(value)
        value.each_codepoint.any? { |codepoint| codepoint < 0x20 || codepoint == 0x7F }
      end
    end

    private

    def validate_fetch_arguments(sort:, subreddits:, user_agent:, deadline_monotonic:)
      operation = SORT_OPERATIONS.fetch(sort) { raise ArgumentError, INVALID_ARGUMENTS_MESSAGE }
      unless subreddits.is_a?(Array) && !subreddits.empty? &&
             subreddits.all? { |name| name.is_a?(String) && name.valid_encoding? && SUBREDDIT_PATTERN.match?(name) } &&
             subreddits.uniq.length == subreddits.length && subreddits == subreddits.sort
        raise ArgumentError, INVALID_ARGUMENTS_MESSAGE
      end
      unless user_agent.is_a?(String) && user_agent.valid_encoding? && !user_agent.strip.empty? &&
             user_agent.bytesize <= USER_AGENT_MAX_BYTES && !unsafe_controls?(user_agent)
        raise ArgumentError, INVALID_ARGUMENTS_MESSAGE
      end

      deadline = Float(deadline_monotonic)
      raise ArgumentError, INVALID_ARGUMENTS_MESSAGE unless deadline.finite?

      [operation, deadline]
    rescue ArgumentError, RangeError, TypeError
      raise ArgumentError, INVALID_ARGUMENTS_MESSAGE
    end

    def raise_http_error(status, metadata, operation)
      category = case status.to_i
                 when 401, 403 then :access_denied
                 when 429 then :rate_limited
                 else :http
                 end
      retry_after_seconds = category == :rate_limited ? maximum_retry_delay(metadata) : nil
      raise RedditRssError.new(
        operation: operation,
        category: category,
        status: status,
        retry_after_seconds: retry_after_seconds
      ), cause: nil
    end

    def maximum_retry_delay(metadata)
      hints = %i[retry_after_seconds ratelimit_reset_seconds].filter_map do |key|
        value = metadata[key]
        next unless value.is_a?(Numeric) && value.finite? && value >= 0

        value.is_a?(Integer) ? value : value.ceil
      end
      [60, hints.max || 0].max
    end

    def ensure_before!(now, deadline, operation)
      return if now < deadline

      raise RedditRssError.new(operation: operation, category: :deadline), cause: nil
    end

    def monotonic_now
      value = Float(@monotonic_clock.call)
      raise ArgumentError, "monotonic clock must return a finite number" unless value.finite?

      value
    rescue ArgumentError, TypeError
      raise ArgumentError, "monotonic clock must return a finite number"
    end

    def callable(value, name)
      raise ArgumentError, "#{name} must be callable" unless value.respond_to?(:call)

      value
    end

    def unsafe_controls?(value)
      value.each_codepoint.any? { |codepoint| codepoint < 0x20 || codepoint == 0x7F }
    end
  end
end
