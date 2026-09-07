require "digest"
require "json"
require "time"

module Cybort
  # Pure, bounded state for the public Reddit RSS observed universe.  This
  # class deliberately owns neither persistence nor source I/O: its input is
  # copied at the JSON boundary and every transition is built on a new copy.
  class RedditRssState
    VERSION = 1
    SCORING_VERSION = "rss-rank-v1"
    MAX_CANDIDATES = 2_000
    MAX_POLLS = 4
    MAX_RANKS = 100
    MAX_SERIALIZED_BYTES = 8_388_608
    CANDIDATE_LIFETIME_SECONDS = 172_800
    FUTURE_SKEW_SECONDS = 300
    HISTORY_GAP_SECONDS = 3_600
    MAX_SCALAR_BYTES = 2_048
    MAX_DEPTH = 16
    # The largest valid collection is the candidate dictionary.  Keeping the
    # generic pre-copy walk at this limit rejects an over-cap candidate map
    # before canonicalization can allocate a second copy.
    MAX_COLLECTION_LENGTH = MAX_CANDIDATES
    SUBREDDIT_PATTERN = RedditRssClient::SUBREDDIT_PATTERN
    ID_PATTERN = /\At3_([1-9a-z][0-9a-z]{0,15})\z/.freeze
    FINGERPRINT_PATTERN = /\A[0-9a-f]{64}\z/.freeze
    WEIGHT_NAMES = %w[top rising momentum persistence].freeze
    ENVELOPE_KEYS = %w[
      version scoring_version fingerprint started_at last_truncated_at candidates polls
    ].freeze
    CANDIDATE_KEYS = %w[subreddit title published_at first_seen_at last_seen_at].freeze
    POLL_KEYS = %w[at top_count rising_count top_ranks rising_ranks].freeze

    Transition = Struct.new(
      :state, :previous_poll, :previous_candidate_ids, :flags,
      :future_exclusion_count, keyword_init: true
    )

    class InvalidState < StandardError; end
    class StateTooLarge < StandardError; end

    def initialize(raw:, subreddits:, weights:)
      @subreddits = normalize_subreddits(subreddits)
      @weights = normalize_weights(weights)
      @fingerprint = Digest::SHA256.hexdigest(JSON.generate([@subreddits, WEIGHT_NAMES.map { |name| @weights.fetch(name) }]))
      @prior_state = load_state(raw)
    rescue RedditRssError
      raise
    rescue StandardError
      raise_invalid_state
    end

    def advance(pages:, now:)
      current_time = normalize_now(now)
      candidates = deep_dup(@prior_state ? @prior_state.fetch("candidates") : {})
      polls = deep_dup(@prior_state ? @prior_state.fetch("polls") : [])
      old_started_at = @prior_state && @prior_state.fetch("started_at")
      old_last_truncated_at = @prior_state && @prior_state.fetch("last_truncated_at")
      saved_last_poll_at = polls.empty? ? nil : parse_time(polls.last.fetch("at"))
      config_reset = @prior_state &&
                     (@prior_state.fetch("fingerprint") != @fingerprint ||
                      @prior_state.fetch("scoring_version") != SCORING_VERSION)
      if config_reset
        candidates = {}
        polls = []
      else
        candidates.each_value do |candidate|
          raise InvalidState unless @subreddits.include?(candidate.fetch("subreddit"))
        end
      end

      future_candidate_ids = candidates.each_with_object([]) do |(id, candidate), ids|
        ids << id if parse_time(candidate.fetch("published_at")) > current_time + FUTURE_SKEW_SECONDS
      end
      history_reset = !!config_reset
      history_reset ||= !future_candidate_ids.empty?
      clock_reset = false
      if saved_last_poll_at
        clock_reset = saved_last_poll_at >= current_time
        clock_reset ||= saved_last_poll_at > current_time + FUTURE_SKEW_SECONDS
        history_reset ||= clock_reset
        history_reset ||= current_time - saved_last_poll_at > HISTORY_GAP_SECONDS
      end
      history_reset = true if @prior_state && stored_observation_in_future?(current_time)
      if history_reset
        polls = []
        old_started_at = time_string(current_time)
        candidates = clamp_observation_times(candidates, current_time) if clock_reset || stored_observation_in_future?(current_time)
        old_last_truncated_at = clamp_time_string(old_last_truncated_at, current_time)
      end
      future_candidate_ids.each { |id| candidates.delete(id) }

      previous_poll = history_reset || polls.empty? ? nil : deep_freeze(deep_dup(polls.last))
      previous_candidate_ids = candidates.keys.sort.freeze
      normalized_pages = normalize_pages(pages)
      current_entries, rank_maps, future_ids = collect_entries(normalized_pages, current_time)
      current_entries.each_value do |record|
        existing = candidates[record.fetch("id")]
        if existing
          if existing.fetch("subreddit") != record.fetch("subreddit") ||
             existing.fetch("published_at") != record.fetch("published_at")
            raise InvalidState
          end
          existing["title"] = record.fetch("title")
          existing["last_seen_at"] = time_string(current_time)
        else
          candidates[record.fetch("id")] = {
            "subreddit" => record.fetch("subreddit"),
            "title" => record.fetch("title"),
            "published_at" => record.fetch("published_at"),
            "first_seen_at" => time_string(current_time),
            "last_seen_at" => time_string(current_time)
          }
        end
      end

      candidates.delete_if do |_id, candidate|
        publication = parse_time(candidate.fetch("published_at"))
        last_seen = parse_time(candidate.fetch("last_seen_at"))
        publication <= current_time - CANDIDATE_LIFETIME_SECONDS ||
          last_seen <= current_time - CANDIDATE_LIFETIME_SECONDS
      end

      last_truncated_at = old_last_truncated_at
      if candidates.length > MAX_CANDIDATES
        excess = candidates.length - MAX_CANDIDATES
        evict = candidates.sort_by do |id, candidate|
          [
            parse_time(candidate.fetch("published_at")),
            parse_time(candidate.fetch("last_seen_at")),
            id
          ]
        end.first(excess)
        evict.each { |id, _candidate| candidates.delete(id) }
        last_truncated_at = time_string(current_time)
      end

      polls << {
        "at" => time_string(current_time),
        "top_count" => normalized_pages.fetch("top").fetch(:raw_entry_count),
        "rising_count" => normalized_pages.fetch("rising").fetch(:raw_entry_count),
        "top_ranks" => rank_maps.fetch("top"),
        "rising_ranks" => rank_maps.fetch("rising")
      }
      polls = polls.last(MAX_POLLS)

      state = {
        "version" => VERSION,
        "scoring_version" => SCORING_VERSION,
        "fingerprint" => @fingerprint,
        "started_at" => old_started_at || time_string(current_time),
        "last_truncated_at" => last_truncated_at,
        "candidates" => candidates.sort.to_h,
        "polls" => polls
      }
      state = canonical_output_state(state)
      validate_canonical_state!(state)
      ensure_serialized_size!(state)

      flags = {
        "history_gap" => history_reset,
        "state_truncated" => !last_truncated_at.nil? &&
                              current_time - parse_time(last_truncated_at) <= 86_400,
        "future_entries_excluded" => !future_ids.empty?
      }
      Transition.new(
        state: state,
        previous_poll: previous_poll,
        previous_candidate_ids: previous_candidate_ids,
        flags: deep_freeze(flags),
        future_exclusion_count: future_ids.length
      ).freeze
    rescue RedditRssError
      raise
    rescue StateTooLarge
      raise RedditRssError.new(operation: :state, category: :state_too_large), cause: nil
    rescue InvalidState, StandardError
      raise_invalid_state
    end

    private

    def load_state(raw)
      return nil if raw.nil?
      if raw.is_a?(Hash) && raw.empty?
        return nil
      end

      bounded_walk!(raw)
      validate_raw_state!(raw)
      canonical = canonicalize(raw)
      validate_canonical_state!(canonical)
      ensure_serialized_size!(canonical)
      deep_freeze(canonical)
    rescue RedditRssError
      raise
    rescue StateTooLarge
      raise RedditRssError.new(operation: :state, category: :state_too_large), cause: nil
    rescue InvalidState, StandardError
      raise_invalid_state
    end

    def normalize_subreddits(value)
      unless value.is_a?(Array) && value.length.between?(1, 10)
        raise_invalid_state
      end
      normalized = value.map do |name|
        unless name.is_a?(String) && name.valid_encoding? && SUBREDDIT_PATTERN.match?(name)
          raise_invalid_state
        end

        name.downcase
      end.uniq.sort
      raise_invalid_state if normalized.empty?

      normalized.freeze
    end

    def normalize_weights(value)
      unless value.is_a?(Hash)
        raise_invalid_state
      end
      keys = []
      value.each_key do |key|
        unless key.is_a?(String) || key.is_a?(Symbol)
          raise_invalid_state
        end

        logical = key.to_s
        raise_invalid_state if keys.include?(logical)

        keys << logical
      end
      raise_invalid_state unless keys.sort == WEIGHT_NAMES.sort
      normalized = WEIGHT_NAMES.to_h do |name|
        weight = value.each_pair.find { |key, _| key.to_s == name }&.last
        unless weight.is_a?(Integer) && weight.between?(0, 1_000)
          raise_invalid_state
        end

        [name, weight]
      end
      raise_invalid_state unless normalized.values.sum == 1_000 && normalized.fetch("top") + normalized.fetch("rising") > 0

      normalized.freeze
    end

    def bounded_walk!(value, depth = 0, seen = {}, path = [])
      raise InvalidState if depth > MAX_DEPTH
      case value
      when Hash
        raise InvalidState if seen[value.object_id]

        seen[value.object_id] = true
        count = 0
        logical_keys = {}
        value.each_pair do |key, child|
          count += 1
          raise InvalidState if count > collection_limit(path, :hash)
          unless key.is_a?(String) || key.is_a?(Symbol)
            raise InvalidState
          end
          key_string = key.to_s
          raise InvalidState if key_string.bytesize > MAX_SCALAR_BYTES || logical_keys.key?(key_string)

          logical_keys[key_string] = true
          bounded_scalar!(key_string)
          path << key_string
          bounded_walk!(child, depth + 1, seen, path)
          path.pop
        end
        seen.delete(value.object_id)
      when Array
        raise InvalidState if seen[value.object_id]

        seen[value.object_id] = true
        raise InvalidState if value.length > collection_limit(path, :array)
        value.each do |child|
          bounded_walk!(child, depth + 1, seen, path)
        end
        seen.delete(value.object_id)
      when String
        bounded_scalar!(value)
      when Integer, TrueClass, FalseClass, NilClass
        raise InvalidState if value.is_a?(Integer) && value.bit_length > 63
      else
        raise InvalidState
      end
      true
    end

    def collection_limit(path, kind)
      return MAX_POLLS if kind == :array && path.last == "polls"

      case path.last
      when "candidates"
        MAX_CANDIDATES
      when "top_ranks", "rising_ranks"
        MAX_RANKS
      else
        MAX_COLLECTION_LENGTH
      end
    end

    def bounded_scalar!(value)
      raise InvalidState unless value.valid_encoding? && value.bytesize <= MAX_SCALAR_BYTES
      raise InvalidState if value.each_codepoint.any? { |codepoint| codepoint < 0x20 || codepoint == 0x7F }
    rescue ArgumentError, EncodingError
      raise InvalidState
    end

    def canonicalize(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, child), copy| copy[key.to_s.dup] = canonicalize(child) }
      when Array
        value.map { |child| canonicalize(child) }
      when String
        value.dup
      else
        value
      end
    end

    # Validate semantic state constraints while the caller still owns the
    # object graph.  This pass intentionally scans in place and only retains
    # bounded scalar/rank locals; canonicalize/deep_freeze runs afterward.
    def validate_raw_state!(state)
      assert_raw_keys!(state, ENVELOPE_KEYS)
      raise InvalidState unless raw_value(state, "version") == VERSION

      scoring_version = raw_value(state, "scoring_version")
      raise InvalidState unless scoring_version.is_a?(String) && printable?(scoring_version) && scoring_version.bytesize <= 128

      fingerprint = raw_value(state, "fingerprint")
      raise InvalidState unless fingerprint.is_a?(String) && FINGERPRINT_PATTERN.match?(fingerprint)
      parse_canonical_time!(raw_value(state, "started_at"))
      truncated = raw_value(state, "last_truncated_at")
      parse_canonical_time!(truncated) unless truncated.nil?
      validate_raw_candidates!(raw_value(state, "candidates"))
      validate_raw_polls!(raw_value(state, "polls"))
      true
    end

    def validate_raw_candidates!(candidates)
      raise InvalidState unless candidates.is_a?(Hash) && candidates.length <= MAX_CANDIDATES
      candidates.each_pair do |id, candidate|
        validate_id!(id.to_s)
        assert_raw_keys!(candidate, CANDIDATE_KEYS)
        subreddit = raw_value(candidate, "subreddit")
        title = raw_value(candidate, "title")
        unless subreddit.is_a?(String) && subreddit.valid_encoding? && SUBREDDIT_PATTERN.match?(subreddit) &&
               subreddit == subreddit.downcase
          raise InvalidState
        end
        unless title.is_a?(String) && title.valid_encoding? && !title.empty? && title.strip != "" &&
               title.bytesize <= MAX_SCALAR_BYTES && printable?(title)
          raise InvalidState
        end
        publication = parse_canonical_time!(raw_value(candidate, "published_at"))
        first_seen = parse_canonical_time!(raw_value(candidate, "first_seen_at"))
        last_seen = parse_canonical_time!(raw_value(candidate, "last_seen_at"))
        raise InvalidState if first_seen > last_seen
        raise InvalidState if publication.nil?
      end
    end

    def validate_raw_polls!(polls)
      raise InvalidState unless polls.is_a?(Array) && polls.length <= MAX_POLLS
      previous = nil
      polls.each do |poll|
        assert_raw_keys!(poll, POLL_KEYS)
        at = parse_canonical_time!(raw_value(poll, "at"))
        raise InvalidState if previous && at <= previous
        previous = at
        top_count = raw_value(poll, "top_count")
        rising_count = raw_value(poll, "rising_count")
        unless top_count.is_a?(Integer) && top_count.between?(0, MAX_RANKS) &&
               rising_count.is_a?(Integer) && rising_count.between?(0, MAX_RANKS)
          raise InvalidState
        end
        validate_raw_ranks!(raw_value(poll, "top_ranks"), top_count)
        validate_raw_ranks!(raw_value(poll, "rising_ranks"), rising_count)
      end
    end

    def validate_raw_ranks!(ranks, count)
      raise InvalidState unless ranks.is_a?(Hash) && ranks.length <= count
      seen = {}
      ranks.each_pair do |id, rank|
        validate_id!(id.to_s)
        raise InvalidState unless rank.is_a?(Integer) && rank.between?(1, count)
        raise InvalidState if seen.key?(rank)

        seen[rank] = true
      end
    end

    def assert_raw_keys!(hash, expected)
      raise InvalidState unless hash.is_a?(Hash)
      count = 0
      expected_set = expected
      hash.each_key do |key|
        logical = key.to_s
        raise InvalidState unless expected_set.include?(logical)

        count += 1
      end
      raise InvalidState unless count == expected.length
      true
    end

    def raw_value(hash, expected)
      found = false
      value = nil
      hash.each_pair do |key, child|
        next unless key.to_s == expected

        raise InvalidState if found

        found = true
        value = child
      end
      raise InvalidState unless found

      value
    end

    def validate_canonical_state!(state)
      unless state.is_a?(Hash) && state.keys.sort == ENVELOPE_KEYS.sort
        raise InvalidState
      end
      raise InvalidState unless state.fetch("version") == VERSION
      scoring_version = state.fetch("scoring_version")
      unless scoring_version.is_a?(String) && printable?(scoring_version) && scoring_version.bytesize <= 128
        raise InvalidState
      end
      fingerprint = state.fetch("fingerprint")
      raise InvalidState unless fingerprint.is_a?(String) && FINGERPRINT_PATTERN.match?(fingerprint)
      parse_canonical_time!(state.fetch("started_at"))
      truncated = state.fetch("last_truncated_at")
      parse_canonical_time!(truncated) unless truncated.nil?
      validate_candidates!(state.fetch("candidates"))
      validate_polls!(state.fetch("polls"))
      true
    end

    def validate_candidates!(candidates)
      raise InvalidState unless candidates.is_a?(Hash) && candidates.length <= MAX_CANDIDATES
      candidates.each_pair do |id, candidate|
        validate_id!(id)
        raise InvalidState unless candidate.is_a?(Hash) && candidate.keys.sort == CANDIDATE_KEYS.sort
        subreddit = candidate.fetch("subreddit")
        title = candidate.fetch("title")
        unless subreddit.is_a?(String) && subreddit.valid_encoding? && SUBREDDIT_PATTERN.match?(subreddit) &&
               subreddit == subreddit.downcase
          raise InvalidState
        end
        unless title.is_a?(String) && title.valid_encoding? && !title.empty? && title.strip != "" && title.bytesize <= MAX_SCALAR_BYTES && printable?(title)
          raise InvalidState
        end
        publication = parse_canonical_time!(candidate.fetch("published_at"))
        first_seen = parse_canonical_time!(candidate.fetch("first_seen_at"))
        last_seen = parse_canonical_time!(candidate.fetch("last_seen_at"))
        raise InvalidState if first_seen > last_seen
        raise InvalidState if publication.nil?
      end
    end

    def validate_polls!(polls)
      raise InvalidState unless polls.is_a?(Array) && polls.length <= MAX_POLLS
      previous = nil
      polls.each do |poll|
        raise InvalidState unless poll.is_a?(Hash) && poll.keys.sort == POLL_KEYS.sort
        at = parse_canonical_time!(poll.fetch("at"))
        raise InvalidState if previous && at <= previous
        previous = at
        %w[top_count rising_count].each do |name|
          count = poll.fetch(name)
          raise InvalidState unless count.is_a?(Integer) && count.between?(0, MAX_RANKS)
        end
        validate_ranks!(poll.fetch("top_ranks"), poll.fetch("top_count"))
        validate_ranks!(poll.fetch("rising_ranks"), poll.fetch("rising_count"))
      end
    end

    def validate_ranks!(ranks, count)
      raise InvalidState unless ranks.is_a?(Hash) && ranks.length <= count
      seen = {}
      ranks.each_pair do |id, rank|
        validate_id!(id)
        raise InvalidState unless rank.is_a?(Integer) && rank.between?(1, count)
        raise InvalidState if seen.key?(rank)

        seen[rank] = true
      end
    end

    def validate_id!(id)
      raise InvalidState unless id.is_a?(String) && id.valid_encoding? && ID_PATTERN.match?(id)
    end

    def normalize_now(value)
      raise InvalidState unless value.is_a?(Time)

      value.getutc
    end

    def normalize_pages(pages)
      raise InvalidState unless pages.is_a?(Hash)
      canonical = {}
      pages.each_pair do |key, value|
        name = key.to_s
        raise InvalidState unless %w[new rising top].include?(name) && !canonical.key?(name)
        entries = value.respond_to?(:entries) ? value.entries : nil
        raw_count = value.respond_to?(:raw_entry_count) ? value.raw_entry_count : nil
        raise InvalidState unless entries.is_a?(Array) && entries.length <= MAX_RANKS
        raise InvalidState unless raw_count.is_a?(Integer) && raw_count.between?(0, MAX_RANKS) && raw_count >= entries.length
        canonical[name] = { entries: entries, raw_entry_count: raw_count }
      end
      raise InvalidState unless canonical.keys.sort == %w[new rising top].sort
      canonical
    end

    def collect_entries(pages, now)
      entries = {}
      seen_records = {}
      rank_maps = { "top" => {}, "rising" => {} }
      future_ids = {}
      %w[new rising top].each do |feed_name|
        page = pages.fetch(feed_name)
        page.fetch(:entries).each do |entry|
          record = normalize_entry(entry, page.fetch(:raw_entry_count))
          existing = seen_records[record.fetch("id")]
          if existing
            if existing.fetch("subreddit") != record.fetch("subreddit") ||
               existing.fetch("published_at") != record.fetch("published_at")
              raise InvalidState
            end
          else
            seen_records[record.fetch("id")] = record
          end
          if record.fetch("published_at_time") > now + FUTURE_SKEW_SECONDS
            future_ids[record.fetch("id")] = true
            next
          end
          entries[record.fetch("id")] ||= record
          if %w[top rising].include?(feed_name)
            rank_maps.fetch(feed_name)[record.fetch("id")] ||= record.fetch("rank")
          end
        end
      end
      rank_maps.each_value { |map| map.replace(map.sort.to_h) }
      [entries, rank_maps, future_ids]
    end

    def normalize_entry(entry, raw_count)
      unless entry.respond_to?(:id) && entry.respond_to?(:subreddit) && entry.respond_to?(:title) &&
             entry.respond_to?(:published_at) && entry.respond_to?(:rank)
        raise InvalidState
      end
      id = entry.id
      subreddit = entry.subreddit
      title = entry.title
      published_at = entry.published_at
      rank = entry.rank
      validate_id!(id)
      unless subreddit.is_a?(String) && subreddit.valid_encoding? && SUBREDDIT_PATTERN.match?(subreddit) &&
             subreddit == subreddit.downcase
        raise InvalidState
      end
      unless title.is_a?(String) && title.valid_encoding? && !title.empty? && title.strip != "" &&
             title.bytesize <= MAX_SCALAR_BYTES && printable?(title)
        raise InvalidState
      end
      unless published_at.is_a?(Time) && rank.is_a?(Integer) && rank.between?(1, raw_count)
        raise InvalidState
      end
      {
        "id" => id,
        "subreddit" => subreddit,
        "title" => title,
        "published_at" => time_string(published_at),
        "published_at_time" => published_at.getutc,
        "rank" => rank
      }
    end

    def stored_observation_in_future?(now)
      return false unless @prior_state
      times = [@prior_state.fetch("started_at")]
      times << @prior_state.fetch("last_truncated_at") unless @prior_state.fetch("last_truncated_at").nil?
      @prior_state.fetch("polls").each { |poll| times << poll.fetch("at") }
      @prior_state.fetch("candidates").each_value do |candidate|
        times << candidate.fetch("first_seen_at") << candidate.fetch("last_seen_at")
      end
      times.any? { |value| parse_time(value) > now + FUTURE_SKEW_SECONDS }
    end

    def clamp_observation_times(candidates, now)
      cutoff = time_string(now)
      candidates.each_value do |candidate|
        candidate["first_seen_at"] = [candidate.fetch("first_seen_at"), cutoff].min
        candidate["last_seen_at"] = [candidate.fetch("last_seen_at"), cutoff].min
        candidate["last_seen_at"] = candidate.fetch("first_seen_at") if candidate.fetch("last_seen_at") < candidate.fetch("first_seen_at")
      end
      candidates
    end

    def clamp_time_string(value, now)
      return nil if value.nil?
      [value, time_string(now)].min
    end

    def canonical_output_state(state)
      canonical = canonicalize(state)
      deep_freeze(canonical)
    end

    def ensure_serialized_size!(state)
      serialized = JSON.generate(state)
      raise StateTooLarge if serialized.bytesize > MAX_SERIALIZED_BYTES
      true
    rescue JSON::GeneratorError, EncodingError
      raise InvalidState
    end

    def parse_canonical_time!(value)
      raise InvalidState unless value.is_a?(String) && value.bytesize <= 64
      parsed = Time.iso8601(value).getutc
      raise InvalidState unless parsed.iso8601(6) == value

      parsed
    rescue ArgumentError, TypeError
      raise InvalidState
    end

    def parse_time(value)
      parse_canonical_time!(value)
    end

    def time_string(value)
      value.getutc.iso8601(6)
    end

    def printable?(value)
      value.each_codepoint.all? { |codepoint| codepoint >= 0x20 && codepoint != 0x7F }
    rescue ArgumentError, EncodingError
      false
    end

    def deep_dup(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, child), copy| copy[key.dup] = deep_dup(child) }
      when Array
        value.map { |child| deep_dup(child) }
      when String
        value.dup
      else
        value
      end
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each { |key, child| deep_freeze(key); deep_freeze(child) }
      when Array
        value.each { |child| deep_freeze(child) }
      end
      value.freeze
    end

    def raise_invalid_state
      raise RedditRssError.new(operation: :state, category: :invalid_state), cause: nil
    end
  end
end
