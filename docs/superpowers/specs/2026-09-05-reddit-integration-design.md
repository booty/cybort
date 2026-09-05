# Reddit Integration Design

**Status:** Approved for implementation planning
**Date:** 2026-09-05

## Summary

Cybort will add a direct-HTTP `reddit` adapter using a user-authorized OAuth
refresh token. A configured Reddit instance collects unread legacy private
messages and a deterministic, bounded selection of active submission threads.
The default thread scope is the user's subscribed communities, sampled through
the authenticated personalized `/hot` listing; explicit additions and `r/news`
receive documented single-subreddit requests, while exclusions prevent both
selection and avoidable outbound requests.

The adapter stores message subjects and thread titles, canonical Reddit URLs,
timestamps, visible vote scores, comment totals, and small typed metadata. It
does not store Reddit bodies, comments, authors, media, linked-page content, or
raw responses. LLM summaries and aggregate statistics for the user's own posts
remain future work.

V1 also adds a source-neutral current-snapshot capability to the existing
adapter contract. `FetchResult#replace_existing_items`, defaulting to `false`,
lets a complete successful remote result atomically replace the instance's
current items. Complete Reddit remote results opt in so posts that leave the
bounded selection and unread messages that become inactive disappear locally.
Cache hits, failures, and incomplete remote work never replace or prune data.

Reddit documents an unread legacy private-message endpoint but no consumer-chat
read endpoint. V1 collects conservatively qualified legacy inbox messages from
`/message/unread` and reports chat as unsupported on remote successes. It does
not scrape Reddit or use undocumented chat endpoints.

## Goals

- Show unread legacy Reddit private messages without intentionally changing
  their read state.
- Show highly active threads from a bounded view of the effective subreddit
  scope.
- Recognize and reserve space for an `r/news` megathread when `news` is in
  scope.
- Default scope to subscribed subreddits, with explicit additions and
  exclusions.
- Store stable identities, canonical URLs, titles/subjects, visible vote
  scores, and comment totals without Reddit body content.
- Remove items absent from a complete successful Reddit snapshot while
  preserving existing cache, failure, transaction, and retention boundaries.
- Keep automated tests offline through injected clients and local fixtures.

## Non-goals

- reading consumer Reddit Chat until Reddit documents and grants a supported
  read interface;
- marking messages read, replying, voting, posting, moderating, or mutating an
  account;
- collecting inbox comment replies, username mentions, post replies, modmail,
  or Reddit announcements;
- storing message or submission bodies, comments, authors, media, previews,
  thumbnails, outbound linked-page content, or full API payloads;
- exhaustive coverage of every hot post in every joined subreddit;
- LLM summaries, embeddings, classification, or aggregate personal-post stats;
- a scheduler, push stream, or delta-based activity velocity;
- exact vote counts—Reddit's `score` is the visible/fuzzed value;
- a Reddit-specific table or persistence path;
- hard wall-clock deletion during outages, automatic cleanup when a configured
  instance is removed, or a user-facing purge workflow; and
- an interactive OAuth authorization flow.

## Official API and policy basis

This design was checked on 2026-09-05 against Reddit-controlled sources:

- the [Reddit Data API Wiki](https://support.reddithelp.com/hc/en-us/articles/16160319875092-Reddit-Data-API-Wiki),
  which requires registered OAuth traffic and a descriptive User-Agent,
  documents the free-access rate policy and rate headers, and describes
  retention/deletion obligations;
- Reddit's [generated OAuth endpoint reference](https://www.reddit.com/dev/api/oauth),
  which documents `/message/unread`, `/subreddits/mine/subscriber`, `/hot`, and
  `/r/{subreddit}/hot`, fullname pagination, and listing pages up to 100;
- Reddit's [Data API Terms](https://redditinc.com/policies/data-api-terms), last
  revised July 20, 2026, which require documented access, prohibit limit
  circumvention and reverse engineering, restrict retention to the approved
  use case, and require deletion when access terminates; and
- Reddit's archived official [OAuth2 documentation](https://github.com/reddit-archive/reddit/wiki/oauth2),
  which describes authorization-code refresh tokens, Basic authentication for
  token exchange, bearer requests to `oauth.reddit.com`, and one-hour tokens.

The generated endpoint reference documents private messages and modmail but no
consumer-chat read endpoint. Treating chat as unsupported is an inference from
that documented surface and the access restrictions. Because Reddit labels
legacy resources as potentially outdated, authenticated state-preservation and
response-shape checks remain release gates.

## Approaches considered

### Direct OAuth Data API client — selected

Extend the injectable HTTP transport with bounded form POST support, and put
Reddit OAuth/listing behavior in `RedditClient`. This matches the RSS/GitHub
adapter model and keeps protocol concerns out of persistence.

### External command-backed adapter

Rejected. There is no maintained official Reddit CLI that removes the OAuth or
API-contract work. A third-party command adds dependency and authentication
failure modes without improving policy alignment.

### Scraping or undocumented chat interfaces

Rejected. Browser state and private chat APIs are undocumented, brittle, and
incompatible with the terms' documented-access boundary.

## Configuration and authentication

```toml
[instances.personal_reddit]
name = "Personal Reddit"
adapter = "reddit"
ttl_minutes = 15
retention_ttl_minutes = 2880
num_items_to_fetch = 50
client_id = "..."
client_secret = "..."
refresh_token = "..."
user_agent = "macos:com.example.cybort:v0.1.0 (by /u/example_user)"
include_subreddits = ["news"]
exclude_subreddits = ["memes"]
```

`client_id`, `client_secret`, `refresh_token`, and `user_agent` are required
strings. Validation first requires `value.strip` to be nonempty, then rejects
all C0 controls (`U+0000`–`U+001F`) and DEL (`U+007F`) anywhere. Maximum encoded
UTF-8 lengths are 256 bytes for `client_id`, 1,024 for `client_secret`, 4,096
for `refresh_token`, and 256 for `user_agent`. These fields remain configuration
only and must never appear in SQLite, URLs, errors, metadata, or logs.

After those checks, User-Agent must match:

```text
\A[^:\s]+:[^:\s]+:[^\s()]+ \(by /u/[A-Za-z0-9_-]+\)\z
```

The user provisions an approved confidential OAuth app and permanent
authorization-code refresh token outside Cybort with at least the required
read capabilities:

- `read` for thread listings;
- `mysubreddits` for subscribed-subreddit discovery; and
- `privatemessages` for unread legacy private messages.

Every remote fetch exchanges the refresh token at
`https://www.reddit.com/api/v1/access_token` with HTTP Basic authentication and
the form fields `grant_type=refresh_token` and `refresh_token`. The response
must contain a nonblank `access_token`, `token_type` equal to `bearer`
case-insensitively, a finite positive numeric `expires_in`, and all required
scopes (`*` also satisfies the check). Data calls go only to
`https://oauth.reddit.com` with the bearer token and validated User-Agent.

`include_subreddits` and `exclude_subreddits` default to empty arrays. Names
omit `r/`, match `\A[A-Za-z0-9_]{2,21}\z`, normalize to lowercase, and dedupe
case-insensitively. Exclusion wins. Each list is capped at 50 names, bounding
the documented one-request-per-explicit-subreddit behavior. The common
`num_items_to_fetch` is an integer from 1 through 100 and limits the final
combined selection, not candidate scanning or retention.

## Bounded subreddit discovery

Define:

```text
subscriptions = complete paginated subscribed-name set
joined_effective = subscriptions MINUS exclusions
explicit_to_fetch = (inclusions MINUS exclusions) MINUS subscriptions
effective = joined_effective UNION explicit_to_fetch
```

The client completely paginates
`/subreddits/mine/subscriber?limit=100&raw_json=1`. Each `after` is either `nil`
or a valid `t5_<lowercase-base36>` fullname, and no non-nil cursor may repeat.
Each child must be `kind: "t5"`, have a lowercase-base36 `id`, and have exact
`name == "t5_#{id}"`; `display_name` must independently pass the subreddit-name
validator. Invalid or partial discovery fails the result.

Candidate calls use only documented endpoints:

1. If `joined_effective` is nonempty, call authenticated
   `/hot?limit=100&raw_json=1` once and retain only candidates in that set. This
   is a bounded personalized-home sample, not proof that every joined
   subreddit was scanned.
2. For every sorted name in `explicit_to_fetch`, call its single-subreddit
   `/r/<name>/hot?limit=100&raw_json=1` once.
3. Apply the `news` rule only after exclusions. If `news` is excluded, make no
   `news` request. If it is in `explicit_to_fetch`, that ordinary explicit call
   is sufficient. If it is in `joined_effective`, make one dedicated
   `/r/news/hot?limit=100&raw_json=1` request so the megathread detector is not
   dependent on personalized-home placement.

V1 never constructs `/r/name+name/hot` or any other multi-subreddit path. V1
intentionally fetches only the first hot page from each endpoint; this is a
bounded selection contract, not exhaustive hot-list pagination. Candidates are
filtered against `effective` and deduplicated by validated `t3` fullname before
ranking.

Remote-success metadata exposes the limitation without leaking membership:

```text
coverage_mode: "personalized_home_plus_explicit_single_subreddit"
subscription_page_count: integer
home_hot_page_count: 0 or 1
explicit_subreddit_request_count: integer
news_dedicated_request: boolean
thread_candidate_count: integer
ratelimit_used: optional finite nonnegative number
ratelimit_remaining: optional finite nonnegative number
ratelimit_reset_seconds: optional finite nonnegative number
```

## Unread legacy private messages and chat

The client paginates:

```text
/message/unread?limit=100&mark=false&max_replies=0&raw_json=1[&after=...]
```

Unread cursors are `nil` or a valid `t1_...`/`t4_...` lowercase-base36
fullname and must not repeat. Pagination continues until `after` is nil or the
adapter has found enough *qualifying* messages to satisfy its possible message
quota. Filtering happens before applying that quota; unrelated inbox objects
cannot crowd out legacy messages.

A qualifying V1 message is conservatively defined as:

- child `kind` is `t4`;
- `data.id` is lowercase base36 and `data.name == "t4_#{data.id}"`;
- `data.new` is exactly `true`; and
- `data.was_comment` is absent or exactly `false`.

Non-`t4` children are ignored. A `t4` child with malformed required identity or
timestamp fields fails the page; a valid `t4` that is not new or is a comment
reply is filtered out. The documented response shape does not provide a
general discriminator for every legacy/system message class, so V1 labels the
stored category **unread legacy inbox messages** and does not claim to exclude
announcements or modmail beyond the explicit predicate above. The
documented `mark=false` parameter and absence of write endpoints mean Cybort
does not intend to change read state; the design does not claim that the
parameter alone guarantees server behavior. Before release, an authenticated
smoke test must compare the qualifying unread IDs/count immediately before and
after collection and confirm no change.

Message normalization is:

| `Item` field | Value |
|---|---|
| `canonical_id` | validated `t4_<id>` fullname |
| `urls` | constructed `https://www.reddit.com/message/messages/<id>` |
| `fetched_at` | the adapter's single fetch completion timestamp |
| `remote_created_at` | UTC value from finite `created_utc` |
| `title` | nonblank `subject`, otherwise `Unread Reddit message` |
| `body` | `nil` |
| `priority` | `100` |
| `action_item` | `true` |
| `info` | `kind: "legacy_private_message"`, `unread: true`, final `selection_rank` |

No author, body, replies, or raw object are retained. A successful *remote*
result includes `chat_collection: "unsupported_by_documented_data_api"`.
Cache hits return persisted items through the existing base-adapter cache path
and do not synthesize remote capability metadata; their metadata remains empty.

## Submission identity and canonical URLs

Every retained candidate must have `kind: "t3"`, a lowercase-base36 `id`, and
an exact `name == "t3_#{id}"`. A syntactically valid home candidate outside
`joined_effective` is an expected recommendation and is filtered. A candidate
from `/r/<name>/hot` whose normalized subreddit does not equal `<name>` fails
the result as an identity mismatch.

`permalink` is accepted only as a relative path with no scheme, authority,
query, fragment, backslash, C0/DEL control, encoded control, encoded slash,
backslash, question mark, or hash, malformed percent escape, or dot/dot-dot
traversal segment after percent decoding. Its decoded leading segments must be
exactly:

```text
r / <normalized-subreddit> / comments / <id>
```

The adapter re-encodes the safe decoded path segments and constructs the
canonical URL as `https://www.reddit.com/<segments>`. It never trusts an
absolute source URL or stores a submission's outbound link. Duplicates sharing
a fullname must agree on stable identity fields (fullname, normalized
subreddit, and canonical path). If mutable fields differ because home and a
dedicated request raced, the deterministic source precedence is dedicated
single-subreddit data over the personalized-home sample, dedicated `news` over
other sources, then first observation within the same source. The selected
record's title, counters, stickiness, and score come from that winning record;
stable identity disagreement fails the complete result.
Name/ID/subreddit/permalink mismatches fail the complete result, preventing
unstable identity or host/path confusion.

## Activity metric, megathreads, and selection

For each valid submission:

```text
vote_score = max(Integer(score), 0)
comment_count = max(Integer(num_comments), 0)
age_minutes = max(floor((fetched_at - created_utc) / 60), 60)
engagement_points = vote_score + (2 * comment_count)
activity_score_milli = floor(engagement_points * 60_000 / age_minutes)
```

The integer score estimates weighted engagement points per hour. Comment
weight 2 intentionally favors discussion. The one-hour age floor controls
brand-new/future-skewed records. Negative integers clamp to zero; nonnumeric or
nonfinite values fail. This is deterministic cumulative engagement divided by
age, not recent-comment velocity.

Candidates sort by:

```text
activity_score_milli DESC,
comment_count DESC,
vote_score DESC,
created_utc DESC,
fullname ASC
```

An `r/news` submission is a megathread when its title matches
`/\bmega\s*thread\b|\blive\s+thread\b/i`. `stickied` is metadata only.

Let `M` be qualifying messages in listing order, `G` ranked news megathreads,
and `T` all other ranked threads. Selection is deterministic:

- For limit 1, choose the first available category in priority order `M`, `G`,
  then `T`.
- For limit at least 2, reserve one `M` if one exists. Then reserve one `G` if
  one exists and a slot remains. If `M` exists, no `G` was reserved, and any
  ordinary thread exists, reserve one `T`; this guarantees a message and a
  thread whenever both categories exist. If no message exists, a `G` was
  reserved, and `T` exists, reserve one `T` when capacity permits.
- Fill remaining slots from `M`, then `G`, then `T`, preserving each category's
  order. Emit reserved/fill choices in that same category order with duplicate
  identities removed.

Thus personal unread communication has deterministic priority at limit 1;
limits of at least 2 preserve thread visibility; and an available `r/news`
megathread receives the bounded thread reservation. Every selected item gets a
one-based `info.selection_rank` describing this final adapter selection.

For `N` total ranked thread candidates and zero-based activity rank:

```text
priority = 99 - floor(rank_index * 99 / max(N - 1, 1))
```

Message priority is 100; thread priority is 99 through 0. Priority expresses
Reddit activity rank only. The current CLI queries durable items by recency,
not adapter priority, and this slice does not change global CLI ordering.

Selected threads have `body: nil`, `action_item: false`, the canonical URL,
title, timestamps, rank-derived priority, and only this `info`: `kind`,
`subreddit`, `vote_score`, `comment_count`, `activity_score_milli`,
`megathread`, `stickied`, and `selection_rank`.

## Generic current-snapshot contract

`FetchResult` gains optional `replace_existing_items`, default `false`. The
success factory and direct construction validate it as exactly `true` or
`false`; the failure factory exposes no replacement option and always sets it
to `false`. Direct construction rejects an error-bearing replacement result.
Persistence independently validates the Boolean and rejects replacement unless
the result is successful and `source_fetched` is true.

For a valid replacement result, `Persistence#write_fetch_result` performs in
one existing per-result transaction:

1. validate the result, all items, and retention policy;
2. delete all existing items for that `adapter_instance_id` when
   `replace_existing_items` is true;
3. upsert every returned item;
4. apply the existing optional successful-fetch retention cutoff;
5. update synchronization state; and
6. append fetch history.

Any failure rolls back the delete and every later write. An empty complete
snapshot intentionally clears the instance's items. The behavior is generic
SQL owned by persistence; adapters do not issue deletes or compare database
rows.

Reddit sets `replace_existing_items: true` only after token exchange,
subscription discovery, all required message/hot calls, validation, ranking,
and normalization complete successfully. Fresh cache results keep the default
false. OAuth, permission, HTTP, rate, timeout, deadline, parsing, request-budget,
or persistence failures never replace. This preserves last-known-good behavior
while making each complete Reddit remote result the current bounded selected
set. It removes messages that are no longer unread and selected threads that
became inactive, were deleted, or fell out of the bounded sample.

`retention_ttl_minutes` is unchanged. On successful remote writes persistence
still prunes items at or before the configured local `fetched_at` cutoff using
its clamped clock. Replacement normally makes that pass redundant for Reddit,
but retaining the operation preserves one source-neutral transaction contract.
Cache hits and failures neither replace nor prune.

This decision is recorded in
[ADR 0004](../../adr/0004-current-snapshot-item-replacement.md).

## Components and ownership

### `HttpClient` and transport errors

The generic client gains form POST plus explicit
`open_timeout_seconds: 10`, `read_timeout_seconds: 30`,
`write_timeout_seconds: 30`, and
`max_response_body_bytes: 1_048_576` defaults. The transport reads response
bodies incrementally and raises an allowlisted `HttpTransportError` with
category `timeout` or `response_too_large`; it never includes a body, secret,
header value, or full URL.

Each request may receive a smaller `timeout_seconds` from the Reddit client's
remaining deadline. `HttpError` carries only status and centrally parsed safe
rate metadata. `RateLimitHeaders` is the only parser for case-insensitive
`X-Ratelimit-Used`, `X-Ratelimit-Remaining`, `X-Ratelimit-Reset`, and
`Retry-After` values. Rate fields accept only finite nonnegative numbers;
`Retry-After` accepts a nonnegative integer delta-seconds value in V1. Both
successful response handling and errors use this parser, resolving the previous
ambiguity about where rate metadata lives.

### `RedditClient`

Owns token refresh, safe headers/query encoding, JSON/listing validation,
cursor validation, request counting, centralized rate observation, and a
120-second monotonic per-fetch deadline. `authenticate` begins a fresh session:
it resets that session's request counter, deadline, safe metadata, and token
state. Listing methods require the returned session and cannot be reused after
the session expires; a second sequential authentication starts a new bounded
session. It checks the deadline before and after requests, passes remaining
seconds down as the request timeout cap, and does not return partial data after
expiry.

### `RedditRateLimitCoordinator`

A process-wide coordinator owns rate state and admission for Reddit requests.
Its key is the in-memory SHA-256 digest of `client_id`; neither plaintext IDs
nor digests are persisted or exposed. A mutex protects remaining/reset state
and monotonic waiting. It permits at most one in-flight request for a key, so
concurrent same-client instances cannot apply rate headers out of response
order. Before a request, a client acquires a lease and reserves capacity
according to known headers or waits only within the fetch deadline. Completion
observes parsed rate headers (and, on 429, `Retry-After`) before releasing the
lease. An `ensure` path releases a lease after transport failures without
inventing new capacity.

The coordinator covers multiple configured instances in one Cybort process
that share a client identity. Its mutex protects state transitions only; waits
and sleeps happen outside the mutex so unrelated client identities remain
admissible. It cannot coordinate other processes, machines, or restarts and
does not make the 90-request bound a global compliance guarantee.

### `RedditActivity` and `Adapters::Reddit`

The pure activity module owns candidate values, the exact score and sort key,
megathread classification, priority, and bounded category selection. The
adapter validates options, drives client operations, validates identities,
normalizes source items, and returns the payload consumed by `Adapters::Base`,
including `replace_existing_items: true` only for a complete remote success.
`Adapters::Base` remains the sole constructor of the existing result type.
Neither layer owns persistence.

`Adapters::Base` carries an optional source payload
`replace_existing_items` into the remote-success `FetchResult`, defaulting to
false. Its cache and rescued-failure paths always remain false. This is a
generic contract bridge rather than a Reddit branch.

### Persistence and orchestration

Persistence owns generic replacement, upsert, retention, synchronization, and
history in the established transaction. The orchestrator remains unchanged: it
freezes cache decisions/retention snapshots, runs adapter threads, then writes
sequentially. A mismatched result ID remains a failure under the configured ID.

## Request complexity, rate limits, deadline, and errors

A remote Reddit fetch has a 90-request *complexity bound*, including token
exchange, subscription/message pages, and hot calls. The client rejects the
next operation before exceeding it. This protects one fetch from runaway
pagination; it is not a substitute for Reddit's OAuth-client rate policy.

The process-wide coordinator handles known shared-client capacity as described
above. There are no blind automatic HTTP retries. A coordinator wait may occur
only while the fetch's 120-second monotonic deadline remains; otherwise the
complete result fails safely.

`RedditApiError` exposes only `operation`, `category`, and allowlisted rate
metadata. Operations are `token`, `subscriptions`, `unread_messages`,
`home_hot`, `subreddit_hot`, and `news_hot`. Categories include:

- `authentication` for a token or data response with HTTP 401;
- `authorization` for a token or data response with HTTP 403;
- `rate_limited` for HTTP 429 or coordinator admission expiry;
- `http` for other non-2xx responses;
- `invalid_json`, `invalid_shape`, or `invalid_identity`;
- `request_budget` or `deadline`; and
- `timeout` or `response_too_large` from the HTTP transport.

Tests distinguish token from data 401/403 failures through `operation`.
`RedditApiError` messages are constant templates assembled only from the
allowlisted operation, category, and status; upstream exception messages,
response excerpts, URLs, headers, subjects, and titles are never wrapped.
This matters because the existing base/CLI and fetch-history paths expose
`error.message` as well as `safe_metadata`. All Reddit errors therefore remain
body-free in result JSON and persisted fetch history. Errors never contain
access/refresh tokens, client values, response bodies, subjects, titles,
usernames, full URLs, or membership. Remote-success metadata contains
only bounded counts/capability/rate values. A failed result preserves old data.

## Cache, lifecycle, compliance, and privacy

- A fresh cache returns persisted items with `source_fetched: false`,
  `replace_existing_items: false`, and empty metadata, with no OAuth/network.
- A complete remote Reddit success uses replacement and the existing optional
  retention pass in one transaction.
- Any incomplete/failed fetch preserves items and sync state; other sources may
  still succeed.
- Credentials stay in local configuration. Secrets use HTTPS bodies/headers,
  never URLs, SQLite, or metadata.
- V1 stores no bodies, authors, comments, media, raw JSON, or outbound links.

Reddit recommends routinely deleting stored user content/data within 48 hours
and requires deletion when access ends. Operators should set
`retention_ttl_minutes <= 2880`, but this V1 does **not** claim full deletion
compliance during an outage: both snapshot replacement and retention cleanup
are intentionally triggered only by a complete successful remote fetch.
Likewise, configuration removal and explicit user-request/account-termination
deletion have no automatic purge workflow. Those lifecycle mechanisms would
change the approved success-triggered architecture and are recorded as release
and operator compliance caveats in
[quality follow-ups](../../quality-followups.md). Operators remain responsible
for deleting the local database or affected data when their authorization/use
ends.

## Testing strategy

All automated tests use injected clients/transports and local fixtures; none
contacts Reddit.

### HTTP, rate, and client tests

- form POST encoding plus unit-named timeout/body-size defaults;
- whitespace-only, NUL, DEL, and overlength credential/User-Agent rejection;
- streamed oversized response and open/read/write timeout categorization;
- token `token_type`, positive `expires_in`, token/scope, and shape validation;
- separate token and data 401/403 operation/category errors;
- one centralized rate-header parser used for success, non-2xx, and 429;
- two instances sharing a client-ID digest observe one coordinated allowance;
  different identities remain independent and no key is persisted/exposed;
- 90-request bound versus rate admission, plus monotonic deadline exhaustion;
- subscription/unread pagination, expected cursor types, and repeated-cursor
  rejection; and
- qualifying-message filtering before the N quota.

### Activity and identity tests

- exact activity arithmetic, floors, negative clamps, nonnumeric rejection,
  stable ties, megathread matching, and priority endpoints;
- limit 1 category priority; limit >= 2 message/thread guarantee; megathread
  reservation; deterministic fill and selection ranks;
- exact t3/t4/t5 name-ID agreement and subreddit agreement; and
- permalink rejection for mismatches, absolute/network paths, query, fragment,
  controls, encoded separators/controls, backslashes, and traversal, with URL
  construction from validated components.

### Adapter, persistence, and system tests

- complete subscribed discovery and bounded personalized-home coverage;
- outbound explicit calls equal `(includes - excludes) - subscriptions`;
- the same name in include/exclude produces no request;
- post-exclusion `news` behavior and no `+` route under any config;
- body/author/raw-payload minimization and safe metadata;
- only remote success carries unsupported-chat metadata; cache metadata empty;
- default-false `FetchResult` compatibility and strict boolean validation;
- successful replacement delete-before-upsert, empty clearing, rollback on
  upsert/state/history failure, and rejection on cache/failure results;
- Reddit remote replacement, cache/failure preservation, and unchanged
  retention semantics;
- CLI presentation remains recency ordered even though selection rank and
  priority retain Reddit's deterministic order; and
- Reddit failure isolation from a successful source.

The authenticated release smoke test must verify approved scopes, token shape,
subscription/message cursor shapes, the documented `/hot` and
`/r/<name>/hot` fields, rate headers, and the unread-ID/count state check around
`mark=false`. It must also confirm requests never use a `+` multi-subreddit
route. Record only status/shape evidence—never tokens, IDs, messages, titles,
usernames, or memberships.

## Documentation impact

Implementation updates `README.md` with OAuth setup, bounded coverage,
selection/ranking, chat limitation, minimization, retention recommendation, and
operator caveats. `AGENTS.md` gains the implemented Reddit and current-snapshot
invariants. Contract discoveries go to `docs/LEARNINGS.md` only after evidence.

This design follows [ADR 0001](../../adr/0001-persistence-storage-and-write-ownership.md)
and [ADR 0003](../../adr/0003-configurable-item-retention.md). Generic snapshot
replacement is the accepted new decision in
[ADR 0004](../../adr/0004-current-snapshot-item-replacement.md); it does not
alter retention timing or adopt proposed command-adapter ADR 0002.

## Future extensions

- official consumer-chat reading when a documented endpoint and scope exist;
- local OAuth authorization and keychain-backed credential storage;
- cross-process or distributed Reddit rate coordination if deployment expands;
- hard-deadline lifecycle cleanup and targeted user/instance purge workflows;
- exhaustive/delta activity collection and richer configurable category quotas;
- policy-approved LLM summaries; and
- aggregate statistics for the authenticated user's own submissions.
