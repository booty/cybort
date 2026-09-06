# Reddit Connector, V2

## Introduction

As of September 2026 Reddit is not currently allowing personal scripts to have direct API access.
All we have to work with is RSS (Atom format) feeds.

The goal of our RedditV2 connector is not to comprehensively list all posts in specific subreddits,
it is to identify the posts in approximately the 90th percentile of noteworthy posts, per subreddit
or multireddit. Here is our initial take on an algorithm.

Note that some subreddits are much more active than others; a post with 200 upvotes and replies on
r/ruby may be more noteworthy than one with 5000 upvotes on r/news, so those RSS feeds will need to
be fetched separately. These will be separate items in cybort.toml

Some entries in cybort.toml may combine subreddits that DO have similar activity levels. For
example, r/ruby and r/rails or r/budgetaudiophile and r/audiophile.


## Handoff: RSS-based recent-post detector

### Objective

For one subreddit, identify posts created within the last 24 hours that rank approximately in the
top 10% for current activity.
This is an RSS-only approximation. Reddit RSS does not reliably expose structured vote or comment
counts, so “90th percentile” means the 90th percentile of an activity score inferred from Reddit’s
top and rising rankings—not the exact 90th percentile by upvotes.

Inputs
- Subreddit name
- Rolling window: 24 hours
- Poll interval: 10–20 minutes
- Feed limit: 100
- Target percentile: 0.90

### Feeds

Poll these independently:

https://www.reddit.com/r/{subreddit or subreddits}/new/.rss?limit=100
https://www.reddit.com/r/{subreddit or subreddits}/rising/.rss?limit=100
https://www.reddit.com/r/{subreddit or subreddits}/top/.rss?t=day&limit=100

Use new for candidate discovery, rising for acceleration, and top?t=day for established activity.

Do not use top?t=week as the primary source: older posts have had more time to accumulate
engagement, and filtering a limited weekly result afterward can miss recent posts ranked below the
feed cutoff.

If multiple subreddits are specified in a single cybort.toml entry, combine them like the following
example for subreddits named `foo`, `bar`, and `baz`:
https://www.reddit.com/r/foo+bar+baz/new/.rss?limit=100

### Persistent state

Store each post under a stable key derived from its canonical Reddit permalink or Atom entry ID.
For every post, retain:

- Subreddit
- Title
- Permalink
- Author, if present
- Feed timestamp
- First-seen and last-seen times
- Rank in each feed at every poll
- Number of recent polls in which it appeared
- Current activity score
- Coverage and confidence flags

Expire records after roughly 48 hours.

Processing each poll

1. Fetch the feeds sequentially, spacing requests apart.
2. Respect HTTP 429 and X-Ratelimit-Reset.
3. Parse the responses as Atom XML.
4. Normalize each permalink and deduplicate entries found in multiple feeds.
5. Add every entry from new to the candidate store.
6. Record each entry’s one-based position in rising and top.
7. Reject entries whose feed timestamp is:
- More than 24 hours old, or
- Unreasonably far in the future, allowing a small clock-skew tolerance.
8. Retain previous observations so rank movement can be measured.

### Convert rank to prominence

For a feed containing N entries, convert rank r into a value from 0 to 1:
rank prominence = 1 - ((r - 1) / max(N - 1, 1))

Thus:
- First position produces 1
- Last position produces 0
- Absence from the feed produces 0

Calculate separate topProminence and risingProminence.

### Momentum and persistence

Let currentProminence be the greater of the current top and rising prominence values.
Momentum measures improvement since the preceding successful poll:

momentum = clamp(
(currentProminence - previousProminence) / 0.25,
0,
1
)

A gain of 25 percentile points or more receives maximum momentum credit. Falling or stationary posts
receive no momentum credit.

Persistence is the fraction of the last four successful polls in which the post appeared in either
top or rising.

### Activity score

Use this initial weighting:
activity score =
0.55 × top prominence
+ 0.30 × rising prominence
+ 0.10 × momentum
+ 0.05 × persistence

Keep the weights configurable and versioned. On the first poll, when history is unavailable, omit
momentum and persistence and renormalize the remaining weights.

### Select the approximate 90th percentile

For all eligible posts in the rolling 24-hour window:

1. Require at least one activity signal: appearance in top or rising.
2. Sort descending by activity score.
3. Break ties deterministically using:
- Better top rank
- Better rising rank
- Newer timestamp
- Canonical post ID
4. Let:
K = max(1, ceiling(number of eligible candidates × 0.10))
5. Return the first K posts.

Selecting an exact count avoids returning dozens of posts when many candidates have identical scores
at the percentile boundary.
If fewer than ten eligible posts exist, return at most one and mark the result lowSampleConfidence.
### Output

Each result should explain why it qualified:
title
permalink
subreddit
created timestamp
age
activity score
percentile within observed candidates
top rank
rising rank
rank change
confidence
Presenting the underlying signals makes the heuristic inspectable and tunable.

### Coverage limitations

A single new response contains at most 100 entries. On a busy subreddit, that may not cover the
entire preceding 24 hours.
Continuous polling solves most of this: accumulate new posts on every poll, provided fewer than 100
posts arrive between polls. On cold start, if the oldest returned entry is still less than 24 hours
old, mark coverage as partial; the system cannot claim it observed the full window.

### Also
- Do not infer zero activity when a feed request fails.
- Preserve the previous successful snapshot during temporary failures.
- Do not calculate momentum across an unusually long outage.
- Sanitize or ignore Atom HTML content.
- Back off instead of retrying aggressively.
- Keep the detector in a warm-up state until at least two successful polling cycles provide rank
history.
Acceptance criteria
- Every returned post is no more than 24 hours old.
- Approximately the top 10% of eligible observed posts are returned.
- Percentiles are calculated within the requested subreddit.
- Duplicate feed entries produce one result.
- A failed or throttled feed does not erase prior state.
- Cold-start and incomplete-window results are visibly labeled.
- Every selection includes its ranks and scoring explanation.
