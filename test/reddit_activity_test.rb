require "test_helper"

class RedditActivityTest < Minitest::Test
  FETCHED_AT = 1_000_000

  def test_calculates_integer_activity_score
    assert_equal 240_000, Cybort::RedditActivity.score(votes: 100, comments: 70, age_minutes: 60)
    assert_equal 120_000, Cybort::RedditActivity.score(votes: 100, comments: 70, age_minutes: 120)
    assert_equal 0, Cybort::RedditActivity.score(votes: -2, comments: -3, age_minutes: 60)
  end

  def test_rejects_non_integer_score_inputs
    ["100", nil, 1.5].each do |value|
      assert_raises(Cybort::ValidationError) do
        Cybort::RedditActivity.score(votes: value, comments: 1, age_minutes: 60)
      end
      assert_raises(Cybort::ValidationError) do
        Cybort::RedditActivity.score(votes: 1, comments: value, age_minutes: 60)
      end
    end

    assert_raises(Cybort::ValidationError) do
      Cybort::RedditActivity.score(votes: 1, comments: 1, age_minutes: 1.5)
    end
    assert_raises(Cybort::ValidationError) do
      Cybort::RedditActivity.score(votes: 1, comments: 1, age_minutes: 0)
    end
  end

  def test_candidate_uses_one_hour_floor_and_clamps_future_timestamps
    recent = candidate(fullname: "t3_recent", created_utc: FETCHED_AT - 30)
    future = candidate(fullname: "t3_future", created_utc: FETCHED_AT + 30)

    ranked = Cybort::RedditActivity.rank([recent, future], fetched_at: FETCHED_AT)

    assert_equal 60, ranked.first.age_minutes
    assert ranked.all? { |item| item.activity_score_milli == 120_000 }
    future = ranked.find { |item| item.fullname == "t3_future" }
    assert_equal 60, future.age_minutes
    assert_equal 120_000, future.activity_score_milli
  end

  def test_rejects_malformed_candidates_and_nonfinite_timestamps
    assert_raises(Cybort::ValidationError) { Cybort::RedditActivity.rank([{}], fetched_at: FETCHED_AT) }
    assert_raises(Cybort::ValidationError) do
      Cybort::RedditActivity.candidate(
        fullname: "t3_bad", subreddit: "news", title: "Bad", votes: 1,
        comments: 1, created_utc: Float::NAN, stickied: false
      )
    end
    assert_raises(Cybort::ValidationError) do
      Cybort::RedditActivity.rank([], fetched_at: Float::INFINITY)
    end
  end

  def test_sorts_by_score_comments_votes_created_time_then_fullname
    candidates = [
      candidate(fullname: "t3_z", votes: 10, comments: 5, created_utc: 101),
      candidate(fullname: "t3_a", votes: 10, comments: 5, created_utc: 101),
      candidate(fullname: "t3_new", votes: 10, comments: 5, created_utc: 102),
      candidate(fullname: "t3_more_votes", votes: 10, comments: 5, created_utc: 101),
      candidate(fullname: "t3_more_comments", votes: 8, comments: 6, created_utc: 101)
    ]

    ranked = Cybort::RedditActivity.rank(candidates, fetched_at: 10_000)

    assert_equal %w[t3_more_comments t3_new t3_a t3_more_votes t3_z], ranked.map(&:fullname)
    assert_equal [99, 75, 50, 25, 0], ranked.map(&:priority)
    assert_equal [0, 1, 2, 3, 4], ranked.map(&:activity_rank)
  end

  def test_classifies_only_news_megathread_titles
    megathreads = [
      candidate(fullname: "t3_1", subreddit: "news", title: "Megathread"),
      candidate(fullname: "t3_2", subreddit: "news", title: "mega thread"),
      candidate(fullname: "t3_3", subreddit: "news", title: "LIVE THREAD: updates"),
      candidate(fullname: "t3_4", subreddit: "news", title: "A sticky post", stickied: true),
      candidate(fullname: "t3_5", subreddit: "worldnews", title: "Megathread")
    ]

    ranked = Cybort::RedditActivity.rank(megathreads, fetched_at: FETCHED_AT)

    assert_equal %w[t3_1 t3_2 t3_3], ranked.select(&:megathread?).map(&:fullname).sort
    refute ranked.find { |item| item.fullname == "t3_4" }.megathread?
    refute ranked.find { |item| item.fullname == "t3_5" }.megathread?
  end

  def test_assigns_message_and_thread_priorities
    one = Cybort::RedditActivity.assign_message_priority([candidate(fullname: "t4_message")])
    many = Cybort::RedditActivity.assign_thread_priorities(
      [candidate(fullname: "t3_1"), candidate(fullname: "t3_2")]
    )

    assert_equal [100], one.map(&:priority)
    assert_equal [99, 0], many.map(&:priority)
  end

  def test_selection_reserves_categories_and_deduplicates
    assert_equal %w[m1], ids(select(limit: 1, messages: %w[m1], megas: %w[g1], threads: %w[t1]))
    assert_equal %w[g1], ids(select(limit: 1, messages: [], megas: %w[g1], threads: %w[t1]))
    assert_equal %w[m1 t1], ids(select(limit: 2, messages: %w[m1 m2], megas: [], threads: %w[t1]))
    assert_equal %w[m1 g1], ids(select(limit: 2, messages: %w[m1], megas: %w[g1], threads: %w[t1]))
    assert_equal %w[g1 t1], ids(select(limit: 2, messages: [], megas: %w[g1], threads: %w[t1]))
    assert_equal %w[m1 g1 m2 t1], ids(select(limit: 4, messages: %w[m1 m2], megas: %w[g1], threads: %w[t1 t2]))
    assert_equal %w[m1 g1 t1], ids(select(limit: 4, messages: %w[m1], megas: %w[g1 m1], threads: %w[m1 t1]))
  end

  def test_selection_attaches_one_based_selection_rank_without_changing_activity_rank
    ranked = Cybort::RedditActivity.rank(
      [candidate(fullname: "t3_thread", votes: 100, comments: 1)], fetched_at: FETCHED_AT
    )
    selected = Cybort::RedditActivity.select(limit: 2, messages: [candidate(fullname: "m1")], megas: [], threads: ranked)

    assert_equal %w[m1 t3_thread], ids(selected)
    assert_equal [1, 2], selected.map(&:selection_rank)
    assert_equal [0], selected.last(1).map(&:activity_rank)
  end

  private

  def candidate(fullname: "t3_candidate", subreddit: "news", title: "A title", votes: 100, comments: 10,
                created_utc: FETCHED_AT - 3600, stickied: false)
    Cybort::RedditActivity.candidate(
      fullname: fullname,
      subreddit: subreddit,
      title: title,
      votes: votes,
      comments: comments,
      created_utc: created_utc,
      stickied: stickied
    )
  end

  def select(**options)
    Cybort::RedditActivity.select(**options)
  end

  def ids(values)
    values.map { |value| value.respond_to?(:fullname) ? value.fullname : value }
  end
end
