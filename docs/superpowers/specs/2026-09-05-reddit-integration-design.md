# Reddit Integration Design

**Status:** Approved for implementation planning
**Date:** 2026-09-05

## Summary

Cybort will add a direct-HTTP `reddit` adapter that uses a user-authorized
Reddit OAuth refresh token. One configured Reddit instance will collect two
kinds of normalized `Item`: unread legacy direct messages and selected active
submission threads. It will discover the user's subscribed subreddits, union
them with explicitly included names, subtract explicitly excluded names, and
rank thread candidates with a deterministic engagement-per-age metric.

The adapter will store message subjects and thread titles, Reddit canonical
URLs, timestamps, and small typed metadata. Thread metadata includes Reddit's
visible vote score and comment total. It will not store message bodies,
submission self-text, comment bodies, media, thumbnails, or linked-page
content. LLM summaries and aggregate statistics for the user's own posts are
future work.

Reddit's documented Data API exposes unread private messages but does not
document a consumer-chat read endpoint. V1 therefore collects direct-message
objects from `/message/unread` and reports in fetch metadata that consumer chat
collection is unavailable. It will not scrape Reddit, reuse first-party
credentials, or call undocumented Sendbird/chat endpoints. This is a deliberate
capability boundary, not silent equivalence between private messages and chat.

## Goals

- Show unread Reddit direct messages without marking them read.
- Show highly active threads from the effective subreddit scope.
- Recognize and reserve space for `r/news` megathreads when they are in scope.
- Default the subreddit scope to every subreddit the authenticated user has
  joined, while allowing explicit additions and exclusions.
- Store stable identities, thread titles, canonical Reddit URLs, visible vote
  scores, and comment totals without storing Reddit bodies or comment content.
- Fit the existing adapter, orchestration, cache, persistence, and per-instance
  retention contracts.
- Keep all automated tests offline through injected HTTP clients and local JSON
  fixtures.

## Non-goals

- reading consumer Reddit Chat conversations until Reddit documents and grants
  a supported read interface;
- marking messages read, replying, voting, posting, moderating, or mutating the
  Reddit account;
- collecting inbox comment replies, username mentions, post replies, modmail,
  or Reddit announcements;
- storing message bodies, submission bodies, comments, media, previews,
  thumbnails, outbound linked-page content, or full API payloads;
- LLM summaries, embeddings, classification, or other model calls;
- aggregate statistics for the user's own posts;
- a background scheduler, continuously updated activity rate, or push stream;
- exact vote counts (Reddit exposes a visible/fuzzed submission `score`, not an
  auditable ballot total);
- a Reddit-specific storage table, reconciliation deletion model, or retention
  policy; and
- a built-in interactive OAuth authorization flow in this slice.

## Official API and policy basis

The design was checked on 2026-09-05 against these Reddit-controlled sources:

- the [Reddit Data API Wiki](https://support.reddithelp.com/hc/en-us/articles/16160319875092-Reddit-Data-API-Wiki),
  which requires registered OAuth traffic and a descriptive User-Agent,
  documents a free-access limit of 100 queries per minute per OAuth client ID
  averaged over ten minutes, identifies the rate-limit response headers, and
  describes deletion/retention obligations;
- Reddit's [generated OAuth endpoint reference](https://www.reddit.com/dev/api/oauth),
  which documents `/message/unread` under `privatemessages`,
  `/subreddits/mine/subscriber` under `mysubreddits`, and `/hot` under `read`,
  including fullname/`after` pagination and a maximum listing page size of 100;
- Reddit's [Data API Terms](https://redditinc.com/policies/data-api-terms),
  last revised July 20, 2026, which require documented access information,
  forbid circumventing limits and reverse engineering, restrict retention to
  the approved use case, and require stored material to be deleted when access
  terminates; and
- Reddit's legacy official [OAuth2 documentation](https://github.com/reddit-archive/reddit/wiki/oauth2),
  which documents authorization-code refresh tokens, one-hour access tokens,
  Basic authentication for token exchange, and use of `oauth.reddit.com` for
  bearer requests. Reddit's current Data API Wiki labels legacy resources as
  potentially out of date, so an authenticated contract smoke test remains a
  release gate.

The generated endpoint index includes private-message and modmail APIs but no
consumer-chat read endpoint. Treating chat as unavailable is an inference from
the documented public surface, reinforced by the terms' documented-access and
anti-reverse-engineering rules. A future official chat interface can add a
third source operation without changing `Item` or persistence.

## Approaches considered

### Direct OAuth Data API client — selected

Use the existing injectable `HttpClient`, add form POST support for token
refresh, and put Reddit-specific OAuth/listing mechanics in a small
`RedditClient`. This keeps credentials and protocol behavior out of persistence,
uses Reddit's supported endpoints, and matches the existing RSS/GitHub direct
HTTP adapter pattern.

### External command-backed adapter

Rejected. Reddit does not provide a maintained official CLI that eliminates the
OAuth and API-contract work in the way `gws` does for Gmail. A third-party CLI
would add executable/version/authentication failure modes while still coupling
Cybort to the same Reddit API and terms.

### Browser scraping or undocumented chat endpoints

Rejected. Browser state and private Sendbird/chat calls are brittle, expose
first-party credentials, are not part of the documented Data API contract, and
would conflict with Reddit's access restrictions. The V1 result must be honest
about the unsupported chat capability rather than simulate support.

## Configuration and authentication

A Reddit instance uses existing common keys plus Reddit-specific OAuth and
scope options:

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
nonblank strings. They remain in configuration only: adapter-instance
registration, items, fetch history, errors, and result metadata must never
contain them. Newlines and control characters are rejected. The User-Agent must
match Reddit's documented shape
`<platform>:<app-id>:<version> (by /u/<username>)`; V1 validates that shape so
the generic Ruby/Net::HTTP agent is never sent accidentally.

The user registers an approved Reddit OAuth application and provisions a
permanent authorization-code grant outside Cybort with these three read-only
scopes and no unnecessary additional scopes:

- `read` for thread listings;
- `mysubreddits` for subscribed-subreddit discovery; and
- `privatemessages` for unread private messages.

V1 does not implement browser authorization, callback handling, or storage of a
new refresh token. On every remote fetch, `RedditClient` exchanges the configured
refresh token at `https://www.reddit.com/api/v1/access_token`, using HTTP Basic
authentication with the client ID and secret and a form body containing only
`grant_type=refresh_token` and `refresh_token`. It rejects token responses that
do not contain a nonblank bearer token and at least all three required scopes
(a returned `*` also satisfies the compatibility check). Data requests go only
to `https://oauth.reddit.com` with
that bearer token and the configured User-Agent.

This assumes a confidential OAuth client for which a local single-user process
can keep the client secret. Supporting installed clients with an empty secret,
a system keychain, or a `cybort reddit authorize` command requires a separate
credential-lifecycle design.

`include_subreddits` and `exclude_subreddits` are optional arrays of subreddit
names without an `r/` prefix. Omission means an empty array. Each name must match
`\A[A-Za-z0-9_]{2,21}\z`; names are deduplicated case-insensitively and
normalized to lowercase. An exclusion wins when a name appears in both lists.
Arrays, elements, and their size are validated before threads start. Each list
is limited to 100 names to bound URL and request amplification.

For this adapter, `num_items_to_fetch` must be an integer from 1 through 100.
It is the maximum number of normalized Reddit items returned by one remote
fetch across messages and threads; it remains separate from cache TTL and item
retention.

## Subreddit scope and candidate discovery

The effective subreddit scope is deterministic:

```text
effective = (all subscribed names UNION include_subreddits)
            MINUS exclude_subreddits
```

`RedditClient` requests
`/subreddits/mine/subscriber?limit=100&raw_json=1`, follows the listing's
`data.after` fullname until it is `null`, and reads each child's
`data.display_name`. It must complete discovery before fetching threads; an
invalid page or exhausted request budget fails the whole adapter result instead
of silently treating a partial subscription list as authoritative.

Thread candidates come from bounded hot listings:

1. one authenticated `/hot?limit=100&raw_json=1` page supplies the personalized
   subscribed-home candidates;
2. explicit additions are sorted, divided into batches of at most 25 names, and
   fetched through `/r/name+name/hot?limit=100&raw_json=1`; and
3. when `news` is effective, one `/r/news/hot?limit=100&raw_json=1` page ensures
   the megathread detector sees `r/news` even if the personalized hot page does
   not surface it.

Every returned candidate is filtered against the effective set. This prevents
home-feed recommendations outside joined communities from leaking into the
result and applies exclusions to every candidate source. Candidates are
deduplicated by Reddit link fullname (`t3_...`) before ranking. The adapter does
not paginate hot listings in V1: 100 candidates per listing is the deliberate
scan bound, while `num_items_to_fetch` is the output bound. Candidate coverage
is therefore a current hot sample, not an exhaustive search of every post in
every joined subreddit.

The `+` multi-subreddit path and representative response shapes must be included
in the authenticated release smoke test because the generated endpoint reference
describes the `/r/subreddit/hot` listing generically rather than specifying a
batch-size contract.

## Unread direct messages and chat representation

The adapter requests one
`/message/unread?limit=<num_items_to_fetch>&mark=false&max_replies=0&raw_json=1`
page. It retains only children whose kind/fullname is `t4`; this deliberately
excludes unread comment replies and username mentions returned by the broader
inbox listing. `mark=false` and the absence of any write call guarantee that
collection does not change Reddit read state.

Each direct-message item is normalized as follows:

| `Item` field | Value |
|---|---|
| `canonical_id` | the message fullname, `t4_<id>` |
| `urls` | `https://www.reddit.com/message/messages/<id>` |
| `fetched_at` | the adapter's single fetch timestamp |
| `remote_created_at` | UTC time from `created_utc` |
| `title` | the nonblank `subject`, or `Unread Reddit message` |
| `body` | `nil` |
| `priority` | `100` |
| `action_item` | `true` |
| `info` | `{ kind: "direct_message", unread: true }` |

The author name, body, replies, and raw payload are intentionally not retained.
An invalid fullname or timestamp fails the adapter result rather than creating
an unstable identity.

Fetch metadata includes
`chat_collection: "unsupported_by_documented_data_api"`. No synthetic chat
item is created because that would look like actual inbox data. If Reddit later
documents a consumer-chat read API, chat conversations should use the official
conversation/message ID as the canonical ID, a `kind` distinct from
`direct_message`, and the same body-free minimization policy.

## Thread activity, megathreads, and selection

For every valid `t3` candidate, define:

```text
vote_score = max(Integer(score), 0)
comment_count = max(Integer(num_comments), 0)
age_minutes = max(floor((fetched_at - created_utc) / 60), 60)
engagement_points = vote_score + (2 * comment_count)
activity_score_milli = floor(engagement_points * 60_000 / age_minutes)
```

`activity_score_milli` is an integer estimate of weighted engagement points per
hour. Comments receive weight 2 because this feature is intended to surface
active discussions rather than only highly voted links. The one-hour age floor
prevents unstable division for brand-new or future-skewed timestamps. Negative
or malformed counts are invalid source data; V1 clamps negative integer counts
to zero but fails on nonnumeric values. The metric uses cumulative public fields
and post age, so it is deterministic but not a true recent-comment velocity.

Normal thread candidates sort by this tuple:

```text
activity_score_milli DESC,
comment_count DESC,
vote_score DESC,
created_utc DESC,
fullname ASC
```

An `r/news` candidate is a megathread when its title matches
`/\bmega\s*thread\b|\blive\s+thread\b/i`. The API's `stickied` value is stored
as metadata but does not by itself make an arbitrary sticky post a megathread.
Megathreads use the same activity calculation and stable ordering as other
threads, but selection reserves them ahead of normal threads so a long-running
megathread is not lost solely because its lifetime-normalized score has fallen.

The final output is selected in this order and truncated once:

1. unread direct messages, in Reddit listing order;
2. detected `r/news` megathreads, in activity order; and
3. all remaining thread candidates, in activity order.

If unread messages consume `num_items_to_fetch`, no threads can be returned in
that fetch. This follows the existing meaning of the common source limit and
gives unread personal communication precedence. The adapter still records
candidate/message counts in safe fetch metadata so the truncation is visible.

Thread priority encodes its rank among all ranked thread candidates. For `N`
candidates and zero-based `rank_index`, use:

```text
priority = 99 - floor(rank_index * 99 / max(N - 1, 1))
```

Thus thread priorities range from 99 to 0, while unread messages remain 100.
Selection order, `priority`, and the exact integer activity score are all
deterministic. Cybort's current CLI still reads durable items in recency order;
consumers use `priority` or `info.activity_score_milli` when they need activity
order. Changing global CLI ordering is outside this adapter slice.

Each selected thread becomes:

| `Item` field | Value |
|---|---|
| `canonical_id` | Reddit link fullname, `t3_<id>` |
| `urls` | one absolute `https://www.reddit.com<permalink>` URL |
| `fetched_at` | the adapter's single fetch timestamp |
| `remote_created_at` | UTC time from `created_utc` |
| `title` | submission `title` |
| `body` | `nil` |
| `priority` | rank-derived integer from 99 through 0 |
| `action_item` | `false` |
| `info` | `kind`, `subreddit`, `vote_score`, `comment_count`, `activity_score_milli`, `megathread`, and `stickied` |

The adapter never copies `selftext`, `selftext_html`, comment data, author data,
media, thumbnails, or outbound submission URL into an item or fetch metadata.
The canonical URL is always the Reddit permalink, not the user-supplied link.

## Components and ownership

### `HttpClient` and `HttpError`

The generic client gains form-encoded POST support. Both GET and POST retain
the current 2xx-only contract. A new `HttpError` carries only allowlisted safe
metadata: status, parsed `Retry-After`, and parsed Reddit rate-limit fields. It
never includes response bodies, request headers, form bodies, authorization
values, or full URLs.

### `RedditClient`

This source client owns token refresh, bearer/User-Agent headers, query
encoding, JSON object validation, listing pagination, request-budget accounting,
and rate-header collection. It does not know about `Item`, activity ranking,
retention, SQLite, or the orchestrator.

### `RedditActivity`

A small pure module owns the candidate value object, megathread predicate,
integer activity score, stable sort key, and rank-to-priority mapping. It has no
network or clock side effects, which makes the metric independently testable.

### `Adapters::Reddit`

The adapter validates Reddit-specific options, asks `RedditClient` for source
listings, computes the effective scope, filters and deduplicates candidates,
normalizes selected records, and returns the existing `FetchResult` shape via
`Adapters::Base`. It owns no SQL and makes no account mutations.

### Existing orchestration and persistence

`AdapterRegistry.default` registers `reddit`; no executable dependency is
declared. The orchestrator continues to decide cached versus remote once,
fetch adapter instances concurrently, snapshot retention, and persist results
sequentially. `Persistence#write_fetch_result` receives ordinary items and the
existing optional `retention_ttl_minutes`; no schema or transaction change is
needed.

## Request budget, rate limits, and errors

One remote adapter fetch has a hard budget of 90 Reddit HTTP requests, including
the token exchange. Subscription pages and explicit-include batches consume
that budget. `RedditClient` checks the budget before each request. Exceeding it
raises a source error and discards the partial remote result.

After every successful response, it reads rate-limit headers
case-insensitively and retains the latest valid numeric values in fetch
metadata as `ratelimit_used`, `ratelimit_remaining`, and
`ratelimit_reset_seconds`. If Reddit reports remaining capacity below 1 before
the fetch is complete, the next request fails locally rather than sleeping an
adapter thread or deliberately exceeding the limit.

HTTP 401/403 responses become authentication/authorization source failures.
HTTP 429 includes only parsed status and `retry_after_seconds` in safe failure
metadata. Other non-2xx responses, malformed JSON, unexpected listing shapes,
missing required source fields, and incomplete subscription discovery fail the
whole Reddit result. V1 performs no automatic retries: orchestration records a
per-instance failure and keeps last-known-good data, while other configured
sources continue.

Safe successful metadata contains only counts, request count, chat capability,
and rate numbers. It contains no subreddit list, message subject, post title,
username, token, client credential, HTTP body, or authorization header.

## Cache, failure, and retention behavior

The Reddit adapter uses `Adapters::Base` unchanged:

- a fresh cache returns persisted Reddit items without OAuth or network access;
- `--force-fetch` always attempts token refresh and remote reads;
- a remote success returns selected items and is persisted in one existing
  per-instance transaction;
- a remote, OAuth, policy, rate-limit, parsing, or persistence failure records a
  failed fetch and preserves the prior Reddit items and synchronization state;
  and
- one Reddit failure does not discard successful results from other sources.

`num_items_to_fetch` limits only the current returned selection. Items selected
by earlier successful runs remain stored under the existing append/upsert
model. The existing optional `retention_ttl_minutes` is the only local cleanup
mechanism: after a successful remote fetch, persistence refreshes returned
items' local `fetched_at` and prunes unseen items at or before the configured
last-seen cutoff. Cache hits and failures do not prune. Omission still means
retain forever.

Reddit requires deletion of removed content and recommends routinely deleting
stored user content/data within 48 hours. A value no greater than 2880 minutes
is therefore strongly recommended for Reddit instances, but the current
success-triggered retention model cannot guarantee a wall-clock deletion bound
during outages and does not prove remote deletion for an item outside the
bounded candidate sample. V1 minimizes this exposure by storing no bodies,
authors, or raw payloads. Operators remain responsible for the current Reddit
terms, deleting the local database when access terminates, and choosing a
retention setting appropriate to their approved use. A compliance API or
authoritative deletion reconciliation feed would require a separate design.

## Privacy and security

- Credentials live in the user's local configuration, consistent with the
  existing GitHub token convention, and are never persisted to SQLite.
- Token exchange uses a form body over HTTPS; secrets never appear in URLs.
- Errors and metadata are allowlisted and body-free.
- Only the minimum read scopes are requested; there are no Reddit write calls.
- Direct-message and submission bodies, authors, comments, and raw source JSON
  are not stored.
- Canonical URLs are constructed from source IDs/permalinks under
  `https://www.reddit.com`; arbitrary source URLs are not trusted.
- The local database still contains potentially sensitive subjects and titles;
  filesystem access controls and backups remain the user's responsibility.

## Testing strategy

All tests use local JSON fixtures and injected fake transports/clients. They
must not contact Reddit or perform an OAuth flow.

### HTTP and Reddit client tests

- form POST encoding, content type, Basic header delegation, and 2xx response;
- safe non-2xx metadata without bodies, credentials, or authorization values;
- token response validation and required-scope enforcement;
- bearer/User-Agent headers and `raw_json=1` query encoding;
- fullname pagination through `data.after`, including a malformed later page;
- request-budget exhaustion and rate-header parsing; and
- 401, 403, and 429 categorization with last-known-good-safe metadata.

### Activity tests

- exact integer scores at the one-hour floor and at older ages;
- comment weighting, negative-count clamping, and nonnumeric rejection;
- deterministic tie breakers;
- `r/news` megathread and live-thread title recognition without classifying an
  unrelated sticky; and
- priority endpoints for one and multiple ranked candidates.

### Adapter tests

- required OAuth/User-Agent configuration and subreddit-list validation;
- complete subscribed-subreddit pagination;
- union/add/exclude precedence and case-insensitive deduplication;
- filtering home-feed recommendations outside effective scope;
- batching explicit additions and the dedicated `r/news` hot request;
- `t4`-only unread direct-message normalization without bodies/authors;
- thread normalization with canonical Reddit URL, vote/comment totals, metric,
  and `body: nil`;
- message, megathread, then activity selection under one output limit;
- duplicate candidates from multiple listings appearing once;
- source failure on malformed IDs, timestamps, listing shapes, or token scopes;
  and
- safe successful/failure metadata.

### Integration and system tests

- default-registry Reddit registration and offline fake HTTP responses;
- a forced CLI fetch persists and presents direct messages and ranked threads;
- a fresh-cache CLI run makes no OAuth or Reddit request;
- a later OAuth/429 failure preserves earlier Reddit items;
- configured retention prunes an unseen Reddit item only after a successful
  remote fetch; and
- Reddit failure remains isolated from a successful RSS instance.

An authenticated manual release smoke test must separately verify an approved
application, the three scopes, token refresh, two subscription pages when
available, `/message/unread?mark=false`, authenticated `/hot`, a `+`-joined
explicit listing, `r/news` hot data, relevant response fields, and rate-limit
headers. Record only versions/statuses/shapes; never record tokens, messages,
titles, usernames, or subreddit membership.

## Documentation impact

Implementation updates `README.md` with setup, the chat limitation, scope
semantics, ranking formula, data minimization, recommended retention, and an
example. `AGENTS.md` gains the implemented Reddit invariant and authenticated
smoke-test gate. If the smoke test exposes a contract mismatch, record it in
`docs/LEARNINGS.md`; do not weaken validation from speculation.

No ADR is required for this feature. It follows
[ADR 0001](../../adr/0001-persistence-storage-and-write-ownership.md) and
[ADR 0003](../../adr/0003-configurable-item-retention.md) without changing
their decisions, and it does not adopt the command-backed connector decision in
proposed ADR 0002.

## Future extensions

- an official consumer-chat reader, gated on a documented Reddit endpoint and
  approved scopes;
- a local OAuth authorization command and keychain-backed credential store;
- delta-based activity velocity using previously observed vote/comment totals;
- configurable category quotas when users need guaranteed thread slots despite
  a large unread-message backlog;
- richer deletion/compliance reconciliation if Reddit exposes an authoritative
  mechanism;
- LLM summaries that first resolve Reddit policy, rights, and data-minimization
  requirements; and
- aggregate statistics for the authenticated user's own submissions.
