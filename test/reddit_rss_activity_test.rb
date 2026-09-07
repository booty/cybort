require "test_helper"

class RedditRssActivityTest < Minitest::Test
  SCALE = 1_000_000
  WEIGHTS = {
    "top" => 550,
    "rising" => 300,
    "momentum" => 100,
    "persistence" => 50
  }.freeze

  def test_prominence_uses_raw_denominator_and_handles_singletons
    assert_equal SCALE, Cybort::RedditRssActivity.prominence(count: 1, rank: 1)
    assert_equal 0, Cybort::RedditRssActivity.prominence(count: 3, rank: nil)
    assert_equal 500_000, Cybort::RedditRssActivity.prominence(count: 3, rank: 2)
    assert_equal 0, Cybort::RedditRssActivity.prominence(count: 3, rank: 3)
  end

  def test_components_and_weighted_score_keep_all_math_in_millionths
    components = Cybort::RedditRssActivity.components(
      top: 1_000_000, rising: 500_000, previous: 500_000,
      known: true, appearances: 2, poll_count: 4
    )

    assert_equal({
      "top" => 1_000_000,
      "rising" => 500_000,
      "momentum" => 1_000_000,
      "persistence" => 500_000
    }, components)
    assert_equal 825_000, Cybort::RedditRssActivity.weighted_score(
      components: components, weights: WEIGHTS, cold: false
    )
    assert_equal 823_529, Cybort::RedditRssActivity.weighted_score(
      components: components, weights: WEIGHTS, cold: true
    )
  end

  def test_new_candidates_have_no_momentum_but_known_candidates_do
    known = Cybort::RedditRssActivity.components(
      top: 900_000, rising: 0, previous: 100_000,
      known: true, appearances: 1, poll_count: 2
    )
    new_candidate = Cybort::RedditRssActivity.components(
      top: 900_000, rising: 0, previous: 100_000,
      known: false, appearances: 1, poll_count: 2
    )

    assert_equal 1_000_000, known.fetch("momentum")
    assert_equal 0, new_candidate.fetch("momentum")
  end

  def test_persistence_uses_one_presence_per_poll_for_each_history_window
    assert_equal 1_000_000, persistence(1, 1)
    assert_equal 500_000, persistence(1, 2)
    assert_equal 666_666, persistence(2, 3)
    assert_equal 750_000, persistence(3, 4)
  end

  def test_selection_uses_observed_denominator_and_reports_cap_separately
    now = Time.utc(2026, 9, 7, 12)
    ids = (1..20).map { |number| "t3_#{number.to_s(36)}" }
    candidates = ids.to_h do |id|
      [id, candidate_state(id, now)]
    end
    top_entries = ids.first(5).each_with_index.map do |id, index|
      entry(id: id, published_at: now, rank: index + 1)
    end
    pages = pages(new_entries: ids.map { |id| entry(id: id, published_at: now, rank: 1) },
                  top_entries: top_entries, top_count: 5)
    transition = transition(state: state(candidates: candidates, polls: [poll(now, ids.first(5), [], top_count: 5)]),
                            previous_poll: nil, previous_candidate_ids: [])

    result = select(transition: transition, pages: pages, now: now, limit: 100)

    assert_equal 20, result.fetch(:metadata).fetch(:observed_candidate_count)
    assert_equal 5, result.fetch(:metadata).fetch(:signalled_candidate_count)
    assert_equal 2, result.fetch(:selected).length
    refute result.fetch(:metadata).fetch(:confidence).fetch(:selection_capped)

    capped = select(transition: transition, pages: pages, now: now, limit: 1)
    assert_equal 1, capped.fetch(:selected).length
    assert capped.fetch(:metadata).fetch(:confidence).fetch(:selection_capped)
  end

  def test_selection_with_one_signal_is_not_cap_truncated
    now = Time.utc(2026, 9, 7, 12)
    ids = (1..20).map { |number| "t3_#{number.to_s(36)}" }
    candidates = ids.to_h { |id| [id, candidate_state(id, now)] }
    pages = pages(new_entries: ids.map { |id| entry(id: id, published_at: now, rank: 1) },
                  top_entries: [entry(id: ids.first, published_at: now, rank: 1)], top_count: 1)
    transition = transition(state: state(candidates: candidates, polls: [poll(now, [ids.first], [], top_count: 1)]),
                            previous_poll: nil, previous_candidate_ids: [])

    result = select(transition: transition, pages: pages, now: now, limit: 100)

    assert_equal 1, result.fetch(:selected).length
    refute result.fetch(:metadata).fetch(:confidence).fetch(:selection_capped)
  end

  def test_nine_observed_candidates_are_low_sample_but_ten_are_not
    now = Time.utc(2026, 9, 7, 12)
    nine = observed_selection(now, 9)
    ten = observed_selection(now, 10)

    assert_equal 1, nine.fetch(:selected).length
    assert nine.fetch(:metadata).fetch(:confidence).fetch(:low_sample_confidence)
    assert_equal 1, ten.fetch(:selected).length
    refute ten.fetch(:metadata).fetch(:confidence).fetch(:low_sample_confidence)
  end

  def test_old_and_over_skew_future_candidates_are_not_observed_but_boundary_future_is
    now = Time.utc(2026, 9, 7, 12)
    ids = %w[t3_old t3_future t3_boundary t3_current]
    candidates = {
      "t3_old" => candidate_state("t3_old", now - 86_401),
      "t3_future" => candidate_state("t3_future", now + 301),
      "t3_boundary" => candidate_state("t3_boundary", now + 300),
      "t3_current" => candidate_state("t3_current", now)
    }
    pages = pages(
      new_entries: ids.map { |id| entry(id: id, published_at: now, rank: 1) },
      top_entries: ids.each_with_index.map { |id, index| entry(id: id, published_at: candidates.fetch(id).fetch("published_at").then { |value| Time.iso8601(value) }, rank: index + 1) },
      top_count: ids.length
    )
    transition = transition(
      state: state(candidates: candidates, polls: [poll(now, ids, [])]),
      previous_poll: nil, previous_candidate_ids: []
    )

    result = select(transition: transition, pages: pages, now: now, limit: 100)

    assert_equal 2, result.fetch(:metadata).fetch(:observed_candidate_count)
    assert_equal %w[t3_boundary], result.fetch(:selected).map { |row| row.fetch(:id) }
  end

  def test_cold_history_renormalizes_weights_and_hides_history_components
    now = Time.utc(2026, 9, 7, 12)
    id = "t3_abc"
    candidate = candidate_state(id, now)
    pages = pages(new_entries: [entry(id: id, published_at: now, rank: 1)],
                  top_entries: [entry(id: id, published_at: now, rank: 1)], top_count: 3,
                  rising_entries: [entry(id: id, published_at: now, rank: 2)], rising_count: 3)
    transition = transition(
      state: state(candidates: {id => candidate}, polls: [poll(now, [id], [id], top_count: 3, rising_count: 3)]),
      previous_poll: nil, previous_candidate_ids: []
    )

    row = select(transition: transition, pages: pages, now: now, limit: 1).fetch(:selected).fetch(0)

    assert_equal 823_529, row.fetch(:info).fetch(:activity_score_millionths)
    assert_equal 0, row.fetch(:info).fetch(:momentum_millionths)
    assert_equal 0, row.fetch(:info).fetch(:persistence_millionths)
  end

  def test_gap_reset_disables_history_components_and_sets_confidence_flag
    now = Time.utc(2026, 9, 7, 12)
    id = "t3_gap"
    pages = pages(
      new_entries: [entry(id: id, published_at: now, rank: 1)],
      top_entries: [entry(id: id, published_at: now, rank: 1)], top_count: 1
    )
    transition = transition(
      state: state(candidates: {id => candidate_state(id, now)}, polls: [poll(now, [id], [])]),
      previous_poll: nil, previous_candidate_ids: [id],
      flags: {"history_gap" => true}
    )

    result = select(transition: transition, pages: pages, now: now, limit: 1)
    row = result.fetch(:selected).fetch(0)

    assert result.fetch(:metadata).fetch(:confidence).fetch(:history_gap)
    assert row.fetch(:info).fetch(:confidence).fetch(:history_gap)
    assert_equal 0, row.fetch(:info).fetch(:momentum_millionths)
    assert_equal 0, row.fetch(:info).fetch(:persistence_millionths)
  end

  def test_known_candidate_uses_previous_poll_denominators_and_or_persistence
    now = Time.utc(2026, 9, 7, 12)
    id = "t3_abc"
    previous = poll(now - 60, [id], [id], top_count: 3, rising_count: 3)
    previous["top_ranks"] = {id => 2}
    previous["rising_ranks"] = {id => 2}
    polls = [
      poll(now - 180, [], [], top_count: 3, rising_count: 3),
      poll(now - 120, [], [], top_count: 3, rising_count: 3),
      previous,
      poll(now, [id], [id], top_count: 10, rising_count: 3)
    ]
    pages = pages(new_entries: [entry(id: id, published_at: now, rank: 2)],
                  top_entries: [entry(id: id, published_at: now, rank: 2)], top_count: 10,
                  rising_entries: [entry(id: id, published_at: now, rank: 2)], rising_count: 3)
    transition = transition(
      state: state(candidates: {id => candidate_state(id, now)}, polls: polls),
      previous_poll: polls[-2], previous_candidate_ids: [id]
    )

    row = select(transition: transition, pages: pages, now: now, limit: 1).fetch(:selected).fetch(0)
    info = row.fetch(:info)

    assert_equal 888_888, info.fetch(:top_prominence_millionths)
    assert_equal 500_000, info.fetch(:previous_top_rank).then { |rank| Cybort::RedditRssActivity.prominence(count: 3, rank: rank) }
    assert_equal 500_000, info.fetch(:persistence_millionths)
    assert_equal 1_000_000, info.fetch(:momentum_millionths)
  end

  def test_sort_tie_breakers_and_allowlisted_metadata_are_deterministic
    now = Time.utc(2026, 9, 7, 12)
    ids = %w[t3_a t3_b]
    candidates = ids.to_h { |id| [id, candidate_state(id, now)] }
    pages = pages(new_entries: ids.map { |id| entry(id: id, published_at: now, rank: 1) },
                  top_entries: [entry(id: "t3_a", published_at: now, rank: 1), entry(id: "t3_b", published_at: now, rank: 2)],
                  top_count: 2,
                  rising_entries: [entry(id: "t3_b", published_at: now, rank: 1), entry(id: "t3_a", published_at: now, rank: 2)],
                  rising_count: 2)
    transition = transition(state: state(candidates: candidates, polls: [poll(now, ids, ids, top_count: 2, rising_count: 2)]),
                            previous_poll: nil, previous_candidate_ids: [])
    result = select(transition: transition, pages: pages, now: now, limit: 2)
    row = result.fetch(:selected).first

    assert_equal ["t3_a"], result.fetch(:selected).map { |selected| selected.fetch(:id) }
    assert_equal %i[source scoring_version new_count top_count rising_count observed_candidate_count
                    signalled_candidate_count selected_count history_count future_exclusion_count confidence].sort,
                 result.fetch(:metadata).keys.sort
    assert_equal %i[kind subreddit scoring_version selection_rank activity_score_millionths
                    top_prominence_millionths rising_prominence_millionths momentum_millionths
                    persistence_millionths top_rank rising_rank top_count rising_count previous_top_rank
                    previous_rising_rank top_rank_change rising_rank_change age_seconds
                    observed_candidate_count signalled_candidate_count observed_percentile_millionths confidence].sort,
                 row.fetch(:info).keys.sort
    assert_equal "reddit_rss", result.fetch(:metadata).fetch(:source)
    assert_equal 100, row.fetch(:priority)
  end

  def test_equal_scores_use_published_time_then_canonical_id
    now = Time.utc(2026, 9, 7, 12)
    older = now - 60
    candidates = {
      "t3_a" => candidate_state("t3_a", older),
      "t3_b" => candidate_state("t3_b", now)
    }
    pages = pages(
      new_entries: [entry(id: "t3_a", published_at: older, rank: 1), entry(id: "t3_b", published_at: now, rank: 1)],
      top_entries: [entry(id: "t3_a", published_at: older, rank: 1), entry(id: "t3_b", published_at: now, rank: 1)],
      top_count: 2
    )
    transition = transition(state: state(candidates: candidates, polls: [poll(now, %w[t3_a t3_b], [])]),
                            previous_poll: nil, previous_candidate_ids: [])

    newest = select(transition: transition, pages: pages, now: now, limit: 100)
    assert_equal ["t3_b"], newest.fetch(:selected).map { |row| row.fetch(:id) }

    same_time = now
    candidates["t3_a"]["published_at"] = same_time.iso8601(6)
    pages = pages(
      new_entries: [entry(id: "t3_b", published_at: same_time, rank: 1), entry(id: "t3_a", published_at: same_time, rank: 1)],
      top_entries: [entry(id: "t3_b", published_at: same_time, rank: 1), entry(id: "t3_a", published_at: same_time, rank: 1)],
      top_count: 2
    )
    transition = transition(state: state(candidates: candidates, polls: [poll(now, %w[t3_a t3_b], [])]),
                            previous_poll: nil, previous_candidate_ids: [])

    assert_equal ["t3_a"], select(transition: transition, pages: pages, now: now, limit: 100).fetch(:selected).map { |row| row.fetch(:id) }
  end

  def test_custom_weights_change_the_cold_selection_order
    now = Time.utc(2026, 9, 7, 12)
    ids = %w[t3_top t3_rising]
    candidates = ids.to_h { |id| [id, candidate_state(id, now)] }
    pages = pages(
      new_entries: ids.map { |id| entry(id: id, published_at: now, rank: 1) },
      top_entries: [entry(id: "t3_top", published_at: now, rank: 1), entry(id: "t3_rising", published_at: now, rank: 2)],
      rising_entries: [entry(id: "t3_rising", published_at: now, rank: 1), entry(id: "t3_top", published_at: now, rank: 2)],
      top_count: 2, rising_count: 2
    )
    transition = transition(state: state(candidates: candidates, polls: [poll(now, ids, ids, top_count: 2, rising_count: 2)]),
                            previous_poll: nil, previous_candidate_ids: [])

    assert_equal ["t3_top"], select(transition: transition, pages: pages, now: now, limit: 100).fetch(:selected).map { |row| row.fetch(:id) }
    rising_first = {"top" => 100, "rising" => 900, "momentum" => 0, "persistence" => 0}
    assert_equal ["t3_rising"], select(weights: rising_first, transition: transition, pages: pages, now: now, limit: 100).fetch(:selected).map { |row| row.fetch(:id) }
  end

  def test_no_signals_returns_no_rows_without_mutating_inputs
    now = Time.utc(2026, 9, 7, 12)
    id = "t3_abc"
    candidates = {id => candidate_state(id, now)}
    pages = pages(new_entries: [entry(id: id, published_at: now, rank: 1)])
    transition = transition(state: state(candidates: candidates, polls: [poll(now, [], [])]),
                            previous_poll: nil, previous_candidate_ids: [])
    original_state = Marshal.load(Marshal.dump(transition.state))
    original_pages = Marshal.load(Marshal.dump(pages))

    result = select(transition: transition, pages: pages, now: now, limit: 1)

    assert_empty result.fetch(:selected)
    assert_equal original_state, transition.state
    assert_equal original_pages, pages
  end

  private

  def select(weights: WEIGHTS, **options)
    Cybort::RedditRssActivity.select(weights: weights, **options)
  end

  def persistence(appearances, poll_count)
    Cybort::RedditRssActivity.components(
      top: 0, rising: 0, previous: 0, known: false,
      appearances: appearances, poll_count: poll_count
    ).fetch("persistence")
  end

  def observed_selection(now, count)
    ids = (1..count).map { |number| "t3_#{number.to_s(36)}" }
    candidates = ids.to_h { |id| [id, candidate_state(id, now)] }
    pages = pages(
      new_entries: ids.map { |id| entry(id: id, published_at: now, rank: 1) },
      top_entries: ids.map.with_index { |id, index| entry(id: id, published_at: now, rank: index + 1) },
      top_count: count
    )
    transition = transition(state: state(candidates: candidates, polls: [poll(now, ids, [], top_count: count)]),
                            previous_poll: nil, previous_candidate_ids: [])
    select(transition: transition, pages: pages, now: now, limit: 100)
  end

  def entry(id:, published_at:, rank:, subreddit: "ruby", title: "Title")
    Cybort::RedditRssClient::Entry.new(
      id: id, subreddit: subreddit, title: title, published_at: published_at, rank: rank
    )
  end

  def pages(new_entries:, top_entries: [], rising_entries: [], new_count: nil, top_count: nil, rising_count: nil)
    {
      "new" => Cybort::RedditRssClient::Page.new(entries: new_entries, raw_entry_count: new_count || new_entries.length),
      "top" => Cybort::RedditRssClient::Page.new(entries: top_entries, raw_entry_count: top_count || top_entries.length),
      "rising" => Cybort::RedditRssClient::Page.new(entries: rising_entries, raw_entry_count: rising_count || rising_entries.length)
    }
  end

  def candidate_state(id, now)
    {
      "subreddit" => "ruby",
      "title" => "Title",
      "published_at" => now.iso8601(6),
      "first_seen_at" => now.iso8601(6),
      "last_seen_at" => now.iso8601(6)
    }
  end

  def poll(at, top_ids, rising_ids, top_count: top_ids.length, rising_count: rising_ids.length)
    {
      "at" => at.iso8601(6),
      "top_count" => top_count,
      "rising_count" => rising_count,
      "top_ranks" => top_ids.each_with_index.to_h { |id, index| [id, index + 1] },
      "rising_ranks" => rising_ids.each_with_index.to_h { |id, index| [id, index + 1] }
    }
  end

  def state(candidates:, polls:)
    {
      "version" => 1,
      "scoring_version" => "rss-rank-v1",
      "fingerprint" => "0" * 64,
      "started_at" => polls.first.fetch("at"),
      "last_truncated_at" => nil,
      "candidates" => candidates,
      "polls" => polls
    }
  end

  def transition(state:, previous_poll:, previous_candidate_ids:, flags: {})
    Cybort::RedditRssState::Transition.new(
      state: state,
      previous_poll: previous_poll,
      previous_candidate_ids: previous_candidate_ids,
      flags: {"history_gap" => false, "state_truncated" => false, "future_entries_excluded" => false}.merge(flags),
      future_exclusion_count: 0
    )
  end
end
