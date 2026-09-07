# Reddit Public RSS Ranking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an explicit public RSS adapter selecting explainable recent Reddit highlights from a bounded observed pool, without authentication or private data.

**Architecture:** Separate `reddit_rss` from unchanged OAuth `reddit`. A bounded feed client and process-wide request lane supply three Atom pages to pure state/ranking components; the adapter returns selected Items plus bounded JSON state through existing snapshot persistence.

**Tech Stack:** Ruby 4.0.1, existing `rss`, JSON, URI, Digest, StringIO, Time, Mutex, Net::HTTP, SQLite3, Minitest. No new gems.

**Spec:** [Reddit RSS design](../specs/2026-09-06-reddit-rss-design.md)
**Decision:** [ADR 0006](../../adr/0006-reddit-rss-observed-ranking.md)

## Global Constraints

- New `adapter = "reddit_rss"`; keep `reddit` and `rss` unchanged. No OAuth, cookies, private RSS keys, scraping, redirects, alternate hosts, or fallback to JSON.
- Only the three fixed `www.reddit.com` routes in the spec; sorted normalized `+` groups; one page each, prefix limit 100, three application requests maximum.
- Attempt deadline 180 seconds; request deadline 30 seconds capped by the attempt; response limit 1,048,576 bytes; process-wide completion-to-next-start spacing two seconds.
- Eligibility window 86,400 seconds inclusive at the old boundary; future skew 300 seconds inclusive; candidate eviction at age 172,800 seconds; maximum 2,000 candidates, four polls, 8,388,608 serialized state bytes.
- Ranking version `rss-rank-v1`, state schema 1; weights top/rising/momentum/persistence 550/300/100/50, integer sum 1000. History gap strictly greater than 3,600 seconds resets history.
- Observed-pool denominator includes age-eligible candidates without a current signal. Only current top/rising candidates can be selected. Quota `(M + 9) / 10`, capped by available signals and configured item limit 1–100.
- Preserve raw prefix positions and counts before deduplication/age filtering. Singleton prominence is 1,000,000, absent prominence is zero.
- Require Atom publication time and canonical post identity. Never store bodies, authors, raw XML, User-Agent, or raw error data.
- State and selected snapshot commit together only after complete success. Cache/failure paths neither advance history nor prune/replace anything. No schema changes or adapter SQL.
- No polling service or durable backoff scheduler. External invocation must respect the documented retry hint; process-local pacing is not cross-process rate compliance.
- Valid server Retry-After hints are honored without a downward cap. Raw hint text is at most 128 bytes; parsing and elapsed-delay comparisons use finite safe arithmetic, active cooldowns fail immediately without allocating or sleeping the requested delay, and no durable backoff is claimed.
- Live feed access, permission, rank order, and creation-time semantics are unverified release gates. Never bypass denial. Keep the connector experimental until verified.

## Execution boundary and branch context

This document is planning only, based on `main` at `9638482`. Gmail replacement
is independently implemented/pushed on `gmail-direct-api` at `86599e6`; do not
reimplement or revert it when integrating branches. README, ADR index, registry,
requires, and system tests may need ordinary merge conflict resolution.

The user waived design approval checkpoints, not the distinction between a
plan and implemented code. This documentation revision does not execute the
plan. For the subsequent implementation, the user authorizes Luna at xhigh to
perform all implementation work and tests, with an independent review and a
commit plus push for every task. Sol at high performs the final whole-branch
review. Do not merge to `main` or change live accounts/configuration. During
this planning task inspect tests but do not run tests, linters, builds, or
dependency installation. Use Minitest commands below, not RSpec.

## Independent review decision record (2026-09-07)

- **Ruling — namespace preflight:** Use REXML's parsed element names and
  namespace URIs before RSS extraction; accept valid default/prefixed Atom and
  reject foreign structural root/children while retaining the first-100 RSS
  normalization boundary. **Cost if wrong:** foreign XML could be interpreted
  as Atom entries, or valid prefixed feeds could be rejected in production.
- **Ruling — state JSON boundary:** Keep string-key JSON storage and existing
  recursive symbolizing `Persistence#parse_json`; canonicalize String/Symbol
  state keys recursively with duplicate-collision rejection and validate bounds
  before taking owned copies. **Cost if wrong:** a two-poll cache roundtrip could
  lose history, accept ambiguous state, or copy an attacker-sized structure.
- **Ruling — transition interface:** Keep `RedditRssState::Transition` nested;
  tests must prove transition behavior and immutability, not a constant-only
  assertion. **Cost if wrong:** callers could bind to an accidental top-level
  API that later collides with another adapter.
- **Ruling — option key count:** Task 5 names exactly three source-option keys;
  the four names belong only to the nested activity-weight table. Reject
  String/Symbol duplicates in both maps. **Cost if wrong:** configuration could
  silently drop an option or weight during normalization.
- **Ruling — server delay hints:** Do not cap valid Retry-After downward; bound
  raw text at 128 bytes, use finite safe arithmetic, and fail active cooldowns
  immediately without sleeping or allocating the requested delay. **Cost if
  wrong:** a cap could permit a request before Reddit's explicit server hint,
  while unsafe arithmetic could overflow or stall the process.

Each implementation task ends with covering tests, spec/code review, then a
scoped commit. Push only when authorized for that execution task. Do not commit
ignored generated `.superpowers` briefs, reports, fixtures with real content,
or credentials. Update the canonical checklist here, not a generated brief.

## Exact file map and shared value contracts

| Files | Responsibility |
|---|---|
| `lib/cybort/errors.rb`, `test/errors_test.rb` | New allowlisted `RedditRssError` |
| `lib/cybort/reddit_rss_client.rb`, `test/reddit_rss_client_test.rb` | Entry/Page structs, Atom boundary, fixed GET contract |
| `lib/cybort/reddit_rss_coordinator.rb`, `test/reddit_rss_coordinator_test.rb` | Single public-host lease, pacing, cooldown |
| `lib/cybort/rate_limit_headers.rb`, `test/rate_limit_headers_test.rb` | Backward-compatible HTTP-date Retry-After normalization |
| `lib/cybort/reddit_rss_state.rb`, `test/reddit_rss_state_test.rb` | Bounded JSON schema and immutable transition |
| `lib/cybort/reddit_rss_activity.rb`, `test/reddit_rss_activity_test.rb` | Fixed-point math and deterministic selection |
| `lib/cybort/adapters/reddit_rss.rb`, `test/adapters/reddit_rss_test.rb` | Static configuration, composition, normalization |
| `lib/cybort.rb`, `lib/cybort/adapter_registry.rb`, `test/adapter_registry_test.rb` | Requires and explicit dependency-free registration |
| `test/support/reddit_rss_fixture.rb`, `test/fixtures/reddit_rss/` | Synthetic Atom builder and recording HTTP fixture |
| `test/system/reddit_rss_system_test.rb`, `test/persistence_test.rb` | CLI/persistence transaction and history guarantees |
| `.cybort.example.toml`, `README.md`, `AGENTS.md`, `docs/LEARNINGS.md`, ADR 0006/index and this spec/plan | Actual behavior, migration, evidence, release status |

No production changes to persistence, schema, Base, orchestrator, Item,
configuration loader, OAuth Reddit classes, or Gmail are planned.

Define these interfaces exactly; all state-derived hashes use string keys:

```ruby
# Within RedditRssClient:
Entry = Struct.new(:id, :subreddit, :title, :published_at, :rank, keyword_init: true)
Page = Struct.new(:entries, :raw_entry_count, keyword_init: true)
# Entry.id is t3_<base36>; published_at is UTC Time; rank is raw 1-based.

RedditRssClient.parse(body:, subreddits:, operation:) # => Page; no HTTP
RedditRssClient.new(http_client:, monotonic_clock:, coordinator:)
# #fetch(sort:, subreddits:, user_agent:, deadline_monotonic:) => Page

RedditRssCoordinator.new(clock:, sleeper:)
# .default => process-wide gate, using Process CLOCK_MONOTONIC and sleep
# #acquire(operation:, deadline_monotonic:) => Lease
# Lease#observe(metadata:, status:), Lease#release (idempotent)

RedditRssState.new(raw:, subreddits:, weights:) # validates, canonicalizes, copies or initializes
# #advance(pages:, now:) => Transition
# pages is {"new" => Page, "rising" => Page, "top" => Page}
# RedditRssState::Transition = Struct.new(:state, :previous_poll,
#   :previous_candidate_ids, :flags, :future_exclusion_count, keyword_init: true)
# previous_poll is nil on cold/reset; previous_candidate_ids is a frozen Array.

RedditRssActivity.select(transition:, pages:, weights:, now:, limit:)
# => {selected: [row, ...], metadata: {...}}
# row = {id:, subreddit:, title:, published_at: Time, priority:, info: Hash}
```

`RedditRssState::Transition` is nested in `RedditRssState`; do not create a
second top-level constant or a constant-only test. `weights` is a normalized
string-keyed Hash in the fixed order
`top`, `rising`, `momentum`, `persistence`. Returned state contains only JSON
scalars/collections; no Time, Struct, Symbol, Set, or client object is serialized.

### Task 1: Safe Atom identity and response decoding

**Files:** errors and error tests; new client and client tests; support fixture,
`test/fixtures/reddit_rss/basic.atom`; `lib/cybort.rb` requires. Do not register
the adapter yet.

**Consumes:** existing SourceError and RSS gem.
**Produces:** Entry/Page and `.parse` interfaces above; `RedditRssError`.

- [ ] **Step 1: Build synthetic fixture helpers and failing parser/error tests.**

  Add a helper module, included only in new test classes, with `atom(entries)`
  and `atom_entry(id:, subreddit:, title:, published:)`. Use `CGI.escapeHTML`
  for text/attributes in generated XML, not hand-concatenated unescaped input:

  ```ruby
  def atom_entry(id: "t3_abc", subreddit: "ruby", title: "Release notes",
                 published: "2026-09-06T11:00:00Z")
    short_id = id.delete_prefix("t3_")
    <<~XML
      <entry><id>#{CGI.escapeHTML(id)}</id>
      <title>#{CGI.escapeHTML(title)}</title>
      <published>#{CGI.escapeHTML(published)}</published>
      <updated>2026-09-06T12:00:00Z</updated>
      <link rel="alternate" href="https://www.reddit.com/r/#{subreddit}/comments/#{short_id}/title/"/>
      </entry>
    XML
  end

  def atom(entries)
    <<~XML
      <feed xmlns="http://www.w3.org/2005/Atom">
      <id>https://www.reddit.com/r/ruby/</id><title>Fixture</title>
      <updated>2026-09-06T12:00:00Z</updated>#{entries.join}</feed>
    XML
  end

  def test_published_and_raw_rank_are_preserved
    xml = atom([atom_entry, atom_entry, atom_entry(id: "t3_def")])
    page = Cybort::RedditRssClient.parse(body: xml, subreddits: ["ruby"], operation: :new)
    assert_equal 3, page.raw_entry_count
    assert_equal ["t3_abc", "t3_def"], page.entries.map(&:id)
    assert_equal [1, 3], page.entries.map(&:rank)
    assert_equal Time.utc(2026, 9, 6, 11), page.entries.first.published_at
  end
  ```

  Adversarial fixture table: no `published` but recent `updated`; malformed
  `published` date; missing/foreign Atom namespace; foreign structural root or
  child namespace; valid prefixed Atom root/children; HTML error document;
  malformed XML; DTD and internal/external entity declarations; `content src`
  and author sentinels ignored without any request; wrong `t3_` identity;
  comment instead of post
  path; query/fragment/userinfo/port/protocol-relative URL; encoded separators,
  bad percent escape, `..`; foreign subreddit; empty/control/oversized title;
  typed HTML/XHTML title; conflicting duplicate ID/date/subreddit; entry 101
  malformed but ignored. Check `cause.nil?` and no sentinel in error/metadata.
  Valid empty Atom returns a zero-entry Page. Error tests reject arbitrary
  operation/category/status/delay and assert frozen safe metadata.

- [ ] **Step 2: Run red tests through the delegated test worker.**
  `bundle exec ruby -Itest test/reddit_rss_client_test.rb` and
  `bundle exec ruby -Itest test/errors_test.rb`; expected missing constants or
  `.parse`, not test-loader or fixture setup errors.

- [ ] **Step 3: Implement error enums and the parse pipeline.**

  Use exactly the spec's enum sets and content-free guidance. HTTP status must
  be nil or an Integer 100–599; retry delay nil or finite nonnegative Numeric.
  Do not attach raw exceptions. Structure the parser as:

  ```ruby
  def self.parse(body:, subreddits:, operation:)
    unless body.is_a?(String) && body.bytesize <= 1_048_576
      raise RedditRssError.new(operation: operation, category: :response_too_large), cause: nil
    end
    xml = body.dup.force_encoding(Encoding::UTF_8)
    # Reject DTD/entity declarations before either XML parser sees the body.
    unless xml.valid_encoding? && !xml.match?(/<!DOCTYPE|<!ENTITY/i)
      raise RedditRssError.new(operation: operation, category: :invalid_feed), cause: nil
    end
    validate_atom_structure!(StringIO.new(xml), operation: operation)
    feed = ::RSS::Parser.parse(StringIO.new(xml), false)
    unless feed.is_a?(::RSS::Atom::Feed)
      raise RedditRssError.new(operation: operation, category: :invalid_feed), cause: nil
    end
    prefix = feed.entries.first(100)
    records = {}
    prefix.each_with_index do |entry, index|
      record = normalize_entry(entry, rank: index + 1,
                               subreddits: subreddits, operation: operation)
      previous = records[record.id]
      if previous && [previous.subreddit, previous.published_at, previous.title] !=
                     [record.subreddit, record.published_at, record.title]
        raise RedditRssError.new(operation: operation, category: :invalid_entry), cause: nil
      end
      records[record.id] ||= record
    end
    Page.new(entries: records.values.freeze, raw_entry_count: prefix.length).freeze
  rescue ::RSS::Error, REXML::ParseException, REXML::UndefinedNamespaceException,
         ArgumentError, EncodingError
    raise RedditRssError.new(operation: operation, category: :invalid_feed), cause: nil
  end
  ```

  Require the existing `rexml/document` and implement
  `validate_atom_structure!` with the `REXML::Document` API,
  not a namespace regex. Parse the bounded `StringIO` once, require
  `root.name == "feed" && root.namespace == ATOM_NAMESPACE`, then inspect
  direct children through `root.elements.to_a`. When present, feed structural
  `id`, `title`, and `updated` children must be unique and Atom-namespace, and
  all `entry` children must be Atom-namespace; root metadata is optional and
  is not required solely for preflight. For only the first 100 entries, require
  unique Atom-namespace `id`, `title`, and `published`, an optional unique
  Atom-namespace `updated`, and Atom-namespace `link` children. A child with a
  structural local name in a foreign namespace is an invalid feed. Accept
  default or prefixed bindings only when
  `element.namespace` resolves to the exact Atom URI; ignore extension/content
  descendants after the structural check. Rescue REXML parse/namespace errors
  into the same content-free `invalid_feed` result before calling RSS.

  Define private `.normalize_entry(entry, rank:, subreddits:, operation:)`:
  unwrap `.content` for id/title/published; require plain-text title and spec
  lengths/types; choose exactly one distinct valid alternate link; missing rel
  means alternate. Canonical path grammar is
  `\A/r/([A-Za-z0-9_]{2,21})/comments/([1-9a-z][0-9a-z]{0,15})(?:/[^/]+)?/?\z`, but validate
  segments before applying it (no controls, traversal, encoded separators, or
  empty interior segments, link over2,048 bytes). Require the bounded short ID
  syntax above and exact Atom `t3_` match. No decoding that
  turns separators into new path segments. Convert subreddit to lowercase;
  require group membership. Freeze Entry and its strings. No category/author
  fallback is needed: subreddit comes from the verified permalink.

- [ ] **Step 4: Run green parser/error tests and review the security boundary.**
  Recheck no external requests from XML and raw rank N semantics.
- [ ] **Step 5: Commit** `feat: decode bounded public Reddit Atom posts`.

### Task 2: Public-feed transport, spacing, and safe throttling

**Files:** client/client tests; new coordinator/coordinator tests; rate-header
parser/tests; `lib/cybort.rb`; `test/http_client_test.rb` regression if needed.
**Consumes:** Task 1 Page decoder and errors; existing HttpClient.
**Produces:** complete client `#fetch`, process-wide lease interface.

- [ ] **Step 1: Write request/coordinator/rate-date tests.**
  Recording fake queues three synthetic HttpResponses. Assert exact routes,
  `+` group sorting supplied by adapter, parameters, headers, deadline/timeout,
  no second request after error, and no redirects. Use an injected mutable
  monotonic clock and sleeper that records/advances time—never real sleeps.
  Assert two different configured instances use the same gate, only one lease
  is active, and release survives HTTP/parser exceptions. Use queues/barriers
  for real thread ordering tests rather than timing-dependent sleep guesses.

  ```ruby
  def test_retry_after_http_date_is_normalized_without_retaining_header
    now = Time.utc(2026, 9, 6, 12)
    parsed = Cybort::RateLimitHeaders.parse(
      {"Retry-After" => "Sun, 06 Sep 2026 12:01:30 GMT"}, now: now
    )
    assert_equal({retry_after_seconds: 90}, parsed)
  end
  ```

  Add HTTP-date past => zero, malformed/control/over-128-byte => omitted,
  one 128-byte huge numeric value retained without downward capping, and a
  far-future HTTP-date retained as a finite delay. Existing numeric/canonical
  metadata/casing tests remain unchanged. Replace the old test specifically
  expecting all HTTP dates to be omitted. Exercise a real HttpClient with
  injected 429 response/body to verify numeric safe metadata reaches the
  coordinator and raw data never reaches the error. With a huge hint, assert
  the coordinator fails a second acquire immediately and does not ask the
  sleeper to wait for the server-requested delay.

- [ ] **Step 2: Run the focused files red.**
  `bundle exec ruby -Itest test/reddit_rss_coordinator_test.rb`, client tests,
  rate-limit-header tests; expected missing gate/fetch/date support.

- [ ] **Step 3: Extend safe Retry-After parsing backward-compatibly.**
  Use `require "time"`; do not change other rate fields. Existing callers pass
  both positional hashes and inline keyword-like hashes, so preserve both:

  ```ruby
  def parse(headers = nil, now: Time.now.utc, **inline_headers)
    source = headers.nil? ? inline_headers : headers
    normalized = {}
    (source.respond_to?(:to_h) ? source.to_h : {}).each do |key, value|
      normalized[key.to_s.downcase.tr("_", "-")] = value
    end
    parsed = {}
    RATE_HEADER_NAMES.each do |header_name, metadata_key|
      canonical_name = metadata_key.to_s.tr("_", "-")
      value = parse_nonnegative_float(
        normalized[header_name] || normalized[header_name.delete_prefix("x-")] || normalized[canonical_name]
      )
      parsed[metadata_key] = value unless value.nil?
    end
    delay = retry_delay(normalized[RETRY_AFTER_HEADER] || normalized["retry-after-seconds"], now: now)
    parsed[:retry_after_seconds] = delay unless delay.nil?
    parsed.freeze
  end

  def retry_delay(value, now:)
    return value if value.is_a?(Integer) && value >= 0
    return unless value.is_a?(String) && value.valid_encoding? && value.bytesize <= 128
    return if value.match?(/[\x00-\x1F\x7F]/)
    return Integer(value, 10) if value.match?(/\A\d+\z/)
    [(Time.httpdate(value).to_r - now.to_r).ceil, 0].max
  rescue ArgumentError, RangeError
    nil
  end
  ```

  Retain existing constants and `parse_nonnegative_float`; mark the new
  `retry_delay` helper private with `private_class_method`, as the existing
  helper is. The public method remains the module function `parse`.
  Test both original inline-hash call forms to catch Ruby keyword regressions.

- [ ] **Step 4: Implement the coordinator as a bounded single-lane state machine.**
  Fields: mutex, active lease token or nil, next-allowed monotonic time,
  cooldown observation time plus integer delay, injected clock/sleeper. `.default` returns
  one eagerly assigned instance after class definition; no per-account keys.
  `acquire` loops: under mutex read time once; deadline reached => deadline
  error; cooldown active => rate_limited with remaining seconds immediately (no
  sleep/allocation of the requested server delay); if lane free and spacing
  satisfied, assign unique Object token and return Lease. Otherwise compute
  `min(remaining_deadline, active ? 0.05 : next_allowed-now)`, unlock, sleep
  positive duration, repeat. For cooldown checks compute
  `(now.to_r - observed_at.to_r)` and compare the Rational directly with the
  integer delay; compute remaining as `(delay - elapsed).ceil`. Never convert a
  huge delay through Float or add it to a monotonic clock. Observe/reset/release
  require matching token.

  `Lease#observe` accepts safe numeric metadata and status. For 429 or remaining
  <=0, record the maximum of the finite nonnegative server hints and 60 seconds
  as the cooldown delay without capping a valid hint downward. No sleeping or
  retrying occurs in observe. On release,
  clear token and set next-allowed to current monotonic time +2; repeat release
  is a no-op. Unexpected sleeper errors become safe deadline errors, not raw
  content. Waits and HTTP must never occur while the mutex is held.

- [ ] **Step 5: Implement fixed request construction and lease cleanup.**

  ```ruby
  def fetch(sort:, subreddits:, user_agent:, deadline_monotonic:)
    operation = {"new" => :new, "rising" => :rising, "top" => :top}.fetch(sort)
    group = subreddits.join("+")
    params = sort == "top" ? {"t" => "day", "limit" => 100} : {"limit" => 100}
    url = "https://www.reddit.com/r/#{group}/#{sort}/.rss?#{URI.encode_www_form(params)}"
    lease = @coordinator.acquire(operation: operation, deadline_monotonic: deadline_monotonic)
    begin
      now = @monotonic_clock.call
      request_deadline = [deadline_monotonic, now + 30].min
      ensure_before!(now, request_deadline, operation)
      response = @http_client.get(url,
        headers: {"User-Agent" => user_agent, "Accept" => "application/atom+xml, application/xml"},
        timeout_seconds: request_deadline - now, deadline_monotonic: request_deadline)
      lease.observe(metadata: RateLimitHeaders.parse(response.headers), status: response.status)
      ensure_before!(@monotonic_clock.call, request_deadline, operation)
      page = self.class.parse(body: response.body, subreddits: subreddits, operation: operation)
      ensure_before!(@monotonic_clock.call, deadline_monotonic, operation)
      page
    rescue HttpError => error
      lease.observe(metadata: error.safe_metadata, status: error.safe_metadata[:status])
      raise_http_error(error, operation)
    rescue HttpTransportError => error
      raise RedditRssError.new(operation: operation, category: error.safe_metadata.fetch(:category)), cause: nil
    ensure
      lease.release
    end
  end
  ```

  Define `ensure_before!(now, deadline, operation)` as strict `<` else safe
  deadline error. Define `raise_http_error`: 401/403 => access_denied; 429 =>
  rate_limited with the finite nonnegative maximum server delay or fallback60
  (never a downward cap); other statuses => http. Keep huge integer hints as
  integers in safe metadata and let the coordinator's elapsed-delay comparison
  handle them without adding them to a monotonic Float.
  Never include HttpError inspection or raw headers. The public `#fetch` also
  validates sort, sorted group names, and printable User-Agent before building
  a URL; invalid programmer inputs yield static ArgumentError, not KeyError
  containing arbitrary values. Tests cover these guards.

- [ ] **Step 6: Run green client/coordinator/header and existing HTTP/OAuth rate tests.**
  Also run `test/reddit_rate_limit_coordinator_test.rb` and
  `test/http_client_test.rb` because safe header behavior is shared.
- [ ] **Step 7: Commit** `feat: pace and fetch public Reddit RSS safely`.

### Task 3: Bounded candidate and observation state

**Files:** new state/state tests; `lib/cybort.rb` require.
**Consumes:** Page/Entry values and validated names/weights.
**Produces:** JSON-safe state and Transition, never SQL or mutation of context.

- [x] **Step 1: Write failing state-transition tests using direct Pages.**
  Test all three feed unions, preferred title order, same-ID date/subreddit
  conflicts, first/last seen, four-snapshot rolling cap, cold state, fingerprint
  change, outage >3600 versus exactly3600, non-increasing clock, future skew,
  age boundaries, deterministic 2001-to-2000 eviction, serialized-size bounds,
  corrupt/unknown-version state, recursively symbolized state, mixed
  String/Symbol duplicate-key rejection, and immutable input. Build entries
  with Task1 structs, not HTTP or RSS parser coupling.

  ```ruby
  def test_state_keeps_non_selected_discovery_candidates
    now = Time.utc(2026, 9, 6, 12)
    page = Cybort::RedditRssClient::Page.new(entries: [
      Cybort::RedditRssClient::Entry.new(id: "t3_abc", subreddit: "ruby",
        title: "Fresh", published_at: now - 60, rank: 1)
    ], raw_entry_count: 1)
    empty = Cybort::RedditRssClient::Page.new(entries: [], raw_entry_count: 0)
    state = Cybort::RedditRssState.new(raw: nil, subreddits: ["ruby"],
      weights: {"top" => 550, "rising" => 300, "momentum" => 100, "persistence" => 50})
    result = state.advance(pages: {"new" => page, "rising" => empty, "top" => empty}, now: now)
    assert_equal ["t3_abc"], result.state.fetch("candidates").keys
    assert_equal 1, result.state.fetch("polls").length
    assert_nil result.previous_poll
  end
  ```

- [x] **Step 2: Run** `bundle exec ruby -Itest test/reddit_rss_state_test.rb` red.

- [x] **Step 3: Implement exact state schema validation and copy boundary.**
  Constructor accepts nil/{} as initialization. Otherwise require exact envelope
  keys/types from spec, recognized schema version1, <=2000 records and <=4
  snapshots, serialized bytes <=8,388,608. Timestamps are canonical UTC
  ISO8601(6), parsed using Time.iso8601 and checked by roundtrip; record strings
  follow the same identity/title syntax as parsed Entries. Check current group
  membership only after matching the fingerprint, so valid old-group state can
  reset rather than failing before reset. Accept String or Symbol keys at every
  level because Persistence#parse_json recursively symbolises stored JSON, but
  reject a duplicate logical key when both spellings occur. Walk the original
  structure first, validating scalar byte limits, collection lengths, nesting,
  timestamp syntax, and rank/count bounds before creating any owned copy.
  Canonicalize keys recursively to Strings only after that bounded pass.
  Publication may precede observation; require first_seen<=last_seen
  and increasing snapshot times. Rank map IDs need canonical syntax but need
  not remain in candidates; each rank Integer1..count, each count Integer0..100,
  map length<=count, no duplicate ranks. Fingerprint is lowercase64hex.
  `scoring_version` must be a bounded printable string; recognized-envelope
  old scoring version/fingerprint triggers reset after validation, not partial
  reuse. Unknown schema versions fail rather than guessing a migration.

  Serialize only the bounded canonical copy to confirm JSON-safe output and
  final byte size, catching generator/parser/encoding failures as safe
  `invalid_state`. Oversize maps/arrays are rejected before serialization and
  before the owned copy. No state dumping in errors. All mutation thereafter is
  on owned copies. The constructor returns the nested
  `RedditRssState::Transition` from `advance`; do not define or test a separate
  top-level Transition constant.

- [x] **Step 4: Implement the transition in this exact order.**

  ```text
  Take owned copy of prior candidates and polls.
  If history gap>3600, time<=last poll, or saved observation time>now+300:
    clear polls, reset started_at to now, set history_gap; preserve candidates.
    On clock rollback, clamp saved first_seen/last_seen/last_truncated to <=now.
  Capture previous_poll (last retained poll or nil) and previous candidate IDs.
  Merge pages in new, rising, top precedence; identity/date conflicts fail.
    Ignore publication>now+300 and count unique excluded IDs.
    For valid existing record keep first_seen; update last_seen and first preferred title.
    For new record set first_seen=last_seen=now.
  Remove candidates published or last seen <=now-172800.
  If >2000: sort [published_at, last_seen_at, id] ascending, evict earliest excess;
    set last_truncated_at=now.
  Append {at:now, counts, top_ranks, rising_ranks}; retain last4.
  Set started_at on cold start; build all string-keyed ISO8601 state fields.
  Validate output state and final byte cap; return Transition with flags and prior signals.
  ```

  The persistent snapshots include valid age-ineligible ranks because their
  original denominators matter. They exclude future-skew-rejected IDs while
  retaining raw counts. `future_exclusion_count` is unique post IDs across all
  feeds. `advance` must not mutate previously returned Transitions or its raw
  context; a second call is independent. Do not use a candidate's newly merged
  presence to decide whether it was known in the preceding observation.

- [x] **Step 5: Run state tests green and review bounds.** Ensure a 48-hour
  eviction is not accidentally implemented with last successful fetch time or
  item `retention_ttl_minutes`.
- [x] **Step 6: Commit** `feat: retain bounded Reddit RSS observation state`.

### Task 4: Deterministic prominence and observed-decile selection

**Files:** activity/activity tests; `lib/cybort.rb` require.
**Consumes:** Transition, pages, normalized weights, now, final limit.
**Produces:** selected rows and allowlisted metadata; state is read-only input.

- [x] **Step 1: Write exact arithmetic/selection tests.** Cover absent/singleton/
  first/last/interior ranks; cold renormalization; known/new candidate momentum;
  persistence1/2/3/4 windows; gap reset; all tie breakers; no signals; old/future
  candidates; caps; separate/pooled groups; configuration weight changes.

  ```ruby
  def test_prominence_uses_raw_denominator_and_handles_singletons
    assert_equal 1_000_000, Cybort::RedditRssActivity.prominence(count: 1, rank: 1)
    assert_equal 0, Cybort::RedditRssActivity.prominence(count: 3, rank: nil)
    assert_equal 500_000, Cybort::RedditRssActivity.prominence(count: 3, rank: 2)
    assert_equal 0, Cybort::RedditRssActivity.prominence(count: 3, rank: 3)
  end
  ```

  Required quota case: 20 age-eligible observed candidates, 5 currently
  signalled, limit100 =>2 results, not1. With limit1 =>1 and selection_capped.
  With20 observed and1 signalled =>1 without selection_capped. M=9 =>at most1
  low-sample; M=10 =>1 not low-sample; M=0 =>empty. Test score example: top1/3,
  rising2/3, previous prominence0.5, known candidate, persistence2/4 =>
  `550000 + 150000 + 100000 + 25000 = 825000`. Cold counterpart is823529.

- [x] **Step 2: Run** `bundle exec ruby -Itest test/reddit_rss_activity_test.rb` red.

- [x] **Step 3: Implement fixed-point helpers and selection.**

  ```ruby
  SCALE = 1_000_000
  def self.prominence(count:, rank:)
    return 0 if rank.nil?
    return SCALE if count == 1
    SCALE * (count - rank) / [count - 1, 1].max
  end

  def self.components(top:, rising:, previous:, known:, appearances:, poll_count:)
    {"top" => top, "rising" => rising,
     "momentum" => known ? [[([top, rising].max - previous) * 4, 0].max, SCALE].min : 0,
     "persistence" => SCALE * appearances / poll_count}
  end

  def self.weighted_score(components:, weights:, cold:)
    active = cold ? weights.slice("top", "rising") : weights
    active.sum { |name, weight| weight * components.fetch(name) } / active.values.sum
  end
  ```

  `select` constructs D from state candidates in the inclusive window, then S
  using current rank maps. Build previous prominence from previous_poll's own
  raw counts/ranks, never this poll's denominator. Persistence counts OR of
  top/rising presence per stored snapshot, not two appearances in one poll.
  Sort rows using `[-score, top_rank || 101, rising_rank || 101,
  -published_at.to_r, id]`. Select `min((M+9)/10, limit, S.length)` only when
  both sets nonempty. Set rank/priority/ordinal per spec after final selection.

  Output `info` exact keys: `kind`, `subreddit`, `scoring_version`,
  `selection_rank`, `activity_score_millionths`, `top_prominence_millionths`,
  `rising_prominence_millionths`, `momentum_millionths`,
  `persistence_millionths`, `top_rank`, `rising_rank`, `top_count`,
  `rising_count`, `previous_top_rank`, `previous_rising_rank`,
  `top_rank_change`, `rising_rank_change`, `age_seconds`,
  `observed_candidate_count`, `signalled_candidate_count`,
  `observed_percentile_millionths`, and `confidence` (flag Hash).
  On cold history expose both disabled history components as zero in `info`,
  even if the internal first-poll persistence calculation is one.

  Success metadata exact keys: `source` (`reddit_rss`), `scoring_version`,
  `new_count`, `top_count`, `rising_count`, `observed_candidate_count`,
  `signalled_candidate_count`, `selected_count`, `history_count`,
  `future_exclusion_count`, `confidence`. Confidence exact keys are the nine
  flags in the spec. Build fresh allowlisted hashes; never merge source records
  into diagnostics. `window_partial` uses the oldest current new publication
  (or true if none). `selection_capped = limit < min((M+9)/10, S.length)`.

- [x] **Step 4: Run scoring tests green.** Test integer results exactly, not
  broad float tolerances or ordering-only assertions.
- Evidence: focused activity tests pass with 15 runs and 51 assertions; the
  full offline suite passes with 302 runs and 1,424 assertions. Review
  follow-up covers known/new momentum, persistence windows, gap reset,
  low-sample boundaries, eligibility boundaries, tie-breakers, and custom
  weights.
- [x] **Step 5: Commit** `feat: rank Reddit RSS observed candidates deterministically`.

### Task 5: Adapter composition, configuration, and snapshot integration

**Files:** adapter and adapter tests; requires/registry/registry tests; new
system test file; persistence tests; canonical example and README current-use
section. Keep historical OAuth section intact.
**Consumes:** all four component contracts; Base/FetchResult/Persistence.
**Produces:** working opt-in `reddit_rss` and offline transaction evidence.

- [ ] **Step 1: Write configuration, cache, and adapter failures red.**
  Validate name counts/types/control/path injection, User-Agent max256/format,
  integer limits1/100 valid0/101 invalid, weights exact keys/types/sum,
  unknown/credential source options rejected, and String/Symbol duplicate keys
  rejected in both the source-option map and nested weight map. No I/O in static
  validation.
  Fresh cache must work with an HTTP/gate object that raises if touched.
  Missing state initializes only on remote fetch; cache does not manufacture
  observations. Full parser/client path uses recording fake + injected gate.
  A malformed third feed after two successes must return no Items or state.

- [ ] **Step 2: Run** new adapter tests and registry tests red.

- [ ] **Step 3: Implement adapter configuration and composition.**
  Normalize only source options (common fields already live on Instance),
  accepting exactly the three allowed keys `subreddits`, `user_agent`, and
  `activity_weights`, plus no others. Validate with static messages that do not
  echo inputs. Normalize group sorted/downcased/unique after validating all
  original entries (raw array length1..10); normalize weight keys without
  accepting conflicting symbol/string duplicates. Defaults exactly as spec.
  Use existing `RedditClient::USER_AGENT_PATTERN` for compatibility without
  constructing an OAuth client; keep its credential validators out of this path.
  Constructor accepts optional `coordinator: RedditRssCoordinator.default` and
  calls Base; registry needs no new kwargs or executable dependencies.

  ```ruby
  def fetch_from_source
    deadline = monotonic_clock.call + 180
    state = RedditRssState.new(raw: context[:sync_state],
      subreddits: @subreddits, weights: @weights)
    ensure_attempt!(deadline, :state)
    client = RedditRssClient.new(http_client: http_client,
      monotonic_clock: monotonic_clock, coordinator: @coordinator)
    pages = %w[new rising top].to_h do |sort|
      [sort, client.fetch(sort: sort, subreddits: @subreddits,
        user_agent: @user_agent, deadline_monotonic: deadline)]
    end
    fetched_at = clock.call
    transition = state.advance(pages: pages, now: fetched_at)
    ensure_attempt!(deadline, :state)
    selection = RedditRssActivity.select(transition: transition, pages: pages,
      weights: @weights, now: fetched_at, limit: instance.num_items_to_fetch)
    items = selection.fetch(:selected).map do |row|
      short_id = row.fetch(:id).delete_prefix("t3_")
      Item.new(instance_id: instance.id, canonical_id: row.fetch(:id),
        urls: ["https://www.reddit.com/r/#{row.fetch(:subreddit)}/comments/#{short_id}/"],
        fetched_at: fetched_at, remote_created_at: row.fetch(:published_at),
        title: row.fetch(:title), body: nil, action_item: false,
        priority: row.fetch(:priority), info: row.fetch(:info))
    end
    ensure_attempt!(deadline, :selection)
    {items: items, sync_state: transition.state,
     metadata: selection.fetch(:metadata), replace_existing_items: true}
  end
  ```

  Define private `ensure_attempt!(deadline, operation)` to compare injected
  monotonic clock strictly `<`, otherwise raise safe deadline error. Require
  files in errors/coordinator/client/state/activity/adapter order; register
  `registry.register("reddit_rss", Adapters::RedditRSS)` and leave other entries.

- [ ] **Step 4: Add isolated CLI/SQLite integration tests.**
  New `test/system/reddit_rss_system_test.rb` avoids enlarging the existing
  Gmail-heavy system file. Use local installation/config/SQLite, fake HTTP and
  private injected clocks; no real user config. Core scenarios:

  | Scenario | Required assertions |
  |---|---|
  | Two complete polls | State carries unselected candidates; second poll has history; selected keys upsert without duplicates |
  | New/rising/top fails separately | Old Items, state JSON and last_successful_fetch unchanged; failure history appended |
  | Complete empty three feeds | Selected Items cleared, poll appended, bounded eligible candidate history retained |
  | Warm cache | Zero requests, no extra poll, no state pruning |
  | Forced fetch | Three requests despite cache, no executable checks |
  | RSS connector fails + ordinary RSS succeeds | Exit1 partial failure and healthy source persisted |
  | Two RSS groups | Separate state/universe/tokens absent, shared rate lane |
  | Transaction fails after replacement | Old selection, old state, old freshness restored together |
  | Diagnostics/history | Body/author/User-Agent/error-content sentinels absent; counts/flags present |

  For rollback, mirror `test/persistence_test.rb`'s scoped singleton override
  of `insert_fetch_run`, restoring in `ensure` (Minitest lacks object.stub).
  Seed nontrivial state, write replacement with changed state, inject failure,
  then compare both `context_for[:sync_state]` and item IDs to prior values.
  This extends tests, not persistence code.

  Add a real two-poll persistence roundtrip: write the first complete poll to
  SQLite, read `context_for(instance_id:)` (whose `sync_state` keys are
  recursively symbolized), pass that state into the second adapter poll, write
  it, and read `context_for` again. Assert the second stored state has two poll
  snapshots and that the JSON persisted in `adapter_instances.sync_state_json`
  still uses string keys. This is an end-to-end history test, not a
  `Transition`-constant existence test, and requires no persistence change.

  Use explicit `--json` when parsing CLI output and `output_mode: :diagnostic`
  for human message assertions. Common persistence metadata adds counts such
  as `items_pruned`; assert source allowlists before persistence and permitted
  generic additions after persistence, not impossible exact end-to-end equality.

  Inject the fake monotonic clock and gate through a test-only registry factory
  so CLI tests never reach the default gate's real sleeper:

  ```ruby
  registry = Cybort::AdapterRegistry.default
  registry.register("reddit_rss",
    ->(**kwargs) { Cybort::Adapters::RedditRSS.new(**kwargs.merge(
      coordinator: fake_gate, monotonic_clock: fake_monotonic_clock)) },
    validate_configuration: ->(instance) { Cybort::Adapters::RedditRSS.validate_configuration!(instance) })
  ```

  Here `fake_gate` is a Task2 coordinator with an injected sleeper that advances
  the same `fake_monotonic_clock`; use a mutex-protected clock when shared
  across instance threads. Pass `registry:` to `CLI.start`. No runtime registry
  injection changes are needed.

- [ ] **Step 5: Publish the commented example and README capability boundary.**
  Copy the spec example as commented TOML into `.cybort.example.toml`, keeping
  existing OAuth/Gmail examples. README links there and explains new IDs,
  pooled vs separate ranking, observed-only denominator, cache/stale behavior,
  external15-minute invocation, process-only backoff, no private messages,
  publication/order/access release gates. Label experimental; do not claim
  unauthenticated means exempt from Reddit policies.

- [ ] **Step 6: Run focused adapter/registry/system/persistence tests green.**
  `bundle exec ruby -Itest test/system/reddit_rss_system_test.rb` and the three
  other named files. Repair only demonstrated implementation defects.
- [ ] **Step 7: Commit** `feat: integrate public Reddit RSS snapshots`.

### Task 6: Whole-branch review, records, and release status

**Files:** AGENTS, LEARNINGS, ADR0006/index, spec/plan status; source/test fixes
only if review evidence requires them.
**Consumes:** implemented connector and covering tests.
**Produces:** reviewed, offline-verified implementation with honest live status.

- [ ] **Step 1: Review the complete diff.** Check no accidental OAuth/Gmail
  replacement; only one shared production utility change (HTTP-date rate
  parsing); no schema/persistence writes; bounds before copies; one time basis
  for scoring; current and previous denominators not mixed; no unsafe XML
  parsing/URL fallback; leased rate lane always released. Delegate fixes/tests
  per execution instructions; root reviews amended code.
- [ ] **Step 2: Run full offline verification through the test worker.**
  `bundle exec rake test`; require zero failures/errors, disclose skips.
  Check `git diff --check`, local documentation links, unchanged Gemfile/lock
  and schema, no production OAuth/HTML/JSON calls from the RSS adapter. Never
  infer a live success or state a test count before the actual report.
- [ ] **Step 3: Record durable knowledge.** AGENTS describes the new registered
  adapter while retaining OAuth-specific invariants. ADR0006/index distinguish
  accepted decision, implemented status, and live verification. LEARNINGS gets
  dated observation/evidence/impact/next action only for actual findings;
  preserve all historical notes. Keep the input sketch unchanged.
- [ ] **Step 4: Evaluate live gate separately.** Only with permitted access,
  use the three documented public routes and an accurately identifying
  User-Agent at low volume; verify feed identity, creation dates, ordering,
  combined groups, limits, and two legitimate poll cycles. No changing hosts
  or identities to defeat restrictions. If unavailable, record gate open,
  connector experimental, and exactly which contracts remain unverified.
- [ ] **Step 5: Commit** `docs: record Reddit RSS verification and limits`.
  Hand off counts, branch, setup link, and open live gates; do not install a
  scheduler, activate user configuration, or start implementation of another
  feature without its own authorization.

## Spec-to-task coverage / self-review

| Requirement | Task |
|---|---|
| Public Atom identity/publication/body-free parsing and safe errors | 1 |
| Fixed requests/deadlines/pacing/Retry-After/cooldown | 2 |
| Three-feed union, finite state/history, eviction/reset | 3 |
| Raw ranks, first-poll weights, momentum/persistence, observed denominator | 4 |
| Explicit adapter/config/migration/cache/atomic snapshots | 5 |
| Offline evidence, durable records, access/shape/order release gates | 6 |

Planning self-review: names/signatures/schema/units checked across tasks;
singleton prominence corrected; current-signal requirement separated from the
observed denominator; candidate lifetime separated from item retention;
HTTP-date handling placed before the existing safe exception boundary; no
promise of durable cross-run backoff or live-verified ranking. Document-only
validation does not run the implementation commands above.
