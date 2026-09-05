module Cybort
  # Pure, deterministic ranking and selection helpers for Reddit results.
  #
  # This module deliberately receives the fetch timestamp from its caller. It
  # has no clock of its own, which keeps activity scores reproducible in tests
  # and makes the adapter's single fetch-completion timestamp authoritative.
  module RedditActivity
    MEGATHREAD_PATTERN = /\bmega\s*thread\b|\blive\s+thread\b/i
    MIN_AGE_MINUTES = 60
    THREAD_PRIORITY_MAX = 99

    class Candidate
      ATTRIBUTES = %i[
        fullname subreddit title vote_score comment_count created_utc stickied
        age_minutes activity_score_milli megathread activity_rank priority selection_rank
      ].freeze

      attr_reader(*ATTRIBUTES)

      def initialize(fullname:, subreddit:, title:, votes:, comments:, created_utc:, stickied: false,
                     age_minutes: nil, activity_score_milli: nil, megathread: false,
                     activity_rank: nil, priority: nil, selection_rank: nil)
        @fullname = RedditActivity.required_string(fullname, :fullname)
        @subreddit = RedditActivity.required_string(subreddit, :subreddit).downcase
        @title = RedditActivity.required_string(title, :title)
        @vote_score = RedditActivity.nonnegative_integer(votes, :votes)
        @comment_count = RedditActivity.nonnegative_integer(comments, :comments)
        @created_utc = RedditActivity.timestamp(created_utc, :created_utc)
        unless stickied == true || stickied == false
          raise ValidationError, "stickied must be true or false"
        end
        @stickied = stickied
        @age_minutes = age_minutes.nil? ? nil : RedditActivity.positive_integer(age_minutes, :age_minutes)
        @activity_score_milli = activity_score_milli.nil? ? nil : RedditActivity.nonnegative_integer(activity_score_milli, :activity_score_milli)
        unless megathread == true || megathread == false
          raise ValidationError, "megathread must be true or false"
        end
        @megathread = megathread
        @activity_rank = activity_rank.nil? ? nil : RedditActivity.nonnegative_integer(activity_rank, :activity_rank)
        @priority = priority.nil? ? nil : RedditActivity.integer_in_range(priority, 0..100, :priority)
        @selection_rank = selection_rank.nil? ? nil : RedditActivity.positive_integer(selection_rank, :selection_rank)
        freeze
      end

      def votes
        vote_score
      end

      def comments
        comment_count
      end

      def megathread?
        megathread
      end

      def with_metadata(age_minutes:, activity_score_milli:, megathread:, activity_rank: nil, priority: nil,
                        selection_rank: nil)
        self.class.new(
          fullname: fullname,
          subreddit: subreddit,
          title: title,
          votes: vote_score,
          comments: comment_count,
          created_utc: created_utc,
          stickied: stickied,
          age_minutes: age_minutes,
          activity_score_milli: activity_score_milli,
          megathread: megathread,
          activity_rank: activity_rank,
          priority: priority,
          selection_rank: selection_rank
        )
      end

      def with_priority(value)
        with_metadata(
          age_minutes: age_minutes || MIN_AGE_MINUTES,
          activity_score_milli: activity_score_milli || 0,
          megathread: megathread,
          activity_rank: activity_rank,
          priority: value,
          selection_rank: selection_rank
        )
      end

      def with_selection_rank(value)
        with_metadata(
          age_minutes: age_minutes || MIN_AGE_MINUTES,
          activity_score_milli: activity_score_milli || 0,
          megathread: megathread,
          activity_rank: activity_rank,
          priority: priority,
          selection_rank: value
        )
      end

      def to_h
        {
          fullname: fullname,
          subreddit: subreddit,
          title: title,
          vote_score: vote_score,
          comment_count: comment_count,
          created_utc: created_utc,
          stickied: stickied,
          age_minutes: age_minutes,
          activity_score_milli: activity_score_milli,
          megathread: megathread,
          activity_rank: activity_rank,
          priority: priority,
          selection_rank: selection_rank
        }
      end
    end

    module_function

    def candidate(fullname:, subreddit:, title:, votes:, comments:, created_utc:, stickied: false)
      Candidate.new(
        fullname: fullname,
        subreddit: subreddit,
        title: title,
        votes: votes,
        comments: comments,
        created_utc: created_utc,
        stickied: stickied
      )
    end

    def score(votes:, comments:, age_minutes:)
      votes = integer(votes, :votes)
      comments = integer(comments, :comments)
      age_minutes = positive_integer(age_minutes, :age_minutes)
      ([votes, 0].max + (2 * [comments, 0].max)) * 60_000 / age_minutes
    end

    def rank(candidates, fetched_at:)
      fetched_at = timestamp(fetched_at, :fetched_at)
      ranked = Array(candidates).map { |value| coerce_candidate(value) }.map do |item|
        age_minutes = [(fetched_at - timestamp_seconds(item.created_utc)) / 60, MIN_AGE_MINUTES].max.floor
        activity_score_milli = score(
          votes: item.vote_score,
          comments: item.comment_count,
          age_minutes: age_minutes
        )
        item.with_metadata(
          age_minutes: age_minutes,
          activity_score_milli: activity_score_milli,
          megathread: megathread?(item),
          activity_rank: nil,
          priority: nil,
          selection_rank: nil
        )
      end.sort_by do |item|
        [-item.activity_score_milli, -item.comment_count, -item.vote_score, -timestamp_seconds(item.created_utc), item.fullname]
      end

      total = ranked.length
      ranked.each_with_index.map do |item, index|
        item.with_metadata(
          age_minutes: item.age_minutes,
          activity_score_milli: item.activity_score_milli,
          megathread: item.megathread,
          activity_rank: index,
          priority: thread_priority(index, total),
          selection_rank: nil
        )
      end
    end

    def rank_threads(candidates, fetched_at:)
      rank(candidates, fetched_at: fetched_at)
    end

    def megathread?(item)
      candidate = coerce_candidate(item)
      candidate.subreddit == "news" && candidate.title.match?(MEGATHREAD_PATTERN)
    end

    def assign_message_priority(messages)
      Array(messages).map do |message|
        if message.respond_to?(:with_priority)
          message.with_priority(100)
        elsif message.is_a?(Hash)
          message.merge(priority: 100)
        else
          message
        end
      end
    end

    def assign_thread_priorities(threads)
      values = Array(threads)
      values.each_with_index.map do |thread, index|
        priority = thread_priority(index, values.length)
        if thread.respond_to?(:with_priority)
          thread.with_priority(priority)
        elsif thread.is_a?(Hash)
          thread.merge(priority: priority)
        else
          thread
        end
      end
    end

    # Selects from messages first, then reserved megathreads, then ordinary
    # threads. Reservations are made before filling so a high message count
    # cannot accidentally hide every thread when the caller's limit permits
    # both categories.
    def select(limit:, messages:, megas:, threads:)
      limit = positive_integer(limit, :limit)
      categories = [Array(messages), Array(megas), Array(threads)]
      selected = []
      seen = {}

      message_reserved = false
      message_reserved = add_first_available(categories[0], selected, seen) if limit >= 1
      megathread_reserved = false
      if selected.length < limit
        megathread_reserved = add_first_available(categories[1], selected, seen)
      end

      if selected.length < limit
        has_thread = available?(categories[2], seen)
        reserve_ordinary = has_thread &&
          ((message_reserved && !megathread_reserved) || (!message_reserved && megathread_reserved))
        add_first_available(categories[2], selected, seen) if reserve_ordinary
      end

      categories.each do |category|
        break if selected.length >= limit

        category.each do |item|
          break if selected.length >= limit
          add_item(item, selected, seen)
        end
      end

      selected.each_with_index.map { |item, index| with_selection_rank(item, index + 1) }
    end

    def required_string(value, field)
      unless value.is_a?(String) && !value.empty?
        raise ValidationError, "#{field} must be a nonempty string"
      end
      value
    end

    def integer(value, field)
      return value if value.is_a?(Integer)

      raise ValidationError, "#{field} must be an integer"
    end

    def nonnegative_integer(value, field)
      [integer(value, field), 0].max
    end

    def positive_integer(value, field)
      value = integer(value, field)
      raise ValidationError, "#{field} must be positive" unless value.positive?

      value
    end

    def integer_in_range(value, range, field)
      value = integer(value, field)
      raise ValidationError, "#{field} is outside its allowed range" unless range.cover?(value)

      value
    end

    def timestamp(value, field)
      value = value.to_f if value.is_a?(Time)
      unless value.is_a?(Integer) || value.is_a?(Float)
        raise ValidationError, "#{field} must be a finite numeric timestamp"
      end
      unless value.finite?
        raise ValidationError, "#{field} must be a finite numeric timestamp"
      end

      value
    end

    def timestamp_seconds(value)
      value.is_a?(Time) ? value.to_f : value
    end

    def coerce_candidate(value)
      return value if value.is_a?(Candidate)
      unless value.is_a?(Hash)
        raise ValidationError, "candidate must be a RedditActivity::Candidate or hash"
      end

      Candidate.new(
        fullname: value.fetch(:fullname) { value.fetch("fullname") },
        subreddit: value.fetch(:subreddit) { value.fetch("subreddit") },
        title: value.fetch(:title) { value.fetch("title") },
        votes: value.fetch(:votes) { value.fetch(:vote_score) },
        comments: value.fetch(:comments) { value.fetch(:comment_count) },
        created_utc: value.fetch(:created_utc),
        stickied: value.fetch(:stickied, false)
      )
    rescue KeyError => error
      raise ValidationError, "candidate missing #{error.key}"
    end

    def thread_priority(index, total)
      return THREAD_PRIORITY_MAX if total <= 1

      THREAD_PRIORITY_MAX - ((index * THREAD_PRIORITY_MAX) / (total - 1))
    end

    def category_identity(item)
      if item.respond_to?(:fullname)
        item.fullname
      elsif item.is_a?(Hash)
        item[:fullname] || item["fullname"] || item[:canonical_id] || item["canonical_id"]
      else
        item
      end
    end

    def available?(category, seen)
      category.any? { |item| !seen.key?(category_identity(item)) }
    end

    def add_first_available(category, selected, seen)
      item = category.find { |candidate| !seen.key?(category_identity(candidate)) }
      return false unless item

      add_item(item, selected, seen)
      true
    end

    def add_item(item, selected, seen)
      identity = category_identity(item)
      return false if seen.key?(identity)

      selected << item
      seen[identity] = true
      true
    end

    def with_selection_rank(item, rank)
      if item.respond_to?(:with_selection_rank)
        item.with_selection_rank(rank)
      elsif item.is_a?(Hash)
        item.merge(selection_rank: rank)
      else
        item
      end
    end
  end
end
