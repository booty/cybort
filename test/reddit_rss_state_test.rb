require "test_helper"

class RedditRssStateTest < Minitest::Test
  WEIGHTS = {
    "top" => 550,
    "rising" => 300,
    "momentum" => 100,
    "persistence" => 50
  }.freeze

  def setup
    @subreddits = ["rails", "ruby"]
  end

  def entry(id:, subreddit: "ruby", title: "Post", published_at:, rank: 1)
    Cybort::RedditRssClient::Entry.new(
      id: id, subreddit: subreddit, title: title, published_at: published_at, rank: rank
    )
  end

  def page(entries, raw_entry_count: entries.length)
    Cybort::RedditRssClient::Page.new(entries: entries, raw_entry_count: raw_entry_count)
  end

  def pages(new_entries: [], rising_entries: [], top_entries: [], new_count: nil, rising_count: nil, top_count: nil)
    {
      "new" => page(new_entries, raw_entry_count: new_count || new_entries.length),
      "rising" => page(rising_entries, raw_entry_count: rising_count || rising_entries.length),
      "top" => page(top_entries, raw_entry_count: top_count || top_entries.length)
    }
  end

  def state(raw: nil, subreddits: @subreddits, weights: WEIGHTS)
    Cybort::RedditRssState.new(raw: raw, subreddits: subreddits, weights: weights)
  end

  def test_state_keeps_non_selected_discovery_candidates_and_first_poll
    now = Time.utc(2026, 9, 6, 12)
    result = state.advance(
      pages: pages(new_entries: [entry(id: "t3_abc", title: "Fresh", published_at: now - 60)]),
      now: now
    )

    assert_equal ["t3_abc"], result.state.fetch("candidates").keys
    assert_equal 1, result.state.fetch("polls").length
    assert_nil result.previous_poll
    assert_equal [], result.previous_candidate_ids
    assert result.state.frozen?
  end

  def test_merge_precedence_and_conflicting_identity_are_deterministic
    now = Time.utc(2026, 9, 6, 12)
    same = entry(id: "t3_abc", title: "new title", published_at: now - 60, rank: 1)
    rising = entry(id: "t3_abc", title: "rising title", published_at: now - 60, rank: 1)
    top = entry(id: "t3_abc", title: "top title", published_at: now - 60, rank: 1)
    result = state.advance(pages: pages(new_entries: [same], rising_entries: [rising], top_entries: [top]), now: now)
    assert_equal "new title", result.state.fetch("candidates").fetch("t3_abc").fetch("title")

    conflict = entry(id: "t3_abc", title: "different date", published_at: now - 59)
    assert_raises(Cybort::RedditRssError) do
      state.advance(pages: pages(new_entries: [same], rising_entries: [conflict]), now: now)
    end
  end

  def test_preferred_title_refreshes_existing_candidate_without_changing_first_seen
    first_now = Time.utc(2026, 9, 6, 12)
    first = state.advance(pages: pages(new_entries: [entry(id: "t3_abc", title: "old", published_at: first_now - 10)]), now: first_now)
    second_now = first_now + 60
    second = Cybort::RedditRssState.new(raw: first.state, subreddits: @subreddits, weights: WEIGHTS).advance(
      pages: pages(top_entries: [entry(id: "t3_abc", title: "new", published_at: first_now - 10)]), now: second_now
    )
    candidate = second.state.fetch("candidates").fetch("t3_abc")
    assert_equal "new", candidate.fetch("title")
    assert_equal first_now.iso8601(6), candidate.fetch("first_seen_at")
    assert_equal second_now.iso8601(6), candidate.fetch("last_seen_at")
  end

  def test_four_snapshot_rolling_cap_and_previous_signals
    now = Time.utc(2026, 9, 6, 12)
    result = nil
    current_state = state
    5.times do |index|
      at = now + index
      result = current_state.advance(
        pages: pages(top_entries: [entry(id: "t3_abc", published_at: now - 60, rank: 1)]), now: at
      )
      current_state = Cybort::RedditRssState.new(raw: result.state, subreddits: @subreddits, weights: WEIGHTS)
    end
    assert_equal 4, result.state.fetch("polls").length
    assert_equal 4, result.state.fetch("polls").map { |poll| poll.fetch("at") }.uniq.length
    assert_equal ["t3_abc"], result.previous_candidate_ids
    assert_equal 1, result.previous_poll.fetch("top_ranks").fetch("t3_abc")
  end

  def test_gap_strictly_greater_than_one_hour_resets_history_but_not_candidates
    first_now = Time.utc(2026, 9, 6, 12)
    first = state.advance(pages: pages(top_entries: [entry(id: "t3_abc", published_at: first_now - 60)]), now: first_now)
    exact = Cybort::RedditRssState.new(raw: first.state, subreddits: @subreddits, weights: WEIGHTS).advance(
      pages: pages, now: first_now + 3600
    )
    assert_equal 2, exact.state.fetch("polls").length
    gap = Cybort::RedditRssState.new(raw: exact.state, subreddits: @subreddits, weights: WEIGHTS).advance(
      pages: pages, now: first_now + 7201
    )
    assert_equal 1, gap.state.fetch("polls").length
    assert_equal true, gap.flags.fetch("history_gap")
    assert_equal ["t3_abc"], gap.state.fetch("candidates").keys
    assert_nil gap.previous_poll
  end

  def test_non_increasing_clock_resets_and_clamps_observation_times
    now = Time.utc(2026, 9, 6, 12)
    first = state.advance(pages: pages(top_entries: [entry(id: "t3_abc", published_at: now - 60)]), now: now)
    rollback = Cybort::RedditRssState.new(raw: first.state, subreddits: @subreddits, weights: WEIGHTS).advance(
      pages: pages, now: now - 120
    )
    assert_equal 1, rollback.state.fetch("polls").length
    candidate = rollback.state.fetch("candidates").fetch("t3_abc")
    assert_operator Time.iso8601(candidate.fetch("first_seen_at")), :<=, now - 120
    assert_operator Time.iso8601(candidate.fetch("last_seen_at")), :<=, now - 120
    assert rollback.flags.fetch("history_gap")
  end

  def test_future_skew_is_excluded_and_old_boundary_is_inclusive
    now = Time.utc(2026, 9, 6, 12)
    future = entry(id: "t3_fut", published_at: now + 301)
    boundary = entry(id: "t3_old", published_at: now - 172_800)
    result = state.advance(pages: pages(new_entries: [future, boundary], new_count: 2), now: now)
    assert_equal 1, result.future_exclusion_count
    assert result.flags.fetch("future_entries_excluded")
    assert_empty result.state.fetch("candidates")
    assert_equal 0, result.state.fetch("polls").first.fetch("top_count")
  end

  def test_future_skew_boundary_is_accepted
    now = Time.utc(2026, 9, 6, 12)
    result = state.advance(pages: pages(new_entries: [entry(id: "t3_fut", published_at: now + 300)]), now: now)
    assert_equal 0, result.future_exclusion_count
    assert_equal ["t3_fut"], result.state.fetch("candidates").keys
  end

  def test_two_thousand_one_candidates_evicts_oldest_deterministically
    now = Time.utc(2026, 9, 6, 12)
    candidates = 2_000.times.to_h do |index|
      id = "t3_#{(index + 1).to_s(36)}"
      [id, {
        "subreddit" => "ruby", "title" => "Post", "published_at" => (now - index - 1).iso8601(6),
        "first_seen_at" => now.iso8601(6), "last_seen_at" => now.iso8601(6)
      }]
    end
    raw = {
      "version" => 1, "scoring_version" => Cybort::RedditRssState::SCORING_VERSION,
      "fingerprint" => Digest::SHA256.hexdigest(JSON.generate([@subreddits, WEIGHTS.values])),
      "started_at" => now.iso8601(6), "last_truncated_at" => nil,
      "candidates" => candidates, "polls" => []
    }
    result = state(raw: raw).advance(
      pages: pages(new_entries: [entry(id: "t3_new", published_at: now)]), now: now
    )
    assert_equal 2_000, result.state.fetch("candidates").length
    refute result.state.fetch("candidates").key?("t3_1jk")
    assert_equal now.iso8601(6), result.state.fetch("last_truncated_at")
  end

  def test_fingerprint_change_resets_candidates_and_history_after_validating_old_state
    now = Time.utc(2026, 9, 6, 12)
    first = state.advance(pages: pages(new_entries: [entry(id: "t3_abc", published_at: now - 60)]), now: now)
    changed = Cybort::RedditRssState.new(raw: first.state, subreddits: ["news"], weights: WEIGHTS).advance(
      pages: pages, now: now + 1
    )
    assert_empty changed.state.fetch("candidates")
    assert_equal 1, changed.state.fetch("polls").length
    assert changed.flags.fetch("history_gap")
  end

  def test_symbolized_state_round_trips_and_mixed_duplicate_keys_fail
    now = Time.utc(2026, 9, 6, 12)
    first = state.advance(pages: pages(new_entries: [entry(id: "t3_abc", published_at: now - 60)]), now: now)
    symbolized = JSON.parse(JSON.generate(first.state), symbolize_names: true)
    result = Cybort::RedditRssState.new(raw: symbolized, subreddits: @subreddits, weights: WEIGHTS).advance(
      pages: pages, now: now + 1
    )
    assert_equal 2, result.state.fetch("polls").length

    duplicate = first.state.dup
    duplicate[:version] = duplicate.fetch("version")
    assert_raises(Cybort::RedditRssError) do
      Cybort::RedditRssState.new(raw: duplicate, subreddits: @subreddits, weights: WEIGHTS)
    end
  end

  def test_invalid_state_is_safe_and_does_not_copy_unknown_version
    assert_raises(Cybort::RedditRssError) do
      Cybort::RedditRssState.new(raw: { "version" => 99 }, subreddits: @subreddits, weights: WEIGHTS)
    end
    error = assert_raises(Cybort::RedditRssError) do
      Cybort::RedditRssState.new(raw: { "version" => 1, "scoring_version" => "x" }, subreddits: @subreddits, weights: WEIGHTS)
    end
    assert_equal :invalid_state, error.safe_metadata.fetch(:category)
    refute_includes error.message, "x"
  end

  def test_state_and_input_are_immutable_after_advance
    now = Time.utc(2026, 9, 6, 12)
    title = String.new("Post")
    input_entry = entry(id: "t3_abc", title: title, published_at: now - 60)
    input_pages = pages(new_entries: [input_entry])
    result = state.advance(pages: input_pages, now: now)
    result.state.fetch("candidates").fetch("t3_abc").fetch("title")
    assert_raises(FrozenError) { result.state.fetch("candidates")["t3_abc"]["title"] << "!" }
    refute input_pages.fetch("new").frozen?
    refute title.frozen?
    refute input_entry.frozen?
    assert_equal "Post", input_pages.fetch("new").entries.first.title

    raw = JSON.parse(JSON.generate(result.state))
    candidate_key = String.new("t3_abc")
    candidate_value = raw.fetch("candidates").delete("t3_abc")
    raw.fetch("candidates")[candidate_key] = candidate_value
    Cybort::RedditRssState.new(raw: raw, subreddits: @subreddits, weights: WEIGHTS)
    refute raw.fetch("candidates").fetch("t3_abc").fetch("title").frozen?
    refute candidate_key.frozen?
  end

  def test_state_rejects_noncanonical_or_oversized_serialized_state
    now = Time.utc(2026, 9, 6, 12)
    first = state.advance(pages: pages(new_entries: [entry(id: "t3_abc", published_at: now - 60)]), now: now)
    bad = JSON.parse(JSON.generate(first.state))
    bad["candidates"]["t3_abc"]["published_at"] = "2026-09-06T12:00:00Z"
    assert_raises(Cybort::RedditRssError) do
      Cybort::RedditRssState.new(raw: bad, subreddits: @subreddits, weights: WEIGHTS)
    end

    huge = first.state.merge("candidates" => { "t3_abc" => first.state.fetch("candidates").fetch("t3_abc").merge("title" => "x" * 2_049) })
    assert_raises(Cybort::RedditRssError) do
      Cybort::RedditRssState.new(raw: huge, subreddits: @subreddits, weights: WEIGHTS)
    end
  end

  def test_state_rejects_oversized_poll_and_rank_collections
    now = Time.utc(2026, 9, 6, 12)
    first = state.advance(pages: pages, now: now)
    too_many_polls = JSON.parse(JSON.generate(first.state))
    too_many_polls["polls"] = 5.times.map do |index|
      {
        "at" => (now + index + 1).iso8601(6), "top_count" => 0, "rising_count" => 0,
        "top_ranks" => {}, "rising_ranks" => {}
      }
    end
    assert_raises(Cybort::RedditRssError) do
      state(raw: too_many_polls)
    end

    too_many_ranks = JSON.parse(JSON.generate(first.state))
    too_many_ranks["polls"] = [{
      "at" => (now + 1).iso8601(6), "top_count" => 100, "rising_count" => 0,
      "top_ranks" => 101.times.to_h { |index| ["t3_#{(index + 1).to_s(36)}", index + 1] },
      "rising_ranks" => {}
    }]
    assert_raises(Cybort::RedditRssError) do
      state(raw: too_many_ranks)
    end
  end

  def test_invalid_rank_and_timestamp_state_is_rejected_at_the_boundary
    now = Time.utc(2026, 9, 6, 12)
    first = state.advance(pages: pages, now: now)
    raw = JSON.parse(JSON.generate(first.state))
    raw.fetch("polls").first.fetch("top_ranks")["t3_abc"] = 101
    assert_raises(Cybort::RedditRssError) { state(raw: raw) }

    raw = JSON.parse(JSON.generate(first.state))
    raw["started_at"] = "2026-09-06T12:00:00Z"
    assert_raises(Cybort::RedditRssError) { state(raw: raw) }
  end

  def test_persisted_candidate_beyond_future_skew_is_filtered_on_transition
    now = Time.utc(2026, 9, 6, 12)
    first = state.advance(
      pages: pages(new_entries: [entry(id: "t3_abc", published_at: now - 60)]), now: now
    )
    raw = JSON.parse(JSON.generate(first.state))
    raw.fetch("candidates").fetch("t3_abc")["published_at"] = (now + 301).iso8601(6)
    result = state(raw: raw).advance(pages: pages, now: now)
    refute result.state.fetch("candidates").key?("t3_abc")
  end
end
