module Cybort
  # Pure, fixed-point scoring for the observed public Reddit RSS universe.
  # State, pages, and their entries are read-only inputs; all result hashes are
  # freshly allocated so diagnostics cannot accidentally expose source state.
  module RedditRssActivity
    SCALE = 1_000_000
    SCORING_VERSION = "rss-rank-v1"
    ELIGIBILITY_WINDOW_SECONDS = 86_400
    FUTURE_SKEW_SECONDS = 300
    RAW_RANK_ABSENT = 101
    DEFAULT_WEIGHTS = {
      "top" => 550,
      "rising" => 300,
      "momentum" => 100,
      "persistence" => 50
    }.freeze
    CONFIDENCE_KEYS = %i[
      observed_only warmup low_sample_confidence new_feed_saturated
      window_partial history_gap state_truncated selection_capped
      future_entries_excluded
    ].freeze

    module_function

    def prominence(count:, rank:)
      validate_integer!(count, :count)
      raise ArgumentError, "count must be nonnegative" if count.negative?
      return 0 if rank.nil?

      validate_integer!(rank, :rank)
      raise ArgumentError, "rank must be within count" unless count.positive? && rank.between?(1, count)
      return SCALE if count == 1

      SCALE * (count - rank) / [count - 1, 1].max
    end

    def components(top:, rising:, previous:, known:, appearances:, poll_count:)
      [top, rising, previous, appearances, poll_count].each_with_index do |value, index|
        validate_integer!(value, %i[top rising previous appearances poll_count][index])
      end
      raise ArgumentError, "poll_count must be nonnegative" if poll_count.negative?
      raise ArgumentError, "appearances must be nonnegative" if appearances.negative?
      raise ArgumentError, "appearances cannot exceed poll_count" if appearances > poll_count
      raise ArgumentError, "known must be boolean" unless known == true || known == false

      {
        "top" => top,
        "rising" => rising,
        "momentum" => known ? [[([top, rising].max - previous) * 4, 0].max, SCALE].min : 0,
        "persistence" => poll_count.zero? ? 0 : SCALE * appearances / poll_count
      }
    end

    def weighted_score(components:, weights:, cold:)
      unless components.is_a?(Hash) && weights.is_a?(Hash) && (cold == true || cold == false)
        raise ArgumentError, "invalid scoring arguments"
      end

      active = cold ? weights.slice("top", "rising") : weights
      denominator = active.values.sum
      raise ArgumentError, "weights must have a positive sum" unless denominator.positive?

      active.sum { |name, weight| weight * components.fetch(name) } / denominator
    end

    def select(transition:, pages:, weights:, now:, limit:)
      current_time = normalize_time!(now)
      limit = positive_integer!(limit, :limit)
      normalized_weights = normalize_weights(weights)
      state = fetch_value(transition, :state)
      candidates = fetch_value(state, "candidates")
      polls = fetch_value(state, "polls")
      normalized_pages = normalize_pages(pages)

      observed = eligible_candidates(candidates, current_time)
      rank_maps = current_rank_maps(normalized_pages, observed)
      signalled_ids = (rank_maps.fetch("top").keys | rank_maps.fetch("rising").keys).sort
      previous_poll = fetch_value(transition, :previous_poll)
      previous_candidate_ids = Array(fetch_value(transition, :previous_candidate_ids))
      history_enabled = !previous_poll.nil?
      current_counts = {
        "top" => normalized_pages.fetch("top").fetch(:raw_entry_count),
        "rising" => normalized_pages.fetch("rising").fetch(:raw_entry_count)
      }
      previous_counts = previous_poll ? {
        "top" => fetch_value(previous_poll, "top_count"),
        "rising" => fetch_value(previous_poll, "rising_count")
      } : {"top" => 0, "rising" => 0}
      flags = confidence_flags(
        transition: transition,
        pages: normalized_pages,
        observed_count: observed.length,
        signalled_count: signalled_ids.length,
        limit: limit,
        now: current_time
      )

      scored = signalled_ids.map do |id|
        candidate = observed.fetch(id)
        top_rank = rank_maps.fetch("top").fetch(id, nil)
        rising_rank = rank_maps.fetch("rising").fetch(id, nil)
        top_prominence = prominence(count: current_counts.fetch("top"), rank: top_rank)
        rising_prominence = prominence(count: current_counts.fetch("rising"), rank: rising_rank)
        previous_top_rank = previous_poll && fetch_value(previous_poll, "top_ranks").fetch(id, nil)
        previous_rising_rank = previous_poll && fetch_value(previous_poll, "rising_ranks").fetch(id, nil)
        previous_top = prominence(count: previous_counts.fetch("top"), rank: previous_top_rank)
        previous_rising = prominence(count: previous_counts.fetch("rising"), rank: previous_rising_rank)
        previous_prominence = [previous_top, previous_rising].max
        known = history_enabled && previous_candidate_ids.include?(id)
        appearances = persistence_appearances(polls, id)
        internal_components = components(
          top: top_prominence,
          rising: rising_prominence,
          previous: previous_prominence,
          known: known,
          appearances: appearances,
          poll_count: polls.length
        )
        score = weighted_score(components: internal_components, weights: normalized_weights, cold: !history_enabled)
        {
          id: id,
          candidate: candidate,
          top_rank: top_rank,
          rising_rank: rising_rank,
          previous_top_rank: previous_top_rank,
          previous_rising_rank: previous_rising_rank,
          top_prominence: top_prominence,
          rising_prominence: rising_prominence,
          momentum: history_enabled ? internal_components.fetch("momentum") : 0,
          persistence: history_enabled ? internal_components.fetch("persistence") : 0,
          score: score
        }
      end

      scored.sort_by! do |row|
        candidate = row.fetch(:candidate)
        [
          -row.fetch(:score),
          row.fetch(:top_rank) || RAW_RANK_ABSENT,
          row.fetch(:rising_rank) || RAW_RANK_ABSENT,
          -fetch_time(candidate, "published_at").to_r,
          row.fetch(:id)
        ]
      end

      quota = observed.empty? || signalled_ids.empty? ? 0 : [(observed.length + 9) / 10, limit, scored.length].min
      selected = scored.first(quota)
      selected_rows = selected.each_with_index.map do |row, index|
        selection_rank = index + 1
        candidate = row.fetch(:candidate)
        info = build_info(
          row: row,
          candidate: candidate,
          selection_rank: selection_rank,
          observed_count: observed.length,
          signalled_count: signalled_ids.length,
          current_counts: current_counts,
          previous_poll: previous_poll,
          now: current_time,
          confidence: flags,
          history_enabled: history_enabled
        )
        {
          id: row.fetch(:id),
          subreddit: candidate.fetch("subreddit"),
          title: candidate.fetch("title"),
          published_at: fetch_time(candidate, "published_at"),
          priority: priority(selection_rank, selected.length),
          info: info
        }
      end

      metadata = {
        source: "reddit_rss",
        scoring_version: SCORING_VERSION,
        new_count: normalized_pages.fetch("new").fetch(:raw_entry_count),
        top_count: current_counts.fetch("top"),
        rising_count: current_counts.fetch("rising"),
        observed_candidate_count: observed.length,
        signalled_candidate_count: signalled_ids.length,
        selected_count: selected_rows.length,
        history_count: polls.length,
        future_exclusion_count: fetch_value(transition, :future_exclusion_count),
        confidence: flags.dup
      }
      {selected: selected_rows, metadata: metadata}
    end

    def normalize_weights(weights)
      unless weights.is_a?(Hash)
        raise ArgumentError, "weights must be a hash"
      end

      normalized = {}
      weights.each_pair do |name, weight|
        name = name.to_s
        raise ArgumentError, "unknown weight" unless DEFAULT_WEIGHTS.key?(name)
        raise ArgumentError, "duplicate weight" if normalized.key?(name)
        validate_integer!(weight, name.to_sym)
        raise ArgumentError, "weight is outside range" unless weight.between?(0, 1_000)

        normalized[name] = weight
      end
      raise ArgumentError, "weights are incomplete" unless normalized.keys.sort == DEFAULT_WEIGHTS.keys.sort
      raise ArgumentError, "weights must sum to 1000" unless normalized.values.sum == 1_000
      raise ArgumentError, "top and rising weights must be positive" if normalized.fetch("top") + normalized.fetch("rising") <= 0

      DEFAULT_WEIGHTS.keys.to_h { |name| [name, normalized.fetch(name)] }
    end

    def normalize_pages(pages)
      unless pages.is_a?(Hash)
        raise ArgumentError, "pages must be a hash"
      end

      normalized = {}
      pages.each_pair do |name, page|
        name = name.to_s
        raise ArgumentError, "invalid page" unless %w[new rising top].include?(name)
        raise ArgumentError, "duplicate page" if normalized.key?(name)
        entries = page.respond_to?(:entries) ? page.entries : nil
        raw_count = page.respond_to?(:raw_entry_count) ? page.raw_entry_count : nil
        unless entries.is_a?(Array) && raw_count.is_a?(Integer) && raw_count.between?(0, 100) && entries.length <= raw_count
          raise ArgumentError, "invalid page"
        end

        normalized[name] = {entries: entries, raw_entry_count: raw_count}
      end
      raise ArgumentError, "pages are incomplete" unless normalized.keys.sort == %w[new rising top].sort
      normalized
    end

    def eligible_candidates(candidates, now)
      unless candidates.is_a?(Hash)
        raise ArgumentError, "candidates must be a hash"
      end

      lower = now - ELIGIBILITY_WINDOW_SECONDS
      upper = now + FUTURE_SKEW_SECONDS
      candidates.each_with_object({}) do |(id, candidate), result|
        published_at = fetch_time(candidate, "published_at")
        result[id] = candidate if published_at >= lower && published_at <= upper
      end
    end

    def current_rank_maps(pages, observed)
      %w[top rising].to_h do |name|
        entries = pages.fetch(name).fetch(:entries)
        ranks = {}
        entries.each do |entry|
          id = fetch_entry(entry, :id)
          next unless observed.key?(id)

          rank = fetch_entry(entry, :rank)
          ranks[id] ||= rank
        end
        [name, ranks]
      end
    end

    def persistence_appearances(polls, id)
      polls.count do |poll|
        fetch_value(poll, "top_ranks").key?(id) || fetch_value(poll, "rising_ranks").key?(id)
      end
    end

    def confidence_flags(transition:, pages:, observed_count:, signalled_count:, limit:, now:)
      polls = fetch_value(fetch_value(transition, :state), "polls")
      new_entries = pages.fetch("new").fetch(:entries)
      boundary = now - ELIGIBILITY_WINDOW_SECONDS
      oldest_new = new_entries.map { |entry| fetch_entry(entry, :published_at) }.min
      selection_quota = observed_count.zero? || signalled_count.zero? ? 0 :
        [(observed_count + 9) / 10, signalled_count].min
      source_flags = fetch_value(transition, :flags)
      {
        observed_only: true,
        warmup: polls.length < 2,
        low_sample_confidence: observed_count < 10,
        new_feed_saturated: pages.fetch("new").fetch(:raw_entry_count) == 100,
        window_partial: oldest_new.nil? || oldest_new > boundary,
        history_gap: !!fetch_value(source_flags, "history_gap"),
        state_truncated: !!fetch_value(source_flags, "state_truncated"),
        selection_capped: limit < selection_quota,
        future_entries_excluded: !!fetch_value(source_flags, "future_entries_excluded")
      }
    end

    def build_info(row:, candidate:, selection_rank:, observed_count:, signalled_count:, current_counts:,
                   previous_poll:, now:, confidence:, history_enabled:)
      top_rank = row.fetch(:top_rank)
      rising_rank = row.fetch(:rising_rank)
      previous_top_rank = row.fetch(:previous_top_rank)
      previous_rising_rank = row.fetch(:previous_rising_rank)
      {
        kind: "submission",
        subreddit: candidate.fetch("subreddit"),
        scoring_version: SCORING_VERSION,
        selection_rank: selection_rank,
        activity_score_millionths: row.fetch(:score),
        top_prominence_millionths: row.fetch(:top_prominence),
        rising_prominence_millionths: row.fetch(:rising_prominence),
        momentum_millionths: history_enabled ? row.fetch(:momentum) : 0,
        persistence_millionths: history_enabled ? row.fetch(:persistence) : 0,
        top_rank: top_rank,
        rising_rank: rising_rank,
        top_count: current_counts.fetch("top"),
        rising_count: current_counts.fetch("rising"),
        previous_top_rank: previous_top_rank,
        previous_rising_rank: previous_rising_rank,
        top_rank_change: rank_change(previous_top_rank, top_rank),
        rising_rank_change: rank_change(previous_rising_rank, rising_rank),
        age_seconds: [(now.to_r - fetch_time(candidate, "published_at").to_r), 0].max.floor,
        observed_candidate_count: observed_count,
        signalled_candidate_count: signalled_count,
        observed_percentile_millionths: ordinal_percentile(observed_count, selection_rank),
        confidence: confidence.dup
      }
    end

    def rank_change(previous, current)
      return nil if previous.nil? || current.nil?

      previous - current
    end

    def ordinal_percentile(observed_count, rank)
      return SCALE if observed_count == 1

      SCALE * (observed_count - rank) / [observed_count - 1, 1].max
    end

    def priority(rank, total)
      return 100 if total <= 1

      100 * (total - rank) / (total - 1)
    end

    def fetch_entry(entry, name)
      return entry.public_send(name) if entry.respond_to?(name)
      return entry.fetch(name) if entry.is_a?(Hash) && entry.key?(name)
      return entry.fetch(name.to_s) if entry.is_a?(Hash) && entry.key?(name.to_s)

      raise ArgumentError, "entry is missing #{name}"
    end

    def fetch_value(value, name)
      return value.public_send(name) if value.respond_to?(name)
      return value.fetch(name) if value.is_a?(Hash) && value.key?(name)
      return value.fetch(name.to_s) if value.is_a?(Hash) && value.key?(name.to_s)
      return value.fetch(name.to_sym) if value.is_a?(Hash) && value.key?(name.to_sym)

      raise ArgumentError, "value is missing #{name}"
    end

    def fetch_time(candidate, name)
      value = fetch_value(candidate, name)
      return value.getutc if value.is_a?(Time)
      return Time.iso8601(value).getutc if value.is_a?(String)

      raise ArgumentError, "#{name} must be a time"
    rescue ArgumentError
      raise ArgumentError, "#{name} must be a valid time"
    end

    def normalize_time!(value)
      raise ArgumentError, "now must be a Time" unless value.is_a?(Time)

      value.getutc
    end

    def positive_integer!(value, name)
      validate_integer!(value, name)
      raise ArgumentError, "#{name} must be positive" unless value.positive?

      value
    end

    def validate_integer!(value, name)
      raise ArgumentError, "#{name} must be an integer" unless value.is_a?(Integer)

      value
    end
  end
end
