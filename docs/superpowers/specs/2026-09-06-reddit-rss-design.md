# Reddit V2: Public RSS Ranking Design

**Status:** Implemented and offline-verified; not live-verified
**Date:** 2026-09-06
**Planning completed:** 2026-09-07
**Implementation completed:** 2026-09-07 (Tasks 1–5)
**Decision:** [ADR 0006](../../adr/0006-reddit-rss-observed-ranking.md)
**Plan:** [Implementation plan](../plans/2026-09-06-reddit-rss.md)
**Input:** [Original sketch](../../spitballing/reddit-v2-spitballing.md), preserved unchanged

The user delegated design decisions and waived intermediate human approvals.
The implementation is now present as the explicit opt-in `reddit_rss`
connector described below. This record does not authorize account changes, a
polling service, unattended production use, or bypassing Reddit access
controls.

## Implementation status

Tasks 1–5 implemented the parser, fixed public-feed transport lane, bounded
state/history, deterministic observed-pool ranking, adapter registration, and
snapshot integration without changing the OAuth `reddit` connector, SQLite
schema, persistence ownership, or adapter SQL. Offline verification uses local
fixtures and injected transports; no live Reddit request was made. The
connector remains experimental until the live gates below are closed.

## Evaluation and decision

Build a separate `adapter = "reddit_rss"` for explicitly configured public
subreddits. Keep `reddit` and its OAuth implementation unchanged. Use the
existing HTTP transport, Ruby `rss` gem, generic synchronization-state JSON,
and complete-result snapshot replacement. No new gems or SQLite schema.

The sketch is a useful prominence detector, not a statistically representative
measurement of the subreddit's activity distribution. Adopt its three feeds,
weights, bounded history, and explainable selection, with these corrections:

| Sketch point | Selected contract |
|---|---|
| Personal scripts cannot use the API | Treat the user's approval failure as an observation, not a universal ban. Reddit currently requires explicit API approval; RSS accessibility is a separate question. |
| Approximately 90th percentile | Top decile of the **age-eligible observed pool**, with a current top/rising signal required; never claim population or vote percentiles. |
| Candidates enter through `new` | Union all three feeds. A cold start must not exclude a strong top/rising post merely because it fell off `new`. |
| Combined communities | A `ruby+rails` instance is one pooled ranking universe. It cannot also promise per-subreddit percentiles; use separate instances for those. |
| Feed timestamp is creation time | Require entry `published`; retain no `updated` fallback. An edit timestamp cannot prove creation in the preceding day. |
| Keep ranks at every poll | Keep only four complete observations and a capped 48-hour candidate dictionary. No unbounded time series. |
| Store author | Omit authors, bodies, HTML, media, and vote/comment counts. None is needed for this heuristic. |
| Poll every 10–20 minutes | Recommend external invocation every 15 minutes with `ttl_minutes = 15`. Cybort has no scheduler; TTL does not schedule work. |
| Continuous polling solves coverage | It improves coverage but cannot prove completeness: feeds may truncate, cache, omit, reorder, or fail. Always label the population observed-only. |
| First poll / outage | First poll and gaps over 60 minutes reset scoring history. New-to-history candidates get no artificial momentum windfall. |

### Alternatives

1. **Dedicated stateful RSS adapter (selected):** reuses persistence while
   isolating Reddit identity, feed-order assumptions, and ranking from generic
   RSS. Meets the sketch's history and explanation goals.
2. **Three ordinary RSS instances:** simplest ingestion, but no shared candidate
   universe, rank history, cross-feed deduplication, or final-decile selection.
3. **Replace OAuth `reddit` in place:** fewer adapter names, but silently loses
   subscriptions/inbox and changes snapshot identity/scope. Explicit opt-in is
   safer and makes the materially different capabilities visible.

## Evidence and live boundary

Reddit's [RSS wiki][reddit-rss] documents `.rss` and combined-subreddit routes,
but explicitly says it is no longer updated. It is historical first-party
documentation, not a current availability or ordering guarantee. The
[Responsible Builder Policy][policy], updated June 5, 2026, requires API
approval, transparency, and respect for access limits. It does not establish
an unrestricted automation exemption for RSS. Use only publicly offered feeds
where access is permitted; clarify permission before live operation if needed.
Do not rotate identities, proxies, hosts, cookies, or credentials to evade a
denial, and do not fall back to HTML scraping or `.json` endpoints.

A September 6 documentation-tool probe of
`https://www.reddit.com/r/ruby/new/.rss?limit=100` returned **Cache miss**.
That is a tool fetch failure, not an observed Reddit 403 or proof that RSS is
unavailable. No feed payload, feed ordering, combined route, or publication
timestamp semantics was verified. These are live release gates below; they do
not block writing a conditional implementation plan.

[Atom RFC 4287][atom] distinguishes publication from significant updates and
assigns no ranking meaning to entry order. Therefore both treating `published`
as Reddit creation time and treating returned order as Reddit ranking require
a Reddit-specific live check. `updated` is never substituted for `published`.
[Ruby RSS][ruby-rss] already supports Atom; use its object model, not a custom
XML parser. Its existing REXML dependency is also used for a small namespace
and structural preflight because `RSS::Parser.parse(StringIO, false)` can
force-bind foreign XML namespaces while extracting entries. Context7
`/ruby/rss` was consulted for parser/entry interfaces.

## Scope and configuration

Proposed canonical template, published as working only during implementation:

```toml
# Experimental, public RSS only. See README for coverage and access caveats.
[instances.reddit_ruby_rails]
name = "Ruby and Rails highlights"
adapter = "reddit_rss"
ttl_minutes = 15
retention_ttl_minutes = 2880
num_items_to_fetch = 20
subreddits = ["ruby", "rails"]
user_agent = "macos:com.example.cybort:v0.1.0 (by /u/your_username)"
# Optional integer weights; all four keys required if the table is provided.
# activity_weights = { top = 550, rising = 300, momentum = 100, persistence = 50 }
```

- `subreddits`: required array of 1–10 names, each 2–21 ASCII letters, digits,
  or underscores, without `r/` or `+`. Lowercase, deduplicate, and sort; joining
  these validated names with `+` is the only group URL construction.
- `user_agent`: required nonblank printable UTF-8, at most 256 bytes, matching
  existing Reddit product/application/version and `/u/username` identification
  syntax. This identifies the client but is not authentication. Never spoof a
  browser or include it in saved item/diagnostic fields.
- `num_items_to_fetch`: integer 1–100; final selected-item cap, not feed size or
  candidate storage limit. Common TTL/retention retain their current meanings.
- `activity_weights`: optional exact four-key table above, integers 0–1000,
  sum exactly 1000, and `top + rising > 0`. String-key/symbol-key normalization
  is explicit. Unknown or mixed duplicate keys fail static validation.
- The only three allowed source-option keys are `subreddits`, `user_agent`, and
  `activity_weights`. Reject unknown keys and reject a duplicate logical key
  supplied once as a String and once as a Symbol, even when the values match.
  Apply the same duplicate-key rule inside `activity_weights` before any
  normalization or copying.
- Reject credential, token, cookie, arbitrary `url`, and unknown source-specific
  options. No automatic subscription discovery or private RSS token feeds.
- Fixed V2 constants: feed limit 100; target fraction 1/10; eligibility window
  86,400 seconds; candidate lifetime 172,800 seconds; tolerated future skew
  300 seconds; history gap 3,600 seconds; four poll snapshots; 2,000 candidates;
  maximum serialized sync state 8,388,608 bytes; scoring version `rss-rank-v1`.

Changing group membership changes the ranking universe: use a new instance ID.
Changes to weights under the same group may reuse the ID, but reset ranking state.
Existing OAuth configuration is not auto-converted. New RSS IDs also avoid
accidentally displaying old private-message items on a cache hit. Removing old
configuration does not purge its data; existing lifecycle limitations remain.

## Components and ownership

| Component | Responsibility / interface |
|---|---|
| `Adapters::RedditRSS` | Static validation, Base cache contract, one fetch attempt, Items and complete result |
| `RedditRssClient` | Fixed-host GETs, bounded Atom decoding, strict Reddit post identity; `fetch(sort:, subreddits:, user_agent:, deadline_monotonic:) -> Page` |
| `RedditRssCoordinator` | Process-wide single public-feed lane, spacing, observed throttling; injectable clock/sleeper for tests |
| `RedditRssState` | Pure JSON-safe state validation, candidate merge/eviction, four-poll history; no SQL or file I/O |
| `RedditRssActivity` | Pure deterministic fixed-point scores, selection, explanation fields |
| Existing persistence | Atomic selected snapshot + candidate/history state + successful run record |

The adapter creates a fresh client per remote attempt. No mutable feed/candidate
state is shared across instances. Only the public-host request gate is shared.
Do not subclass the ordinary RSS adapter: it stores content and has permissive
identity/date fallbacks unsuitable for this contract. Do not repurpose the
OAuth rate coordinator, which is keyed by client identity and OAuth operations.

## Fetch and failure contract

Fetch exactly once each, sequentially in `new`, `rising`, `top` order:

```text
https://www.reddit.com/r/<sorted+names>/new/.rss?limit=100
https://www.reddit.com/r/<sorted+names>/rising/.rss?limit=100
https://www.reddit.com/r/<sorted+names>/top/.rss?t=day&limit=100
```

No paging, detail requests, cookies, Authorization headers, browser automation,
redirect following, alternate-host fallback, or automatic retries. At most
three application requests per remote attempt; the User-Agent and an Atom/XML
Accept header are the only source-specific request headers.

Start an absolute 180-second monotonic attempt deadline before state decoding.
Each request deadline is `min(attempt_deadline, now + 30)`; pass both positive
remaining timeout seconds and absolute deadline to existing `HttpClient`.
Keep its 1,048,576-byte response limit. Check time before/after HTTP, parsing,
scoring, and final return. An expired attempt never returns success.

The coordinator serializes requests across RSS instances in this process,
including response observation, with at least two seconds from a preceding
request's completion to the next start. Waiting counts against each attempt's
deadline, uses injected sleeps outside the state mutex, and rechecks on wake.
Always release a lease in `ensure`. Do not hold the mutex during HTTP.

On HTTP 429, stop this attempt immediately. Honor valid `Retry-After` (seconds
or HTTP date) and `X-Ratelimit-Reset` as delay hints; use their maximum with a
60-second fallback minimum, and share the resulting monotonic cooldown with
other RSS instances. Do not cap a valid server delay downwards: an earlier
request would violate the server's explicit hint. Retry-After text is limited
to 128 bytes; decimal values remain nonnegative arbitrary-precision integers,
and HTTP-date subtraction uses exact `Time#to_r`/Rational arithmetic without
converting a huge hint through a float. The coordinator stores an observation
time plus the integer delay and compares exact rational elapsed time to the
delay, rather than adding a far-future delay to a monotonic clock. An active
cooldown fails immediately and does not allocate or sleep for the requested
delay. This honors large finite hints while keeping arithmetic safe. An
exhausted `X-Ratelimit-Remaining` also closes the
lane until reset or the fallback. Other attempts encountering an active
cooldown fail safely without waiting out or retrying the throttle. Fixed-host
401/403 are access-denied failures, not prompts to try another access method.

The shared `RateLimitHeaders` currently supports only numeric Retry-After.
Extend it with optional `now: Time.now.utc` and bounded HTTP-date parsing,
returning only a nonnegative integer delay. A 128-byte raw-text bound and
checked `Integer`/`Time.httpdate` parsing (with `Time#to_r` for exact date
subtraction) rejects malformed or non-finite input;
they are not a downward cap on a valid server delay. This preserves the safe
HttpError boundary without retaining raw headers; update its old date-rejection
test and add huge numeric and far-future date cases. Other HTTP exception
contracts and OAuth coordination behavior remain intact.

The gate is process-local, **not durable across CLI invocations or shared with
other programs on the IP**. Emit a safe remaining `retry_after_seconds` hint;
the operator/external invoker must honor it. This slice adds no background
poller, durable retry scheduler, or cross-process lock. A continuously repeated
forced-fetch command is not a supported substitute for that scheduler.

Add `RedditRssError < SourceError`: allowlisted operations `state`, `new`,
`rising`, `top`, `selection`; categories `access_denied`, `rate_limited`, `http`,
`network`, `timeout`, `deadline`, `response_too_large`, `invalid_feed`,
`invalid_entry`, `invalid_state`, `state_too_large`. Allow only source
`reddit_rss`, operation/category, numeric HTTP status, and finite nonnegative
retry delay in error metadata. Static messages and `cause: nil` prevent parser
messages, body fragments, paths, or headers from reaching diagnostic/history.

All three feeds must succeed and validate before committing any observation.
Any failure preserves prior items, sync state, freshness, and retention state.
Failed feeds are **unknown**, never a zero score or an empty observation. Other
sources can succeed. Empty valid three-feed snapshots are successful and may
clear selected items; HTML error pages and missing feeds are not empty success.

## Atom and identity boundary

Parse an in-memory `StringIO` containing validated UTF-8 XML; never pass a URL
or potentially path-like raw string to the RSS parser. Reject DTD/entity
declarations before parsing; accept built-in XML entity escapes. Require an
`RSS::Atom::Feed`, not generic RSS/RDF or a standalone entry. Before that RSS
extraction, parse the same bounded XML with existing `REXML::Document` and
inspect `REXML::Element#name`, `#namespace`, and child `#elements`: the root
must be `feed` in the exact Atom namespace URI
`http://www.w3.org/2005/Atom`; direct feed structural children `entry`, `id`,
`title`, and `updated`, when present, must use that URI; and each of the first
100 Atom `entry` children must have Atom-namespace `id`, `title`, and
`published` children, with optional `updated` and `link` children also required
to be Atom-namespace. The required entry children and optional singleton
`updated` child must be unique when present; present root metadata is also
singleton, while root metadata itself is optional and is not required solely
for preflight. A foreign-namespace
element with one of those structural local names is an invalid feed, not an
extension to ignore. Default and prefixed bindings are both accepted only when
`REXML::Element#namespace` resolves them to the exact URI; unbound or foreign
root/child/prefix bindings fail. Extension elements and content descendants are
ignored after this structural check. Only the first 100 entries then proceed to
RSS normalization, preserving the raw-prefix semantics below. No manual regex
namespace parser is used.

Ignore HTML content, author, media, and all remote resource references; never
dereference anything discovered in XML. Require plain-text Atom titles (`text`
or omitted type), nonblank and at most 2,048 UTF-8 bytes, with C0/DEL rejected.

Inspect only the first 100 entries in returned document order. `N` is this raw
prefix length, including duplicates and age-ineligible entries. Each retained
post keeps the first occurrence's one-based raw rank; do not compress ranks
after deduplication or age filtering. Conflicting duplicates fail the attempt.

Require a Reddit post alternate link on `https://www.reddit.com` or an absolute
path, at most 2,048 UTF-8 bytes, with no userinfo, port override, query,
fragment, encoded separators,
controls, or traversal segments. Accept an optional slug, but only a submission
path `/r/<name>/comments/<base36-id>[/<slug>/]`, never a comment permalink.
Short IDs match `[1-9a-z][0-9a-z]{0,15}`: 1–16 lowercase base36 characters,
without a leading zero. The subreddit must be in the configured normalized
group. Derive `t3_<id>` as
the canonical key and construct the stable URL
`https://www.reddit.com/r/<name>/comments/<id>/`; do not preserve tracking or
slugs. Atom entry ID must be that `t3_` value. If live feeds use another shape,
revise this boundary with evidence before relaxing it; do not fall back to a
hash of title/time. Duplicate identity/subreddit/publication-time conflicts
across feeds fail; title differences choose `new`, then `rising`, then `top`.

Unwrap `published.content` when available and require a finite `Time`; `updated` and feed-level
dates are not creation fallbacks. A missing/malformed publication date fails
the attempt with a content-free entry error. Valid posts more than five minutes
in the future are excluded and counted, not clamped into the window. Age for
accepted future-skew posts is zero. Live tests must confirm this creation-time
assumption; otherwise the advertised 24-hour creation rule is unsupported.

## Bounded state and continuity

Sync state is stored as a string-keyed JSON Hash with this exact envelope:

```text
version: 1
scoring_version: "rss-rank-v1"
fingerprint: SHA256(JSON([sorted_subreddits, ordered_weight_values]))
started_at: UTC ISO8601(6)
last_truncated_at: UTC ISO8601(6) or null
candidates: { "t3_id": {subreddit, title, published_at, first_seen_at, last_seen_at} }
polls: [{at, top_count, rising_count, top_ranks: {id: rank}, rising_ranks: {id: rank}}]
```

Storage continues to emit string-key JSON through `JSON.generate`, while the
existing `Persistence#parse_json` boundary returns symbolized keys recursively.
`RedditRssState.new` therefore accepts either String or Symbol keys at every
state level. Before creating an owned copy, it walks the input structure with
the schema's collection, depth, scalar-byte, timestamp, and rank bounds; an
unknown type, oversized collection/scalar, or duplicate logical key (one String
and one Symbol spelling the same key) fails with `invalid_state`. It then
canonicalizes keys recursively to Strings and validates the canonical copy.
This is a state-boundary change only: persistence schema and persistence writes
do not change, and no unbounded input is copied merely to discover that it is
too large.

`RedditRssState::Transition` is nested in `RedditRssState` and is the only
Transition constant. It carries the owned state and prior-observation signals;
there is no top-level `Cybort::Transition`. Tests exercise transition behavior
and immutability rather than asserting a constant exists in isolation.

Canonical URLs derive from keys/subreddits. No author/body/raw XML/response is
stored. Candidates include the union of valid entries from all feeds, plus
previous candidates still within 48 hours of publication and last observation.
Refresh last-seen and preferred title when present; preserve first-seen. Remove
records with either age at or beyond 172,800 seconds. If over 2,000 remain,
evict oldest publication time, then oldest last-seen, then ID ascending until
bounded, and record truncation time. Rank maps remain bounded to 100 each even
when a candidate is evicted; they are only history signals, not output records.

Retain at most four poll snapshots, including this completed poll. Missing
history gives zero prior prominence; however momentum is enabled for a post
only if it existed in the preceding candidate dictionary. Persistence counts
presence in top or rising across the stored snapshots, divided by the number
of snapshots (up to four), including absences before first observation.

Nil/empty state initializes a cold start. A recognized state with a changed
fingerprint/scoring version resets its history and candidates. Malformed,
oversized, or unknown-schema-version state fails safely; it does not clear
data or authorize silent repairs. Validate bounds, scalar types, canonical
identities, allowed keys, timestamp order, rank/count ranges, and byte size
before using persisted state. Work on a fresh copy, never mutate context.

A gap greater than 3,600 seconds, or non-increasing wall time, drops poll history
and resets `started_at`, preserving still-valid candidates. If stored times are
more than 300 seconds ahead of current wall time, use the same cold-history
reset and reject future candidates by the ordinary rule. First poll uses only
top/rising weights. Second contiguous successful poll enables history weights;
four give a full persistence window. Cache hits do not count as polls.

On a clock rollback reset, clamp saved first/last observation times and
`last_truncated_at` to no later than `now` before merging; never change a post's
publication time. This preserves first-seen <= last-seen even when a post is
re-observed with a clock earlier than the prior observation. Structural state
validation checks subreddit syntax independently of current group membership;
membership is enforced only after a matching fingerprint, so a legitimate
group-change reset cannot be rejected as corrupt old state.

Retention on `items` does **not** prune `sync_state_json`. State eviction is an
explicit pure transformation committed with successful results. During outages
and cache hits, data may outlive 48 hours; no hard wall-clock deletion guarantee
is made. Fetch history holds counts/flags only and never duplicates candidates.

## Exact ranking and selection

Compute fixed-point prominence in millionths, keeping raw rank semantics:

```text
P(N, r) = absent ? 0 : floor(1,000,000 * (N - r) / max(N - 1, 1))
Special case: N = 1 and r = 1 => 1,000,000
current = max(top_prominence, rising_prominence)
momentum = min(1,000,000, max(0, (current - previous_current) * 4))
persistence = floor(1,000,000 * appearances / stored_poll_count)
score_millionths = floor(sum(weight * component) / sum(active_weights))
```

Disable momentum for newly discovered posts. On cold history disable both
history components and renormalize by `top + rising`; otherwise use all four
weights. Never compare a stored weighted score to current raw prominence.
Scores are current-snapshot explanations, not probabilities or engagement
counts. A single-entry feed yields prominence one, not zero.

Let `D` be all distinct retained candidates with publication in
`[now - 86,400, now + 300]`. Let `S` be the subset of `D` present in the current
top or rising prefix. Denominator `M = D.length` includes zero-current-signal
candidates: taking ten percent of `S` instead would take the top decile of an
already activity-filtered sample. If `M == 0` or `S.empty?`, return none.

Sort `S` by score descending, better top rank (absence last), better rising
rank, newer publication time, then canonical ID ascending. Select
`min(ceil(M / 10), num_items_to_fetch, S.length)`; integer ceil is `(M + 9) / 10`.
This deliberately resolves an ambiguity in the sketch. Report both `M` and
`S.length` so the choice is inspectable. If `M < 10`, return at most one and
set low-sample confidence. Report selection-cap truncation separately.

For selection rank `j` (1-based), the displayed observed-pool ordinal percentile
is `floor(1,000,000 * (M-j) / max(M-1,1))`, with `M==1` defined as 1,000,000.
It is not an interpolated score percentile, probability, or population estimate.
Unsignalled candidates are ranked after signalled candidates for this ordinal.

## Output and confidence

Each Item: canonical `t3_` ID, reconstructed permalink, plain title,
`remote_created_at = published_at`, one attempt-wide `fetched_at`, `body = nil`,
`action_item = false`, and `priority = 100` for a sole selection or
`floor(100 * (K-j) / (K-1))` otherwise. Existing CLI presentation remains ordered
by creation time; `info.selection_rank` carries the detector's order.

`info` contains only kind `submission`, subreddit, scoring version, selection
rank, score/prominences/momentum/persistence in millionths, current top/rising
ranks (nullable), their raw denominators, prior ranks and signed prior-minus-
current rank changes when both exist, age seconds, observed-pool and signalled
counts, ordinal percentile millionths, and the confidence flags below.

Success metadata contains counts and flags, not titles, IDs, user agent, or
raw responses: each prefix size, observed/signalled/selected counts,
future-exclusion count, stored-history count, and scoring version. Flags:

- `observed_only`: always true; a public-feed sample never establishes population coverage.
- `warmup`: fewer than two contiguous successful polls.
- `low_sample_confidence`: observed eligible count below ten.
- `new_feed_saturated`: raw `new` prefix has 100 entries.
- `window_partial`: no current `new` entry at/before the 24-hour boundary, including an empty new feed.
- `history_gap`: continuity reset on this attempt.
- `state_truncated`: truncation occurred within the preceding 24 hours.
- `selection_capped`: configured cap reduced the quota after available signals.
- `future_entries_excluded`: at least one feed entry exceeded skew tolerance.

Return `replace_existing_items: true` only after complete validation/scoring;
the selected snapshot and bounded state commit atomically through existing
persistence. A complete empty selection clears old selected items. Old
candidates may remain in bounded state to support history, not presentation.

## Verification and release gates

Offline implementation tests use local Atom fixtures/injected transports:
URL/headers/order/bounds, raw-rank dedupe, hostile XML and identities, timestamp
semantics, exact math/ties/quota, cold start/new candidate/outage/config reset,
state limits, cache no-I/O, all-or-nothing three-feed failure, retained state on
transaction rollback, empty replacement, cross-instance isolation, rate lane
release/spacing/throttle, and safe diagnostic/history fields. Reuse existing
Minitest and persistence tests; Task 6 records the final offline command and
counts. The final `bundle exec rake test` run completed with 319 runs, 1,612
assertions, 0 failures, 0 errors, and 0 skips; no live Reddit request is part
of this evidence.

Before enabling unattended real use, separately confirm permitted public RSS
access, then fetch the three exact routes for one group at low volume. Confirm
Atom `published` matches actual post creation, `t3_` IDs/permalinks, meaningful
top/rising ordering, combined-group behavior, and returned limits. Capture only
sanitized shapes/counts/timing. Stop on denial or throttle; do not evade it.
Observe two legitimate poll cycles to validate warmup/history without claiming
statistical calibration. These permission, availability, identity, timestamp,
ordering, combined-group, limit, and two-cycle checks remain open for this
implementation. Failure keeps the connector experimental and may require a
revised design, not a hidden fallback. Ranking quality needs later human
evaluation; tests only prove the chosen heuristic is implemented
deterministically.

The offline persistence regression must exercise a real two-poll SQLite
roundtrip: persist one complete poll, call `context_for`, feed its recursively
symbolized state into the second poll, persist that result, and call
`context_for` again. It must prove that state history advances to two polls and
that storage remains string-key JSON without a persistence-code change.

The parser fixture matrix explicitly includes a foreign-namespace root, a
foreign structural child, valid default-namespace and prefixed-namespace Atom,
and malformed `published` values. DTD/entity rejection occurs before either
REXML or RSS extraction.

[reddit-rss]: https://www.reddit.com/r/reddit.com/wiki/rss/
[policy]: https://support.reddithelp.com/hc/en-us/articles/42728983564564-Responsible-Builder-Policy
[atom]: https://www.rfc-editor.org/rfc/rfc4287
[ruby-rss]: https://github.com/ruby/rss
