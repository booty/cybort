# Reddit Integration Implementation Plan

> **For Luna:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an offline-tested direct OAuth Reddit adapter that replaces its complete current bounded selection of unread legacy messages and active threads without storing Reddit body content.

**Architecture:** Extend `FetchResult` with a generic opt-in current-snapshot flag and keep delete/upsert/retention/state/history inside persistence's existing per-result transaction. Add a bounded HTTP boundary, centralized safe rate parsing, a process-wide client-identity rate coordinator, a Reddit OAuth/listing client, and a pure ranking/selection module. `Adapters::Reddit` composes those parts; the orchestrator and SQLite schema stay unchanged.

**Tech Stack:** Ruby 4.0.1, Net::HTTP, JSON, URI, Digest, Base64, SQLite3, TOML, Minitest

**Spec:** `docs/superpowers/specs/2026-09-05-reddit-integration-design.md`

**Accepted decision:** `docs/adr/0004-current-snapshot-item-replacement.md`

## Global constraints

- Use only documented Reddit OAuth endpoints. Never construct a `+`
  multi-subreddit path or call undocumented chat APIs.
- Validate stripped emptiness, byte length, and every C0/DEL control in
  credentials and User-Agent before any network call.
- Required scopes are `read`, `mysubreddits`, and `privatemessages`.
- Treat joined coverage as one bounded authenticated-home sample. Only explicit
  additions and post-exclusion `news` receive documented `/r/<name>/hot` calls.
- Paginate subscribed listings completely. Paginate unread listings in pages
  of 100 and filter qualifying legacy private messages before applying quota.
- Validate fullnames, cursor types, subreddit identity, and permalink structure;
  construct canonical URLs from validated components.
- The 90-request value is a per-fetch complexity bound, not Reddit-wide rate
  compliance. Coordinate same-client instances process-wide from response
  headers and 429s, subject to one monotonic 120-second fetch deadline.
- A limit of at least 2 returns both a message and a thread when both exist and
  reserves an available `r/news` megathread under that bound. Limit 1 uses
  message, megathread, ordinary-thread priority.
- Reddit complete remote successes set `replace_existing_items: true`; cache
  hits and all failures leave it false. Replacement is generic persistence
  behavior and shares the existing transaction and rollback boundary.
- Preserve `retention_ttl_minutes`: only successful remote writes prune; cache
  hits and failures do not. Do not claim hard expiry during outages.
- Do not add a storage table, Reddit-specific SQL, a global CLI-order change,
  external-service tests, or production support for LLM summaries/statistics.
- Never persist/expose credentials, access tokens, response bodies, raw source
  objects, authors, usernames, membership lists, or client-ID digests.

---

## Exact file map

| File | Action and responsibility |
|---|---|
| `lib/cybort/rate_limit_headers.rb` | **Create:** central case-insensitive parser for safe Reddit rate headers. |
| `test/rate_limit_headers_test.rb` | **Create:** valid, invalid, nonfinite, negative, and casing parser tests. |
| `lib/cybort/errors.rb` | **Modify:** add body-free `HttpError`, `HttpTransportError`, and `RedditApiError`. |
| `test/errors_test.rb` | **Modify:** assert allowlisted operation/category/status/rate metadata only. |
| `lib/cybort/http_client.rb` | **Modify:** add form POST, open/read/write timeout units, deadline cap, and streamed maximum-body enforcement. |
| `test/http_client_test.rb` | **Modify:** form, GET compatibility, timeout, oversized-body, and safe-error tests. |
| `lib/cybort/reddit_rate_limit_coordinator.rb` | **Create:** process-wide, SHA-256-client-keyed admission and header/429 observation. |
| `test/reddit_rate_limit_coordinator_test.rb` | **Create:** shared-client serialization, different-client independence, reset/deadline, and secret-safety tests. |
| `lib/cybort/fetch_result.rb` | **Modify:** add strict `replace_existing_items` boolean with default false. |
| `test/fetch_result_test.rb` | **Modify:** default, success opt-in, failure, and invalid-value tests. |
| `lib/cybort/adapters/base.rb` | **Modify:** propagate a remote adapter's generic snapshot-completeness flag; cache/failure results remain false. |
| `test/adapters/base_test.rb` | **Modify:** prove remote opt-in propagation and cache/failure defaults. |
| `lib/cybort/persistence.rb` | **Modify:** atomically validate, replace, upsert, retain, update state, and record history. |
| `test/persistence_test.rb` | **Modify:** replacement order, empty clear, invalid result, retention composition, and rollback tests. |
| `lib/cybort/reddit_client.rb` | **Create:** OAuth validation, listing requests/pagination, cursor checks, request bound, coordinator use, and monotonic deadline. |
| `test/reddit_client_test.rb` | **Create:** token/data operations, 401/403, pagination, deadline, rate, and request-path tests. |
| `lib/cybort/reddit_activity.rb` | **Create:** validated candidate value, exact metric/ties, megathread detection, priority, and bounded selection. |
| `test/reddit_activity_test.rb` | **Create:** arithmetic, validation, stable ranking, category guarantees, and selection rank tests. |
| `lib/cybort/adapters/reddit.rb` | **Create:** option/identity validation, scope calls, normalization, safe metadata, and complete-snapshot result. |
| `test/adapters/reddit_test.rb` | **Create:** config, calls, exclusions, identity/URL attacks, selection, content minimization, and cache metadata tests. |
| `test/fixtures/reddit/token.json` | **Create:** sanitized valid bearer response. |
| `test/fixtures/reddit/subscriptions_page_1.json` | **Create:** valid t5 page and next cursor. |
| `test/fixtures/reddit/subscriptions_page_2.json` | **Create:** final subscription page. |
| `test/fixtures/reddit/unread_page_1.json` | **Create:** unrelated unread objects plus valid t4 message and cursor. |
| `test/fixtures/reddit/unread_page_2.json` | **Create:** enough valid t4 messages to prove post-filter quota. |
| `test/fixtures/reddit/home_hot.json` | **Create:** in-scope t3 candidates plus out-of-scope recommendation. |
| `test/fixtures/reddit/included_hot.json` | **Create:** explicit-subreddit candidate and duplicate. |
| `test/fixtures/reddit/news_hot.json` | **Create:** news megathread and unrelated sticky. |
| `lib/cybort/adapter_registry.rb` | **Modify:** register direct HTTP `reddit` adapter without executable dependency. |
| `lib/cybort.rb` | **Modify:** require new modules in dependency order. |
| `test/adapter_registry_test.rb` | **Modify:** default registration and aggregate config-error tests. |
| `test/system/cli_system_test.rb` | **Modify:** remote replacement, cache/failure preservation, recency display, retention, and source isolation. |
| `README.md` | **Modify:** setup, bounded coverage, selection, chat limitation, privacy, and compliance caveats. |
| `AGENTS.md` | **Modify:** record implemented Reddit/snapshot invariants and smoke-test gate. |
| `docs/LEARNINGS.md` | **Conditional modify:** only record evidence if the authenticated smoke test is actually run. |

No change is planned for `lib/cybort/item.rb`, `lib/cybort/orchestrator.rb`,
`lib/cybort/schema.rb`, or existing ADR text.

---

### Task 1: Centralize safe rate parsing and bounded HTTP behavior

**Files:**
- Create: `lib/cybort/rate_limit_headers.rb`
- Create: `test/rate_limit_headers_test.rb`
- Modify: `lib/cybort/errors.rb`
- Modify: `test/errors_test.rb`
- Modify: `lib/cybort/http_client.rb`
- Modify: `test/http_client_test.rb`

**Interfaces:**

```ruby
RateLimitHeaders.parse(headers)
# => { retry_after_seconds:, ratelimit_used:, ratelimit_remaining:,
#      ratelimit_reset_seconds: } with invalid keys omitted

HttpClient.new(
  transport:,
  open_timeout_seconds: 10,
  read_timeout_seconds: 30,
  write_timeout_seconds: 30,
  max_response_body_bytes: 1_048_576
)
HttpClient#get(url, headers: {}, timeout_seconds: nil)
HttpClient#post_form(url, form:, headers: {}, timeout_seconds: nil)
```

- [ ] **Step 1: Write rate-parser and error tests**

Create `test/rate_limit_headers_test.rb` with exact expectations:

```ruby
def test_parses_case_insensitive_safe_values
  parsed = Cybort::RateLimitHeaders.parse(
    "X-Ratelimit-Used" => "3.5",
    "x-ratelimit-remaining" => "0",
    "X-RATELIMIT-RESET" => "42.25",
    "Retry-After" => "7"
  )
  assert_equal 3.5, parsed.fetch(:ratelimit_used)
  assert_equal 0.0, parsed.fetch(:ratelimit_remaining)
  assert_equal 42.25, parsed.fetch(:ratelimit_reset_seconds)
  assert_equal 7, parsed.fetch(:retry_after_seconds)
end

def test_omits_negative_nonfinite_and_http_date_values
  parsed = Cybort::RateLimitHeaders.parse(
    "x-ratelimit-used" => "NaN",
    "x-ratelimit-remaining" => "-1",
    "x-ratelimit-reset" => "Infinity",
    "retry-after" => "Wed, 21 Oct 2015 07:28:00 GMT"
  )
  assert_empty parsed
end
```

Add to `test/errors_test.rb` separate safe contracts for:

```ruby
http = Cybort::HttpError.new(status: 429, headers: {
  "retry-after" => "5", "authorization" => "Bearer secret"
})
assert_equal({ status: 429, retry_after_seconds: 5 }, http.safe_metadata)

api = Cybort::RedditApiError.new(
  operation: :subscriptions,
  category: :authorization,
  status: 403,
  rate_metadata: { ratelimit_remaining: 0.0 }
)
assert_equal :subscriptions, api.safe_metadata.fetch(:operation)
assert_equal :authorization, api.safe_metadata.fetch(:category)
refute_includes api.safe_metadata.to_s, "secret"
```

Also assert `RedditApiError#message` is a constant/allowlisted rendering that
does not include an injected token, response body, title, or URL. In an
adapter/system test, inject each sentinel into malformed JSON and transport
failures and assert the sentinel is absent from the failure result JSON and the
persisted `fetch_runs.error_message`, not only from `safe_metadata`.

- [ ] **Step 2: Write HTTP form, timeout, and size tests**

Extend the fake transport to capture all unit-named values. Add tests proving:

```ruby
client.post_form(
  "https://www.reddit.com/api/v1/access_token",
  form: { grant_type: "refresh_token", refresh_token: "a+b secret" },
  headers: { "Authorization" => "Basic opaque" },
  timeout_seconds: 4.5
)
assert_equal 4.5, transport.calls.last.fetch(:timeout_seconds)
refute_includes transport.calls.last.fetch(:url), "secret"
```

Also simulate an incremental body over 1,048,576 bytes and each Net::HTTP
open/read/write timeout. Assert `HttpTransportError#safe_metadata` is exactly
`{ category: :response_too_large }` or `{ category: :timeout }`; no body or URL
is present. Keep an existing GET success test unchanged.

- [ ] **Step 3: Run focused tests; verify RED**

```bash
bundle exec ruby -Itest test/rate_limit_headers_test.rb
bundle exec ruby -Itest test/errors_test.rb
bundle exec ruby -Itest test/http_client_test.rb
```

Expected: failures for missing parser/errors/form/timeouts.

- [ ] **Step 4: Implement the smallest shared boundary**

In `rate_limit_headers.rb`, lowercase keys once, accept only finite
nonnegative `Float` rate values, accept `Retry-After` only with
`\A\d+\z`, and freeze the returned hash. Make `HttpError` call this parser;
do not duplicate parsing in errors or Reddit code.

In `http_client.rb`, keep 2xx enforcement above both verbs, URI-encode form
data, set `application/x-www-form-urlencoded`, configure Net::HTTP with the
three timeout values capped by positive `timeout_seconds`, and accumulate
response chunks only until the byte maximum. Map transport timeout classes to
the safe transport error.

- [ ] **Step 5: Run focused tests; verify GREEN**

Run the three commands from Step 3. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/cybort/rate_limit_headers.rb test/rate_limit_headers_test.rb lib/cybort/errors.rb test/errors_test.rb lib/cybort/http_client.rb test/http_client_test.rb
git commit -m "feat: bound HTTP transport and parse rate limits"
```

---

### Task 2: Add process-wide Reddit rate admission

**Files:**
- Create: `lib/cybort/reddit_rate_limit_coordinator.rb`
- Create: `test/reddit_rate_limit_coordinator_test.rb`
- Modify: `lib/cybort.rb`

**Interface:**

```ruby
coordinator = RedditRateLimitCoordinator.default
test_coordinator = RedditRateLimitCoordinator.new(clock:, sleeper:)
key = coordinator.key_for(client_id) # in-memory SHA-256 digest
lease = coordinator.acquire(key:, deadline_monotonic:)
lease.observe(metadata:, status: nil)
lease.release
```

- [ ] **Step 1: Write deterministic fake-clock tests**

Cover two client objects sharing `client_id: "same"`:

```ruby
shared_key = coordinator.key_for("same")
initial = coordinator.acquire(key: shared_key, deadline_monotonic: 20.0)
initial.observe(metadata: {
  ratelimit_remaining: 1.0,
  ratelimit_reset_seconds: 10.0
})
initial.release
lease = coordinator.acquire(key: shared_key, deadline_monotonic: 20.0)
assert_raises(Cybort::RedditApiError) do
  coordinator.acquire(key: shared_key, deadline_monotonic: 5.0)
end
lease.observe(metadata: { ratelimit_remaining: 0.0,
                          ratelimit_reset_seconds: 10.0 })
lease.release
```

Assert the second same-key caller is not admitted while the first lease is in
flight, then its deadline yields `rate_limited`; a reset releases the shared
key; another client-ID digest remains independent; and a 429 plus
`retry_after_seconds: 7` blocks same-key admission. Assert an ensured release
after a transport exception avoids deadlock without inventing capacity. Neither
plaintext nor digest may occur in errors or a persistence-facing value. Use a
fake sleeper that advances the monotonic clock; never sleep in tests.

- [ ] **Step 2: Run and verify RED**

```bash
bundle exec ruby -Itest test/reddit_rate_limit_coordinator_test.rb
```

- [ ] **Step 3: Implement mutex-protected process state**

Use `Digest::SHA256.digest(client_id)` as an opaque hash key and expose a
mutex-protected `.default` singleton for production construction. Store only
remaining capacity, an absolute monotonic reset instant, and one in-flight flag
per key. `acquire` waits for the prior same-key lease, then reserves one unit
atomically. On known exhaustion, wait no later than the reset and caller
deadline; raise `rate_limited` instead of overrunning the deadline. The lease's
`observe` replaces state from valid centralized parsed headers and applies 429
`Retry-After`; `release` signals waiters and is idempotent. Do not expose state
in fetch metadata.

- [ ] **Step 4: Run and verify GREEN**

```bash
bundle exec ruby -Itest test/reddit_rate_limit_coordinator_test.rb
```

- [ ] **Step 5: Commit**

```bash
git add lib/cybort/reddit_rate_limit_coordinator.rb test/reddit_rate_limit_coordinator_test.rb lib/cybort.rb
git commit -m "feat: coordinate Reddit rate limits per client"
```

---

### Task 3: Implement generic current-snapshot replacement

**Files:**
- Modify: `lib/cybort/fetch_result.rb`
- Modify: `test/fetch_result_test.rb`
- Modify: `lib/cybort/adapters/base.rb`
- Modify: `test/adapters/base_test.rb`
- Modify: `lib/cybort/persistence.rb`
- Modify: `test/persistence_test.rb`

- [ ] **Step 1: Lock down the result value contract**

Add tests equivalent to:

```ruby
assert_equal false, successful_result.replace_existing_items

snapshot = Cybort::FetchResult.success(
  instance_id: "reddit",
  items: [],
  sync_state: {},
  started_at: NOW,
  finished_at: NOW,
  metadata: {},
  source_fetched: true,
  replace_existing_items: true
)
assert_equal true, snapshot.replace_existing_items

failure = Cybort::FetchResult.failure(
  instance_id: "reddit", error: error,
  started_at: NOW, finished_at: NOW
)
assert_equal false, failure.replace_existing_items

attributes = successful_result.to_h.merge(replace_existing_items: nil)
assert_raises(ArgumentError) { Cybort::FetchResult.new(**attributes) }
```

Exercise direct construction with an omitted field, `nil`, `0`, and `"true"`;
omission becomes false and strict validation otherwise accepts only the two
Boolean singletons. A direct error-bearing result with replacement true is
invalid; the failure factory always supplies false.

In `test/adapters/base_test.rb`, make the stub source return
`replace_existing_items: true` and assert the remote result propagates true.
Assert its cached result and rescued failure both expose false. This is the
generic adapter-to-result bridge; do not special-case Reddit in base.

- [ ] **Step 2: Write transaction behavior tests**

Seed `old-a` and `old-b`, then write a replacement containing refreshed
`old-b` plus `new-c`. Assert the stored canonical IDs are exactly
`["new-c", "old-b"]`. An empty replacement leaves no items. A default-false
success continues to upsert without removing `old-a`.

Add rejection tests for `replace_existing_items: true` with
`source_fetched: false` and with an unsuccessful result. Add a combined
replacement+retention test using the existing injected persistence clock to
prove retention still executes with its prior cutoff semantics.

Mutate a constructed result's public struct field to `"true"` immediately
before persistence and assert `ValidationError`. This proves persistence
independently enforces the Boolean even if a caller bypasses construction-time
validation.

For rollback, inject/induce failures at upsert, state update, and history
insertion after the delete. After each raised error, open a new read and assert
both seeded rows and prior sync/history remain unchanged.

- [ ] **Step 3: Run and verify RED**

```bash
bundle exec ruby -Itest test/fetch_result_test.rb
bundle exec ruby -Itest test/persistence_test.rb
```

- [ ] **Step 4: Add the field and delete-before-upsert order**

Append `:replace_existing_items` to the struct. Override initialization to
supply false when the keyword is omitted and perform the strict Boolean/error
combination checks. The success factory accepts an optional false-defaulted
flag; the failure factory exposes no such argument and sets false. In the base
adapter's remote-success construction, pass
`replace_existing_items: fetched.fetch(:replace_existing_items, false)`.

In `write_fetch_result`, independently require the field to be exactly true or
false, validate all items before mutation, and reject replacement unless
`source_fetched` is true. Then execute inside the existing transaction:

```ruby
@database.execute(
  "DELETE FROM items WHERE instance_id = ?",
  [result.instance_id]
) if result.replace_existing_items

result.items.each { |item| upsert_item(item) }
if retention_ttl_minutes
  cutoff = successful_fetch_at - (retention_ttl_minutes * 60)
  prune_expired_items(instance_id: result.instance_id, cutoff: cutoff)
end
update_instance_state(
  result,
  last_successful_fetch: successful_fetch_at,
  updated_at: persistence_now
)
insert_fetch_run(result, "successful")
```

Use the repository's actual private method names/signatures. Do not interpolate
the ID, add adapter checks, or change schema.

- [ ] **Step 5: Run focused tests and the existing orchestrator tests**

```bash
bundle exec ruby -Itest test/fetch_result_test.rb
bundle exec ruby -Itest test/adapters/base_test.rb
bundle exec ruby -Itest test/persistence_test.rb
bundle exec ruby -Itest test/orchestrator_test.rb
```

Expected: PASS, including existing retention/cache/failure behavior.

- [ ] **Step 6: Commit**

```bash
git add lib/cybort/fetch_result.rb test/fetch_result_test.rb lib/cybort/adapters/base.rb test/adapters/base_test.rb lib/cybort/persistence.rb test/persistence_test.rb
git commit -m "feat: replace complete source snapshots atomically"
```

---

### Task 4: Build the deadline-aware Reddit OAuth/listing client

**Files:**
- Create: `lib/cybort/reddit_client.rb`
- Create: `test/reddit_client_test.rb`
- Modify: `lib/cybort.rb`

**Interface:**

```ruby
client = RedditClient.new(
  http_client:,
  coordinator:,
  clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
  deadline_seconds: 120,
  request_limit: 90
)
session = client.authenticate(client_id:, client_secret:, refresh_token:, user_agent:)
client.each_subscription_page(session:) { |children| ... }
client.each_unread_page(session:) { |children| ... }
client.home_hot(session:)
client.subreddit_hot(session:, subreddit:, operation: :subreddit_hot)
client.safe_metadata
```

`authenticate` begins one bounded fetch session: it resets the request counter,
120-second monotonic deadline, safe metadata, and token state. Listing methods
require that session and reject use after its deadline. A second sequential
`authenticate` on the same injected client starts a new session; concurrent
sessions on one client are rejected. The coordinator must not hold its mutex
while waiting or sleeping.

- [ ] **Step 1: Write separate token-response contract tests**

Assert the token call uses Basic authentication, form data, User-Agent, and no
secret in its URL. Valid fixture fields are:

```json
{"access_token":"test-access","token_type":"bearer","expires_in":3600,"scope":"read mysubreddits privatemessages"}
```

Reject blank token, `token_type: "mac"`, zero/negative/nonnumeric/nonfinite
`expires_in`, missing scope, malformed JSON, or non-object JSON. Accept
case-insensitive `Bearer` and scope `*`.

Token HTTP 401 and 403 must produce respectively:

```ruby
{ operation: :token, category: :authentication, status: 401 }
{ operation: :token, category: :authorization, status: 403 }
```

- [ ] **Step 2: Write data-operation, path, and cursor tests**

Assert exact paths contain only:

```text
/subreddits/mine/subscriber?limit=100&raw_json=1
/message/unread?limit=100&mark=false&max_replies=0&raw_json=1
/hot?limit=100&raw_json=1
/r/news/hot?limit=100&raw_json=1
```

Assert every data request has bearer/User-Agent headers. Assert no captured URL
contains `+`. Follow subscription `after: "t5_next"` and unread
`after: "t4_next"`; reject wrong prefixes, malformed base36, query/control
characters, and repeated non-nil cursors. Data 401/403 must keep the requested
operation (`:subscriptions`, `:unread_messages`, `:home_hot`,
`:subreddit_hot`, or `:news_hot`) and proper category.

- [ ] **Step 3: Write rate, request-bound, timeout, and deadline tests**

Use fake monotonic time and coordinator. Assert each request acquires its
same-client lease before HTTP, observes centrally parsed headers afterward
(including on 429), and releases in an ensure path. Assert
request 91 fails with `category: :request_budget`. Advance time to exactly 120
seconds during pagination and assert `category: :deadline`, no partial return,
and no next request. Assert the HTTP call receives the positive remaining
deadline as `timeout_seconds`. Map transport timeout/oversize categories into
the operation-specific `RedditApiError` without copying response data.
Authenticate twice sequentially and assert both sessions receive independent
request budgets/deadlines; attempt concurrent reuse and assert a safe
validation error. Use two client identities while one coordinator lease waits
to prove the coordinator mutex is not held during sleep.

- [ ] **Step 4: Run and verify RED**

```bash
bundle exec ruby -Itest test/reddit_client_test.rb
```

- [ ] **Step 5: Implement one request gateway**

All token/data calls must pass through one private gateway that:

1. checks the 90-request counter and monotonic deadline;
2. acquires a coordinator lease with the SHA-256 identity key;
3. passes remaining seconds to `HttpClient`;
4. centrally parses and observes rate metadata on success/`HttpError`, then
   releases the lease in `ensure`;
5. converts status 401/403/429 and transport failures into an operation-aware
   `RedditApiError`; and
6. checks deadline again before returning parsed data.

Listing helpers validate `kind`, `data.children` array, and `data.after`. Keep
subscription and unread cursor-prefix contracts distinct. Query strings must
use URI encoding. Never accept a caller-supplied path.

- [ ] **Step 6: Run and verify GREEN**

```bash
bundle exec ruby -Itest test/reddit_client_test.rb
bundle exec ruby -Itest test/http_client_test.rb
bundle exec ruby -Itest test/reddit_rate_limit_coordinator_test.rb
```

- [ ] **Step 7: Commit**

```bash
git add lib/cybort/reddit_client.rb test/reddit_client_test.rb lib/cybort.rb
git commit -m "feat: add bounded Reddit OAuth client"
```

---

### Task 5: Implement deterministic activity and bounded category selection

**Files:**
- Create: `lib/cybort/reddit_activity.rb`
- Create: `test/reddit_activity_test.rb`
- Modify: `lib/cybort.rb`

- [ ] **Step 1: Write exact score/rank tests**

At a fixed fetch time, assert:

```ruby
assert_equal 240_000, score(votes: 100, comments: 70, age_minutes: 60)
assert_equal 120_000, score(votes: 100, comments: 70, age_minutes: 120)
assert_equal 0, score(votes: -2, comments: -3, age_minutes: 60)
```

Reject strings, nils, nonfinite timestamps, and malformed candidates. Assert
the complete tie order: score, comments, votes, created time, fullname. Test
`Megathread`, `mega thread`, and `LIVE THREAD` in `news`; reject an unrelated
sticky and matching text outside `news`. Assert one candidate priority 99 and
multi-candidate endpoints 99/0.

- [ ] **Step 2: Write the selection matrix**

Use identities `m1/m2`, `g1/g2`, `t1/t2` and assert:

```ruby
assert_equal %w[m1], select(limit: 1, messages: %w[m1], megas: %w[g1], threads: %w[t1])
assert_equal %w[g1], select(limit: 1, messages: [], megas: %w[g1], threads: %w[t1])
assert_equal %w[m1 t1], select(limit: 2, messages: %w[m1 m2], megas: [], threads: %w[t1])
assert_equal %w[m1 g1], select(limit: 2, messages: %w[m1], megas: %w[g1], threads: %w[t1])
assert_equal %w[g1 t1], select(limit: 2, messages: [], megas: %w[g1], threads: %w[t1])
assert_equal %w[m1 g1 m2 t1], select(limit: 4, messages: %w[m1 m2], megas: %w[g1], threads: %w[t1 t2])
```

Assert final one-based `selection_rank` matches emitted order and duplicates are
not emitted.

- [ ] **Step 3: Run and verify RED**

```bash
bundle exec ruby -Itest test/reddit_activity_test.rb
```

- [ ] **Step 4: Implement the pure module from the spec formulas**

Use integer arithmetic only. Keep activity rank separate from final selection
rank. Do not read a clock inside this module; require the adapter's fetch time.
Implement reservation first, then category-order fill, so guarantees do not
depend on incidental concatenation/truncation.

- [ ] **Step 5: Run and verify GREEN; commit**

```bash
bundle exec ruby -Itest test/reddit_activity_test.rb
git add lib/cybort/reddit_activity.rb test/reddit_activity_test.rb lib/cybort.rb
git commit -m "feat: rank and select Reddit activity"
```

---

### Task 6: Add fixtures and the Reddit adapter configuration boundary

**Files:**
- Create: all eight `test/fixtures/reddit/*.json` files in the file map
- Create: `lib/cybort/adapters/reddit.rb`
- Create: `test/adapters/reddit_test.rb`
- Modify: `lib/cybort.rb`

- [ ] **Step 1: Add minimized fixtures**

Each fixture contains only fields the adapter consumes. Use synthetic IDs,
subjects, titles, subreddits, times, scores, comments, stickied, and permalinks;
include no real account data, bodies, authors, media, or outbound URLs. Make
unread page 1 contain enough nonqualifying `t1`/announcement/comment shapes to
prove they do not consume the message quota; page 2 supplies qualifying t4s.

- [ ] **Step 2: Write exhaustive config-validation tests**

For every credential and User-Agent, test `"   "`, a value containing `"\0"`,
one containing `"\u007f"`, and one byte over its 256/1024/4096/256 limit.
Assert no client call occurs. Test valid User-Agent shape and malformed
platform/app/version/username variants.

Test subreddit arrays for non-array, non-string, empty, `r/` prefix, slash,
control, over-21-character name, and 51 elements. Assert lowercase
case-insensitive dedupe and exclusion precedence. Test `num_items_to_fetch` at
0, 1, 100, and 101.

- [ ] **Step 3: Run the focused file; verify RED**

```bash
bundle exec ruby -Itest test/adapters/reddit_test.rb
```

- [ ] **Step 4: Implement validation and injected construction**

Follow existing adapter initializer/validation patterns. Store only normalized
non-secret options necessary for fetch. Default the production client and
process coordinator, but accept injected clients/clocks in tests. Ensure
`executable_dependencies` remains empty.

- [ ] **Step 5: Run config tests; verify GREEN**

```bash
bundle exec ruby -Itest test/adapters/reddit_test.rb -n '/config|user_agent|subreddit|num_items/'
```

- [ ] **Step 6: Commit**

```bash
git add test/fixtures/reddit lib/cybort/adapters/reddit.rb test/adapters/reddit_test.rb lib/cybort.rb
git commit -m "feat: validate Reddit adapter configuration"
```

---

### Task 7: Implement discovery calls, identity validation, and normalization

**Files:**
- Modify: `lib/cybort/adapters/reddit.rb`
- Modify: `test/adapters/reddit_test.rb`

- [ ] **Step 1: Write scope and outbound-call tests**

With subscriptions `ruby, news, memes`, includes `askscience, news, memes`, and
excludes `memes`, assert:

```ruby
assert_equal %w[news ruby], adapter.joined_effective
assert_equal %w[askscience], adapter.explicit_to_fetch
assert_equal 1, client.calls.count { |c| c.operation == :home_hot }
assert_equal %w[askscience], client.subreddit_calls.select { |c| c.operation == :subreddit_hot }.map(&:subreddit)
assert_equal %w[news], client.subreddit_calls.select { |c| c.operation == :news_hot }.map(&:subreddit)
refute client.urls.any? { |url| url.include?("+") }
```

In a separate case put `news` in include and exclude and assert there is no
request for it. Put an explicit name in subscriptions and assert no explicit
request. When all joined names are excluded, assert no home call. When explicit
`news` is not subscribed, assert exactly one call (ordinary explicit request,
not a duplicate dedicated request).

- [ ] **Step 2: Write unread qualification/pagination tests**

Set limit 2, return a first page with ten nonqualifying children and one valid
t4 plus an `after`, then a second valid t4. Assert two messages are returned and
the second page was requested. Test `kind/name/id`, `new`, and `was_comment`
rules individually. Assert message body/author/raw fields never occur in
`Item#body`, `info`, result metadata, or serialized result.

- [ ] **Step 3: Write identity and URL attack tests**

For t3 candidates independently reject:

- `kind != "t3"`, uppercase/malformed ID, and `name` not exactly `t3_<id>`;
- subreddit different from a requested single-subreddit (while a valid
  out-of-scope home recommendation is filtered, not failed);
- an absolute URL, network path, query, fragment, and backslash;
- raw C0/DEL, `%00`, `%1f`, `%7f`, `%2f`, `%5c`, `%3f`, and `%23`
  (case-insensitive), plus malformed percent escapes;
- `.`/`..` traversal segments including percent-encoded forms; and
- a decoded subreddit or comment ID mismatch.

Assert duplicates with one fullname and different stable identity fields fail.
For duplicates whose mutable scores/comments/titles differ, assert deterministic
precedence: dedicated single-subreddit data wins over personalized-home data,
dedicated `news` wins over other sources, and first observation wins within one
source. Assert the valid path
`/r/news/comments/abc123/example_title/` produces exactly
`https://www.reddit.com/r/news/comments/abc123/example_title/` even if the source
object contains an outbound `url` field.

- [ ] **Step 4: Write normalization, metadata, and replacement tests**

Assert selected messages/threads have `body: nil`, correct canonical identity,
one canonical URL, one fetch timestamp, normalized remote time, exact vote and
comment totals, activity score, megathread/stickied, and final selection rank.
Assert a complete remote result has:

```ruby
assert result.source_fetched
assert result.replace_existing_items
assert_equal "unsupported_by_documented_data_api",
  result.metadata.fetch(:chat_collection)
assert_equal "personalized_home_plus_explicit_single_subreddit",
  result.metadata.fetch(:coverage_mode)
```

Assert bounded count/page/request fields exist but membership, credentials,
subjects, and titles do not. Make any required page/call invalid and assert a
failure with `replace_existing_items == false` and no partial items.

- [ ] **Step 5: Write final selection tests at adapter level**

Cover N=1 message priority; N=2 message+ordinary; N=2 message+mega (mega is the
reserved thread); N=2 mega+ordinary without message; N=4 deterministic fill;
duplicate t3 across home/explicit/news; and more unread nonqualifying objects
than N. Assert priority describes activity order while `selection_rank`
describes final emitted order.

- [ ] **Step 6: Run and verify RED**

```bash
bundle exec ruby -Itest test/adapters/reddit_test.rb
```

- [ ] **Step 7: Implement one complete remote pipeline**

Implement in this order:

1. authenticate;
2. completely discover/validate subscriptions;
3. calculate `joined_effective` and `explicit_to_fetch` after exclusions;
4. fetch/qualify unread pages until enough qualifying candidates or end;
5. call home at most once, sorted explicit names individually, and joined news
   once after exclusion;
6. validate/filter/dedupe t3s, calculate/rank, then bounded-select;
7. construct minimized `Item`s and safe bounded metadata; and
8. return a source payload hash with `replace_existing_items: true` only now;
   `Adapters::Base` constructs the `FetchResult` and supplies the canonical
   instance ID, timestamps, and cache/failure behavior.

Rescue source errors through the established base adapter path. Cached base
results retain default replacement false and empty metadata; do not restore
`chat_collection` on cache hits.

- [ ] **Step 8: Run focused tests; verify GREEN**

```bash
bundle exec ruby -Itest test/adapters/reddit_test.rb
bundle exec ruby -Itest test/reddit_activity_test.rb
bundle exec ruby -Itest test/reddit_client_test.rb
```

- [ ] **Step 9: Commit**

```bash
git add lib/cybort/adapters/reddit.rb test/adapters/reddit_test.rb test/fixtures/reddit
git commit -m "feat: collect bounded Reddit snapshots"
```

---

### Task 8: Register Reddit and prove persistence/orchestrator integration

**Files:**
- Modify: `lib/cybort/adapter_registry.rb`
- Modify: `test/adapter_registry_test.rb`
- Modify: `test/system/cli_system_test.rb`

- [ ] **Step 1: Write registry tests**

Assert `AdapterRegistry.default` builds `reddit`, declares no executable, and
reports Reddit validation errors alongside another invalid source before
persistence registration. Use syntactically fake secrets only.

- [ ] **Step 2: Write offline system scenarios**

Using injected/fake HTTP responses and a temporary SQLite database, prove:

1. first forced remote fetch stores one unread message and two selected
   threads;
2. second complete remote snapshot omits the message/thread, and they are
   removed while a returned identity remains refreshed;
3. an empty complete snapshot clears the instance;
4. a fresh-cache run makes zero token/data calls, preserves stored items, and
   has no remote chat metadata;
5. token 401, data 403, 429, timeout, and malformed later page preserve prior
   items and sync state;
6. configured retention remains success-only and composes with replacement;
7. a Reddit failure does not discard a successful RSS result; and
8. CLI JSON stays in current recency order even when Reddit priority and
   `selection_rank` differ.

Capture requested URLs in all scenarios and assert:

```ruby
refute requested_urls.any? { |url| url.match?(%r{/r/[^/]*\+[^/]*/hot}) }
```

- [ ] **Step 3: Run and verify RED**

```bash
bundle exec ruby -Itest test/adapter_registry_test.rb
bundle exec ruby -Itest test/system/cli_system_test.rb
```

- [ ] **Step 4: Register the adapter only**

Follow the existing direct-adapter registry entry. Do not modify the
orchestrator: `FetchResult` transports snapshot intent to persistence through
the existing result write.

- [ ] **Step 5: Run integration tests; verify GREEN**

```bash
bundle exec ruby -Itest test/adapter_registry_test.rb
bundle exec ruby -Itest test/system/cli_system_test.rb
bundle exec ruby -Itest test/orchestrator_test.rb
bundle exec ruby -Itest test/persistence_test.rb
```

- [ ] **Step 6: Commit**

```bash
git add lib/cybort/adapter_registry.rb test/adapter_registry_test.rb test/system/cli_system_test.rb
git commit -m "feat: integrate Reddit snapshot collection"
```

---

### Task 9: Document operator behavior and authenticated release gate

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`
- Conditional modify: `docs/LEARNINGS.md`

- [ ] **Step 1: Add user-facing configuration and semantics**

Document every example key and limit, external refresh-token provisioning,
required scopes, bounded personalized-home coverage, one-call explicit/news
behavior, exclusions, exact ranking formula, message/thread reservation,
`selection_rank`, and unchanged CLI recency ordering.

State prominently that chat is unsupported, body/author/raw data is not stored,
visible score is not an exact vote count, and complete successes replace the
bounded current set.

- [ ] **Step 2: Add the compliance caveat without overclaiming**

Recommend `retention_ttl_minutes <= 2880`, then state that cache/failure paths do
not clean up, so neither retention nor snapshot replacement guarantees
wall-clock deletion during outages. Document the absence of automatic cleanup
on instance removal/access termination/user request and point to
`docs/quality-followups.md`. Provide a concrete manual local-data removal
warning without inventing a new destructive CLI command.

- [ ] **Step 3: Record durable invariants**

In `AGENTS.md`, add only implemented facts: documented endpoints, complete
remote snapshot opt-in, cache/failure preservation, body-free storage, bounded
coverage, and authenticated release gate. Do not copy temporary task details.

- [ ] **Step 4: Specify and, only if credentials are available, run smoke test**

The manual checklist verifies token fields/scopes, t5/t4 cursor shapes,
`/hot`, one `/r/<name>/hot`, rate headers, absence of `+` routes, and unchanged
qualifying unread IDs/count immediately before/after the `mark=false` fetch.
Record only shapes/statuses. If not run, say so; do not add a speculative
learning or block offline implementation.

- [ ] **Step 5: Validate links and terminology**

```bash
rg -n 'reddit|replace_existing_items|retention_ttl_minutes|chat|personalized|mark=false' README.md AGENTS.md docs/adr docs/quality-followups.md docs/superpowers/specs/2026-09-05-reddit-integration-design.md
rg -n '/r/[^` ]*\+[^` ]*/hot|full deletion compliance|guarantee.*read state' README.md AGENTS.md docs
```

Expected: the first command shows consistent documentation; the second has no
positive implementation claim or multi-subreddit endpoint (historical review
wording such as “never use” may match and must be inspected).

- [ ] **Step 6: Commit**

```bash
git add README.md AGENTS.md
git add docs/LEARNINGS.md
git commit -m "docs: explain Reddit collection and lifecycle caveats"
```

---

### Task 10: Final verification and review checkpoint

**Files:** review every file in the exact file map; change only defects found.

- [ ] **Step 1: Run focused suites together**

```bash
bundle exec ruby -Itest test/rate_limit_headers_test.rb
bundle exec ruby -Itest test/http_client_test.rb
bundle exec ruby -Itest test/errors_test.rb
bundle exec ruby -Itest test/reddit_rate_limit_coordinator_test.rb
bundle exec ruby -Itest test/fetch_result_test.rb
bundle exec ruby -Itest test/persistence_test.rb
bundle exec ruby -Itest test/reddit_client_test.rb
bundle exec ruby -Itest test/reddit_activity_test.rb
bundle exec ruby -Itest test/adapters/reddit_test.rb
bundle exec ruby -Itest test/adapter_registry_test.rb
bundle exec ruby -Itest test/system/cli_system_test.rb
```

Expected: all PASS with no network access.

- [ ] **Step 2: Run complete project verification**

```bash
bundle exec rake test
bundle exec rubocop
bundle exec brakeman
```

Expected: all exit 0. If this repository does not define one of the latter two
commands, report that exact absence; do not install or invent tooling.

- [ ] **Step 3: Audit prohibited data and endpoints**

```bash
rg -n 'selftext|author|Sendbird|sendbird|/r/[^ ]*\+[^ ]*/hot' lib/cybort test README.md AGENTS.md
rg -n 'client_secret|refresh_token|access_token|Authorization' lib/cybort
```

Inspect every match. Credential terms may appear only at validation/request
construction boundaries, never in result metadata, errors, or persistence.
Fixtures contain synthetic values only. There must be no production `+` route.

- [ ] **Step 4: Review architecture boundaries and diff**

```bash
git diff --check
git status --short
git diff --stat HEAD~8..HEAD
git log --oneline -10
```

Confirm no schema change, adapter SQL, orchestrator special case, global CLI
sort change, or external-service test. Confirm snapshot delete precedes upsert
inside one transaction and all rollback tests actually observe durable state
from a fresh read.

- [ ] **Step 5: Request independent code review**

Use `superpowers:requesting-code-review` with the spec, ADR 0004, this plan,
commit range, and verification output. Resolve correctness findings with tests
first and rerun Steps 1–4.

- [ ] **Step 6: Commit review fixes if any**

```bash
git add lib test README.md AGENTS.md docs/LEARNINGS.md
git diff --cached --quiet
git commit -m "fix: address Reddit integration review"
```

Run the commit command only when the preceding check exits nonzero because
review fixes are staged; otherwise skip it.

Stop before pushing or merging. Hand off the commit range, verification output,
whether the authenticated smoke test ran, and the known outage/explicit-deletion
compliance caveats.
