# Reddit Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an offline-tested direct OAuth Reddit adapter that collects unread direct-message headers and deterministically ranked active threads from the user's effective subreddit scope without storing Reddit bodies.

**Architecture:** Extend the injectable HTTP boundary with safe form POSTs, put OAuth/listing/rate mechanics in `RedditClient`, and keep ranking in a pure `RedditActivity` module. `Adapters::Reddit` composes those units and returns ordinary `Item`/`FetchResult` values, so orchestration, SQLite writes, caching, partial failure, and optional per-instance retention remain unchanged.

**Tech Stack:** Ruby 4.0.1, Net::HTTP, JSON, URI, Base64, SQLite3, TOML, Minitest

**Spec:** `docs/superpowers/specs/2026-09-05-reddit-integration-design.md`

## Global Constraints

- Use only Reddit's documented OAuth Data API; do not scrape pages, use first-party credentials, or call undocumented Sendbird/chat endpoints.
- Consumer Reddit Chat is not collected in V1. Successful fetch metadata must say `chat_collection: "unsupported_by_documented_data_api"`.
- Required OAuth scopes are `read`, `mysubreddits`, and `privatemessages`; provision only those scopes, while accepting a token response that contains at least them or `*`.
- Never persist or expose `client_id`, `client_secret`, `refresh_token`, access tokens, authorization headers, HTTP/form bodies, usernames, subreddit membership, authors, or raw API payloads in result/error metadata.
- `include_subreddits` and `exclude_subreddits` default to empty arrays, accept at most 100 names each, normalize case-insensitively, and exclusions win.
- Reddit `num_items_to_fetch` must be an integer from 1 through 100 and caps the combined selected message/thread items for one remote fetch.
- The effective subreddit set is `(all subscriptions UNION explicit inclusions) MINUS exclusions`.
- Paginate subscribed-subreddit discovery to completion; scan one page of at most 100 candidates per hot listing; batch explicit additions by 25 names; make a dedicated `r/news` hot request when `news` is effective.
- One remote Reddit fetch may make at most 90 HTTP requests including token exchange. Do not sleep or retry automatically.
- Direct messages precede detected `r/news` megathreads, which precede other activity-ranked threads before the one combined limit is applied.
- Use the exact integer activity and tie-break formulas in the spec. Store Reddit's visible `score` as `vote_score`, not as an exact upvote count.
- Message and thread `body` values are always `nil`; never copy self-text, comments, authors, media, thumbnails, or outbound submission URLs.
- Preserve the existing adapter/orchestrator/persistence contract. Do not add tables, columns, adapter SQL, a Reddit-specific cleanup path, or a global CLI-order change.
- Existing optional `retention_ttl_minutes` remains the only local item-cleanup policy. Cache hits and failures do not prune.
- Tests must use local fixtures and injected clients/transports; they must not contact Reddit or perform a real OAuth flow.
- Do not modify `docs/initial-spitballing.md`.

---

## File Map

| File | Responsibility |
|---|---|
| `lib/cybort/errors.rb` | Add a body-free `HttpError` with allowlisted status/rate metadata. |
| `lib/cybort/http_client.rb` | Add form POST transport and use one safe 2xx/error boundary for GET and POST. |
| `test/errors_test.rb` | Prove HTTP metadata allowlisting and secret/body rejection. |
| `test/http_client_test.rb` | Prove form encoding, headers, and safe non-2xx behavior. |
| `lib/cybort/reddit_client.rb` | Own token refresh, required-scope checks, OAuth GETs, listings, pagination, request budget, JSON shape checks, and rate metadata. |
| `test/reddit_client_test.rb` | Lock down OAuth, pagination, request/rate behavior, and safe failures. |
| `lib/cybort/reddit_activity.rb` | Define thread candidates and pure megathread/scoring/ranking/priority functions. |
| `test/reddit_activity_test.rb` | Prove the exact deterministic ranking contract. |
| `lib/cybort/adapters/reddit.rb` | Validate Reddit options, discover effective scope, fetch bounded candidates/messages, normalize items, and return safe metadata. |
| `test/adapters/reddit_test.rb` | Prove scope, batching, filtering, selection, normalization, and malformed-source behavior. |
| `test/fixtures/reddit/token.json` | Sanitized successful token response. |
| `test/fixtures/reddit/subscriptions_page_1.json` | First subscription listing page with an `after` fullname. |
| `test/fixtures/reddit/subscriptions_page_2.json` | Final subscription listing page. |
| `test/fixtures/reddit/unread.json` | Mixed unread `t4` message and non-message inbox children. |
| `test/fixtures/reddit/home_hot.json` | Personalized hot candidates including an out-of-scope recommendation. |
| `test/fixtures/reddit/included_hot.json` | Explicit-subreddit candidate and a duplicate. |
| `test/fixtures/reddit/news_hot.json` | `r/news` megathread and unrelated sticky candidates. |
| `lib/cybort/adapter_registry.rb` | Register the direct HTTP `reddit` adapter with no executable dependency. |
| `lib/cybort.rb` | Require the Reddit client, activity module, and adapter in dependency order. |
| `test/adapter_registry_test.rb` | Prove default registration and aggregated preflight validation. |
| `test/system/cli_system_test.rb` | Prove forced fetch, cache, safe failure, retention, and RSS isolation through the CLI. |
| `README.md` | Document setup, limitations, scope, metric, data minimization, retention, and manual smoke test. |
| `AGENTS.md` | Record the implemented adapter contract and release gate as durable invariants. |
| `docs/LEARNINGS.md` | Record only evidence from the authenticated smoke test if one is actually run. |

No change is planned for `lib/cybort/item.rb`, `lib/cybort/fetch_result.rb`,
`lib/cybort/orchestrator.rb`, `lib/cybort/persistence.rb`, or
`lib/cybort/schema.rb`.

---

### Task 1: Add Safe Form POST and HTTP Failure Metadata

**Files:**
- Modify: `test/errors_test.rb`
- Modify: `test/http_client_test.rb`
- Modify: `lib/cybort/errors.rb`
- Modify: `lib/cybort/http_client.rb`

**Interfaces:**
- Consumes: existing `HttpClient#get(url, headers: {})` and transport response objects.
- Produces: `HttpClient#post_form(url, form:, headers: {}) -> HttpResponse`.
- Produces: `HttpError#safe_metadata -> Hash` with only `status`, `retry_after_seconds`, `ratelimit_used`, `ratelimit_remaining`, and `ratelimit_reset_seconds` when present.
- Preserves: existing GET callers and `SourceError` rescue behavior.

- [ ] **Step 1: Write failing error and HTTP-client tests**

Add to `test/errors_test.rb`:

```ruby
def test_http_error_exposes_only_allowlisted_numeric_metadata
  error = Cybort::HttpError.new(
    429,
    headers: {
      "Retry-After" => "12",
      "X-Ratelimit-Used" => "3.5",
      "X-Ratelimit-Remaining" => "0",
      "X-Ratelimit-Reset" => "42",
      "Authorization" => "Bearer secret"
    }
  )

  assert_equal "HTTP request failed with status 429", error.message
  assert_equal 429, error.safe_metadata.fetch(:status)
  assert_equal 12, error.safe_metadata.fetch(:retry_after_seconds)
  assert_equal 3.5, error.safe_metadata.fetch(:ratelimit_used)
  assert_equal 0.0, error.safe_metadata.fetch(:ratelimit_remaining)
  assert_equal 42.0, error.safe_metadata.fetch(:ratelimit_reset_seconds)
  refute_includes error.safe_metadata.to_s, "secret"
end
```

Extend the test transport in `test/http_client_test.rb`:

```ruby
def post_form(url, form:, headers:)
  @calls << [url, form, headers]
  @response
end
```

Add:

```ruby
def test_posts_url_encoded_form_without_putting_secrets_in_url
  transport = Transport.new(Response.new(status: 200, headers: {}, body: "{}"))
  client = Cybort::HttpClient.new(transport: transport)

  client.post_form(
    "https://www.reddit.com/api/v1/access_token",
    form: { grant_type: "refresh_token", refresh_token: "a+b secret" },
    headers: { "Authorization" => "Basic opaque" }
  )

  url, form, headers = transport.calls.fetch(0)
  assert_equal "https://www.reddit.com/api/v1/access_token", url
  assert_equal({ grant_type: "refresh_token", refresh_token: "a+b secret" }, form)
  assert_equal "Basic opaque", headers.fetch("Authorization")
end

def test_non_success_raises_body_free_http_error
  transport = Transport.new(Response.new(
    status: 429,
    headers: { "retry-after" => "7", "authorization" => "Bearer secret" },
    body: "private response body"
  ))
  client = Cybort::HttpClient.new(transport: transport)

  error = assert_raises(Cybort::HttpError) do
    client.get("https://oauth.reddit.com/hot")
  end

  assert_equal 7, error.safe_metadata.fetch(:retry_after_seconds)
  refute_includes error.message, "private"
  refute_includes error.safe_metadata.to_s, "secret"
end
```

- [ ] **Step 2: Run focused tests and verify failure**

Run:

```bash
bundle exec ruby -Itest test/errors_test.rb
bundle exec ruby -Itest test/http_client_test.rb
```

Expected: FAIL because `HttpError` and `post_form` do not exist.

- [ ] **Step 3: Implement the allowlisted error**

Append inside `module Cybort` in `lib/cybort/errors.rb`:

```ruby
class HttpError < SourceError
  HEADER_KEYS = {
    "retry-after" => [:retry_after_seconds, :integer],
    "x-ratelimit-used" => [:ratelimit_used, :float],
    "x-ratelimit-remaining" => [:ratelimit_remaining, :float],
    "x-ratelimit-reset" => [:ratelimit_reset_seconds, :float]
  }.freeze

  attr_reader :safe_metadata

  def initialize(status, headers: {})
    @safe_metadata = { status: Integer(status) }
    headers.each do |name, value|
      definition = HEADER_KEYS[name.to_s.downcase]
      next unless definition

      key, type = definition
      @safe_metadata[key] = type == :integer ? Integer(value) : Float(value)
    rescue ArgumentError, TypeError
      next
    end
    @safe_metadata.freeze
    super("HTTP request failed with status #{@safe_metadata.fetch(:status)}")
  end
end
```

- [ ] **Step 4: Implement form POST and shared response validation**

In `lib/cybort/http_client.rb`, add `require "uri"` if needed and implement:

```ruby
def post_form(url, form:, headers: {})
  ensure_success(@transport.post_form(url, form: form, headers: headers))
end

private

def ensure_success(response)
  status = response.status.to_i
  raise HttpError.new(status, headers: response.headers || {}) unless status.between?(200, 299)

  HttpResponse.new(status: status, headers: response.headers || {}, body: response.body)
end
```

Change `#get` to call `ensure_success(@transport.get(...))`. Add to
`NetHttpTransport`:

```ruby
def post_form(url, form:, headers: {})
  uri = URI.parse(url)
  request = Net::HTTP::Post.new(uri)
  headers.each { |name, value| request[name] = value }
  request["Content-Type"] ||= "application/x-www-form-urlencoded"
  request.body = URI.encode_www_form(form)
  perform(uri, request)
rescue URI::InvalidURIError, SocketError, SystemCallError => error
  raise SourceError, error.message
end
```

Extract the existing `Net::HTTP.start` response mapping into private
`perform(uri, request)` and have `#get` call it:

```ruby
def perform(uri, request)
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
    http.request(request)
  end
  HttpResponse.new(
    status: response.code.to_i,
    headers: response.each_header.to_h,
    body: response.body
  )
end
```

Do not include request/response bodies or headers in exception messages.

- [ ] **Step 5: Run the focused and existing adapter tests**

Run:

```bash
bundle exec ruby -Itest test/errors_test.rb
bundle exec ruby -Itest test/http_client_test.rb
bundle exec ruby -Itest test/adapters/rss_test.rb
bundle exec ruby -Itest test/adapters/github_test.rb
```

Expected: PASS with no failures or errors.

- [ ] **Step 6: Commit the HTTP boundary**

```bash
git add lib/cybort/errors.rb lib/cybort/http_client.rb test/errors_test.rb test/http_client_test.rb
git commit -m "feat: add safe form HTTP requests"
```

---

### Task 2: Implement the Reddit OAuth and Listing Client

**Files:**
- Create: `lib/cybort/reddit_client.rb`
- Create: `test/reddit_client_test.rb`
- Create: `test/fixtures/reddit/token.json`
- Create: `test/fixtures/reddit/subscriptions_page_1.json`
- Create: `test/fixtures/reddit/subscriptions_page_2.json`
- Modify: `lib/cybort.rb`

**Interfaces:**
- Consumes: `RedditClient.new(http_client:, client_id:, client_secret:, refresh_token:, user_agent:, request_budget: 90)`.
- Produces: `#authenticate! -> self`, validating `read mysubreddits privatemessages` or `*`.
- Produces: `#listing(path, params:, paginate:, max_items:) -> Array<Hash>` of child objects.
- Produces: `#request_count -> Integer` and `#rate_metadata -> Hash`.
- Raises: `SourceError`/`HttpError` with body-free safe metadata.

- [ ] **Step 1: Add exact token and pagination fixtures**

Create `test/fixtures/reddit/token.json`:

```json
{"access_token":"fixture-access","token_type":"bearer","expires_in":3600,"scope":"read mysubreddits privatemessages"}
```

Create `test/fixtures/reddit/subscriptions_page_1.json`:

```json
{"kind":"Listing","data":{"after":"t5_next","children":[{"kind":"t5","data":{"display_name":"Ruby"}}]}}
```

Create `test/fixtures/reddit/subscriptions_page_2.json`:

```json
{"kind":"Listing","data":{"after":null,"children":[{"kind":"t5","data":{"display_name":"news"}}]}}
```

- [ ] **Step 2: Write failing OAuth, headers, and pagination tests**

In `test/reddit_client_test.rb`, define this queue fake and helpers, then add the
OAuth/pagination assertion:

```ruby
class QueueHttpClient
  attr_reader :post_calls, :get_calls

  def initialize(post_responses:, get_responses:)
    @post_responses = post_responses.dup
    @get_responses = get_responses.dup
    @post_calls = []
    @get_calls = []
  end

  def post_form(url, form:, headers: {})
    @post_calls << [url, form, headers]
    value = @post_responses.shift
    raise value if value.is_a?(Exception)
    value
  end

  def get(url, headers: {})
    @get_calls << [url, headers]
    value = @get_responses.shift
    raise value if value.is_a?(Exception)
    value
  end
end

USER_AGENT = "macos:com.example.cybort:v0.1.0 (by /u/example_user)"

def fixture(name)
  File.read(File.expand_path("fixtures/reddit/#{name}", __dir__))
end

def response(body, headers: {})
  Cybort::HttpResponse.new(status: 200, headers: headers, body: body)
end

def rate_headers(remaining:)
  { "X-Ratelimit-Used" => "2", "X-Ratelimit-Remaining" => remaining,
    "X-Ratelimit-Reset" => "30" }
end

def reddit_client(http, request_budget: 90)
  Cybort::RedditClient.new(
    http_client: http, client_id: "client", client_secret: "secret",
    refresh_token: "fixture-refresh", user_agent: USER_AGENT,
    request_budget: request_budget
  )
end
```

```ruby
def test_refreshes_token_and_paginates_listing_with_oauth_headers
  http = QueueHttpClient.new(
    post_responses: [response(fixture("token.json"))],
    get_responses: [
      response(fixture("subscriptions_page_1.json"), headers: rate_headers(remaining: "98")),
      response(fixture("subscriptions_page_2.json"), headers: rate_headers(remaining: "97"))
    ]
  )
  client = reddit_client(http)

  client.authenticate!
  children = client.listing(
    "/subreddits/mine/subscriber",
    params: { limit: 100 },
    paginate: true,
    max_items: nil
  )

  assert_equal %w[Ruby news], children.map { |child| child.dig("data", "display_name") }
  assert_equal 3, client.request_count
  assert_equal 97.0, client.rate_metadata.fetch(:ratelimit_remaining)
  assert_equal "Basic #{Base64.strict_encode64("client:secret")}", http.post_calls.first.fetch(2).fetch("Authorization")
  assert_equal "Bearer fixture-access", http.get_calls.first.fetch(1).fetch("Authorization")
  assert_equal USER_AGENT, http.get_calls.first.fetch(1).fetch("User-Agent")
  assert_includes http.get_calls.first.fetch(0), "raw_json=1"
  assert_includes http.get_calls.last.fetch(0), "after=t5_next"
end
```

Also test: missing required token scope, malformed token JSON, malformed second
listing page, `max_items` truncation, a 90-request local budget, and local refusal
to issue a next request after a response reports `X-Ratelimit-Remaining: 0`.
Every failure assertion must refute the configured refresh/access token and a
fixture body in both `error.message` and `error.safe_metadata` when available.

- [ ] **Step 3: Run the client test and verify failure**

Run:

```bash
bundle exec ruby -Itest test/reddit_client_test.rb
```

Expected: FAIL because `Cybort::RedditClient` is undefined.

- [ ] **Step 4: Implement token refresh and safe request state**

Create `lib/cybort/reddit_client.rb` with these constants and public skeleton:

```ruby
require "base64"
require "json"
require "uri"

module Cybort
  class RedditClient
    TOKEN_URL = "https://www.reddit.com/api/v1/access_token"
    API_URL = "https://oauth.reddit.com"
    REQUIRED_SCOPES = %w[mysubreddits privatemessages read].freeze

    attr_reader :request_count, :rate_metadata

    def initialize(http_client:, client_id:, client_secret:, refresh_token:, user_agent:, request_budget: 90)
      @http_client = http_client
      @client_id = client_id
      @client_secret = client_secret
      @refresh_token = refresh_token
      @user_agent = user_agent
      @request_budget = request_budget
      @request_count = 0
      @rate_metadata = {}
    end

    def authenticate!
      response = request do
        @http_client.post_form(
          TOKEN_URL,
          form: { grant_type: "refresh_token", refresh_token: @refresh_token },
          headers: {
            "Authorization" => "Basic #{Base64.strict_encode64("#{@client_id}:#{@client_secret}")}",
            "User-Agent" => @user_agent
          }
        )
      end
      payload = parse_object(response.body, "token")
      token = payload["access_token"]
      scopes = payload.fetch("scope", "").split
      unless token.is_a?(String) && !token.empty? &&
             (scopes.include?("*") || (REQUIRED_SCOPES - scopes).empty?)
        raise SourceError, "Reddit OAuth token is missing a bearer token or required scopes"
      end
      @access_token = token
      self
    end
  end
end
```

Do not retain the token response hash after extracting the access token and
scope strings. Error messages name only the operation/category.

- [ ] **Step 5: Implement listing pagination, budget, and rate parsing**

Implement `#listing` with this contract:

```ruby
def listing(path, params:, paginate:, max_items:)
  raise SourceError, "Reddit client is not authenticated" unless @access_token

  children = []
  after = nil
  loop do
    query = params.merge(raw_json: 1)
    query[:after] = after if after
    response = request do
      @http_client.get(
        "#{API_URL}#{path}?#{URI.encode_www_form(query)}",
        headers: { "Authorization" => "Bearer #{@access_token}", "User-Agent" => @user_agent }
      )
    end
    payload = parse_object(response.body, "listing")
    data = payload["data"]
    page = data.is_a?(Hash) ? data["children"] : nil
    raise SourceError, "Reddit listing has an invalid shape" unless page.is_a?(Array)

    children.concat(page)
    return children.first(max_items) if max_items && children.length >= max_items

    after = data["after"]
    break unless paginate && after
    raise SourceError, "Reddit listing has an invalid after fullname" unless after.is_a?(String) && !after.empty?
  end
  children
end
```

The private `request` increments before dispatch, rejects when the next request
would exceed `@request_budget`, rejects when the previous valid remaining value
is below 1, yields, and parses headers case-insensitively:

```ruby
RATE_HEADERS = {
  "x-ratelimit-used" => :ratelimit_used,
  "x-ratelimit-remaining" => :ratelimit_remaining,
  "x-ratelimit-reset" => :ratelimit_reset_seconds
}.freeze

def request
  raise SourceError, "Reddit request budget exhausted" if @request_count >= @request_budget
  if @rate_metadata[:ratelimit_remaining]&.<(1)
    raise SourceError, "Reddit rate limit exhausted"
  end

  @request_count += 1
  response = yield
  response.headers.each do |name, value|
    key = RATE_HEADERS[name.to_s.downcase]
    next unless key
    @rate_metadata[key] = Float(value)
  rescue ArgumentError, TypeError
    next
  end
  response
end

def parse_object(body, operation)
  value = JSON.parse(body)
  raise SourceError, "Reddit #{operation} response must be an object" unless value.is_a?(Hash)
  value
rescue JSON::ParserError
  raise SourceError, "Reddit #{operation} response is invalid JSON"
end
```

Ignore malformed individual rate values. `parse_object` rescues
`JSON::ParserError` and raises `SourceError` with a short operation-only message.

- [ ] **Step 6: Require the client and run its tests**

Add after `require "cybort/http_client"` in `lib/cybort.rb`:

```ruby
require "cybort/reddit_client"
```

Run:

```bash
bundle exec ruby -Itest test/reddit_client_test.rb
bundle exec ruby -Itest test/http_client_test.rb
```

Expected: PASS with no failures or errors.

- [ ] **Step 7: Commit the source client**

```bash
git add lib/cybort.rb lib/cybort/reddit_client.rb test/reddit_client_test.rb test/fixtures/reddit/token.json test/fixtures/reddit/subscriptions_page_1.json test/fixtures/reddit/subscriptions_page_2.json
git commit -m "feat: add Reddit OAuth client"
```

---

### Task 3: Implement Deterministic Reddit Activity Ranking

**Files:**
- Create: `lib/cybort/reddit_activity.rb`
- Create: `test/reddit_activity_test.rb`
- Modify: `lib/cybort.rb`

**Interfaces:**
- Produces: `RedditActivity::Candidate` with `fullname`, `subreddit`, `title`, `permalink`, `created_at`, `vote_score`, `comment_count`, and `stickied`.
- Produces: `.megathread?(candidate) -> true | false`.
- Produces: `.activity_score_milli(candidate, fetched_at:) -> Integer`.
- Produces: `.rank(candidates, fetched_at:) -> Array<Candidate>`.
- Produces: `.priority(rank_index:, candidate_count:) -> Integer` from 99 through 0.

- [ ] **Step 1: Write exact failing metric tests**

Create `test/reddit_activity_test.rb` with this candidate helper:

```ruby
FETCHED_AT = Time.utc(2026, 9, 5, 12)

def build_candidate(fullname: "t3_default", subreddit: "ruby", title: "Thread",
                    created_at: Time.utc(2026, 9, 5, 11), vote_score: 10,
                    comment_count: 5, stickied: false)
  Cybort::RedditActivity::Candidate.new(
    fullname: fullname, subreddit: subreddit, title: title,
    permalink: "/r/#{subreddit}/comments/default/thread/",
    created_at: created_at, vote_score: vote_score,
    comment_count: comment_count, stickied: stickied
  )
end
```

Add these core assertions:

```ruby
def test_integer_activity_score_uses_comment_weight_and_one_hour_floor
  candidate = build_candidate(vote_score: 100, comment_count: 50,
                              created_at: Time.utc(2026, 9, 5, 11, 30))

  assert_equal 200_000, Cybort::RedditActivity.activity_score_milli(
    candidate, fetched_at: Time.utc(2026, 9, 5, 12)
  )
end

def test_two_hour_old_candidate_divides_weighted_engagement_by_age
  candidate = build_candidate(vote_score: 100, comment_count: 50,
                              created_at: Time.utc(2026, 9, 5, 10))

  assert_equal 100_000, Cybort::RedditActivity.activity_score_milli(
    candidate, fetched_at: Time.utc(2026, 9, 5, 12)
  )
end

def test_rank_uses_every_tie_breaker_and_fullname_last
  candidates = [
    build_candidate(fullname: "t3_z", created_at: Time.utc(2026, 9, 5, 8), vote_score: 0, comment_count: 0),
    build_candidate(fullname: "t3_a", created_at: Time.utc(2026, 9, 5, 8), vote_score: 0, comment_count: 0),
    build_candidate(fullname: "t3_newer", created_at: Time.utc(2026, 9, 5, 9), vote_score: 0, comment_count: 0),
    build_candidate(fullname: "t3_votes", created_at: Time.utc(2026, 9, 5, 8), vote_score: 50, comment_count: 20),
    build_candidate(fullname: "t3_comments", created_at: Time.utc(2026, 9, 5, 8), vote_score: 20, comment_count: 35)
  ]
  ranked = Cybort::RedditActivity.rank(candidates, fetched_at: FETCHED_AT)

  assert_equal %w[t3_comments t3_votes t3_newer t3_a t3_z], ranked.map(&:fullname)
end

def test_only_titled_news_threads_are_megathreads
  assert Cybort::RedditActivity.megathread?(build_candidate(subreddit: "news", title: "Election Megathread"))
  assert Cybort::RedditActivity.megathread?(build_candidate(subreddit: "NEWS", title: "Live Thread: storm"))
  refute Cybort::RedditActivity.megathread?(build_candidate(subreddit: "news", title: "Daily discussion", stickied: true))
  refute Cybort::RedditActivity.megathread?(build_candidate(subreddit: "worldnews", title: "Election Megathread"))
end

def test_priority_spans_rank_range
  assert_equal 99, Cybort::RedditActivity.priority(rank_index: 0, candidate_count: 3)
  assert_equal 50, Cybort::RedditActivity.priority(rank_index: 1, candidate_count: 3)
  assert_equal 0, Cybort::RedditActivity.priority(rank_index: 2, candidate_count: 3)
  assert_equal 99, Cybort::RedditActivity.priority(rank_index: 0, candidate_count: 1)
end
```

Also assert that negative integer counts are treated as zero and non-integer
counts raise `ValidationError`.

- [ ] **Step 2: Run the activity test and verify failure**

Run:

```bash
bundle exec ruby -Itest test/reddit_activity_test.rb
```

Expected: FAIL because `Cybort::RedditActivity` is undefined.

- [ ] **Step 3: Implement the pure metric and stable rank**

Create `lib/cybort/reddit_activity.rb`:

```ruby
module Cybort
  module RedditActivity
    Candidate = Struct.new(
      :fullname, :subreddit, :title, :permalink, :created_at,
      :vote_score, :comment_count, :stickied,
      keyword_init: true
    )

    MEGATHREAD_PATTERN = /\bmega\s*thread\b|\blive\s+thread\b/i
    module_function

    def activity_score_milli(candidate, fetched_at:)
      vote_score = count(candidate.vote_score, "score")
      comment_count = count(candidate.comment_count, "num_comments")
      age_minutes = [((fetched_at - candidate.created_at) / 60).floor, 60].max
      ((vote_score + (2 * comment_count)) * 60_000) / age_minutes
    end

    def megathread?(candidate)
      candidate.subreddit.casecmp?("news") && candidate.title.match?(MEGATHREAD_PATTERN)
    end

    def rank(candidates, fetched_at:)
      candidates.sort_by do |candidate|
        [
          -activity_score_milli(candidate, fetched_at: fetched_at),
          -count(candidate.comment_count, "num_comments"),
          -count(candidate.vote_score, "score"),
          -candidate.created_at.to_f,
          candidate.fullname
        ]
      end
    end

    def priority(rank_index:, candidate_count:)
      raise ValidationError, "invalid Reddit rank" unless rank_index.between?(0, candidate_count - 1)
      99 - ((rank_index * 99) / [candidate_count - 1, 1].max)
    end

    def count(value, field)
      raise ValidationError, "Reddit #{field} must be an integer" unless value.is_a?(Integer)
      [value, 0].max
    end
    private_class_method :count
  end
end
```

- [ ] **Step 4: Require the module and run tests**

Add after the Reddit client require in `lib/cybort.rb`:

```ruby
require "cybort/reddit_activity"
```

Run:

```bash
bundle exec ruby -Itest test/reddit_activity_test.rb
bundle exec ruby -Itest test/item_test.rb
```

Expected: PASS with no failures or errors.

- [ ] **Step 5: Commit the metric**

```bash
git add lib/cybort.rb lib/cybort/reddit_activity.rb test/reddit_activity_test.rb
git commit -m "feat: rank Reddit thread activity"
```

---

### Task 4: Validate and Register Reddit Adapter Configuration

**Files:**
- Create: `lib/cybort/adapters/reddit.rb`
- Create: `test/adapters/reddit_test.rb`
- Modify: `lib/cybort.rb`
- Modify: `lib/cybort/adapter_registry.rb`
- Modify: `test/adapter_registry_test.rb`

**Interfaces:**
- Consumes: normal `Configuration::Instance#options`.
- Produces: `Adapters::Reddit.validate_configuration!(instance)` with no network or OAuth side effects.
- Produces: default registry entry `reddit` with zero executable dependencies.

- [ ] **Step 1: Write failing option-validation tests**

In `test/adapters/reddit_test.rb`, build an instance containing fixture-only
values for the four credentials and this User-Agent:

```ruby
USER_AGENT = "macos:com.example.cybort:v0.1.0 (by /u/example_user)"
```

Test that validation accepts omitted include/exclude arrays and values such as
`["news", "Ruby"]`. Add table-driven failures for each missing/blank credential,
control characters, malformed User-Agent, non-array lists, non-string names,
`"r/news"`, invalid punctuation, 101 names, and Reddit limits 0 and 101. Use
exact message fragments naming the invalid key but never its value.

Add to `test/adapter_registry_test.rb`:

```ruby
def test_default_registry_registers_reddit_without_executable_dependencies
  instance = Cybort::Configuration::Instance.new(
    id: "reddit", name: "Reddit", adapter: "reddit", ttl_minutes: 15,
    num_items_to_fetch: 10,
    options: {
      client_id: "client", client_secret: "secret", refresh_token: "refresh",
      user_agent: "macos:com.example.cybort:v0.1.0 (by /u/example_user)"
    }
  )

  registry = Cybort::AdapterRegistry.default
  registry.validate_configuration!(instance)
  assert_empty registry.dependencies_for(instance)
end
```

- [ ] **Step 2: Run focused tests and verify failure**

Run:

```bash
bundle exec ruby -Itest test/adapters/reddit_test.rb
bundle exec ruby -Itest test/adapter_registry_test.rb
```

Expected: FAIL because the Reddit adapter is undefined/unregistered.

- [ ] **Step 3: Implement side-effect-free validation**

Create `lib/cybort/adapters/reddit.rb` with constants and validator:

```ruby
module Cybort
  module Adapters
    class Reddit < Base
      MAX_ITEMS = 100
      MAX_CONFIGURED_SUBREDDITS = 100
      SUBREDDITS_PER_BATCH = 25
      SUBREDDIT_PATTERN = /\A[A-Za-z0-9_]{2,21}\z/
      USER_AGENT_PATTERN = /\A[^:\s]+:[^:\s]+:[^\s()]+ \(by \/u\/[A-Za-z0-9_-]+\)\z/
      CREDENTIAL_KEYS = %i[client_id client_secret refresh_token].freeze

      def self.validate_configuration!(instance)
        CREDENTIAL_KEYS.each do |key|
          value = instance.options[key]
          unless value.is_a?(String) && !value.empty? && value.each_codepoint.none? { |code| code < 32 || code == 127 }
            raise ConfigurationError, "reddit #{key} must be a nonblank printable string"
          end
        end
        user_agent = instance.options[:user_agent]
        unless user_agent.is_a?(String) && user_agent.match?(USER_AGENT_PATTERN)
          raise ConfigurationError, "reddit user_agent must use Reddit's descriptive format"
        end
        unless instance.num_items_to_fetch.is_a?(Integer) && instance.num_items_to_fetch.between?(1, MAX_ITEMS)
          raise ConfigurationError, "reddit num_items_to_fetch must be an integer from 1 through #{MAX_ITEMS}"
        end
        %i[include_subreddits exclude_subreddits].each do |key|
          validate_subreddits!(key, instance.options.fetch(key, []))
        end
      end

      def self.validate_subreddits!(key, values)
        unless values.is_a?(Array) && values.length <= MAX_CONFIGURED_SUBREDDITS &&
               values.all? { |value| value.is_a?(String) && value.match?(SUBREDDIT_PATTERN) }
          raise ConfigurationError, "reddit #{key} must contain at most 100 subreddit names"
        end
      end
      private_class_method :validate_subreddits!
    end
  end
end
```

- [ ] **Step 4: Require and register the adapter**

Add after the Gmail adapter require in `lib/cybort.rb`:

```ruby
require "cybort/adapters/reddit"
```

In `AdapterRegistry.default`, add:

```ruby
registry.register("reddit", Adapters::Reddit)
```

- [ ] **Step 5: Run focused configuration/registry tests**

Run:

```bash
bundle exec ruby -Itest test/adapters/reddit_test.rb
bundle exec ruby -Itest test/adapter_registry_test.rb
bundle exec ruby -Itest test/configuration_test.rb
```

Expected: PASS with no failures or errors. Reddit tests at this checkpoint cover
validation only.

- [ ] **Step 6: Commit registration and validation**

```bash
git add lib/cybort.rb lib/cybort/adapter_registry.rb lib/cybort/adapters/reddit.rb test/adapter_registry_test.rb test/adapters/reddit_test.rb
git commit -m "feat: validate Reddit adapter configuration"
```

---

### Task 5: Fetch, Select, and Normalize Reddit Items

**Files:**
- Modify: `lib/cybort/adapters/reddit.rb`
- Modify: `test/adapters/reddit_test.rb`
- Create: `test/fixtures/reddit/unread.json`
- Create: `test/fixtures/reddit/home_hot.json`
- Create: `test/fixtures/reddit/included_hot.json`
- Create: `test/fixtures/reddit/news_hot.json`

**Interfaces:**
- Consumes: `RedditClient#authenticate!`, `#listing`, `#request_count`, and `#rate_metadata` from Task 2.
- Consumes: `RedditActivity` candidate/ranking functions from Task 3.
- Produces: ordinary successful/failure `FetchResult` through `Adapters::Base#fetch`.
- Produces: only body-free `Item` values and safe aggregate metadata.

- [ ] **Step 1: Create sanitized source fixtures**

Create the fixtures with these exact payloads (line wrapping is optional).

`test/fixtures/reddit/unread.json`:

```json
{"kind":"Listing","data":{"after":null,"children":[{"kind":"t4","data":{"name":"t4_dm1","id":"dm1","subject":"Project update","created_utc":1788602400,"new":true,"body":"DO_NOT_STORE_MESSAGE_BODY","author":"private_user"}},{"kind":"t1","data":{"name":"t1_reply1","body":"DO_NOT_STORE_COMMENT_BODY"}}]}}
```

`test/fixtures/reddit/home_hot.json`:

```json
{"kind":"Listing","data":{"after":null,"children":[{"kind":"t3","data":{"name":"t3_ruby1","subreddit":"Ruby","title":"Ruby release discussion","permalink":"/r/ruby/comments/ruby1/release/","created_utc":1788598800,"score":200,"num_comments":120,"stickied":false,"selftext":"DO_NOT_STORE_SELF_TEXT"}},{"kind":"t3","data":{"name":"t3_memes1","subreddit":"memes","title":"Excluded","permalink":"/r/memes/comments/memes1/excluded/","created_utc":1788598800,"score":9999,"num_comments":9999,"stickied":false,"selftext":"DO_NOT_STORE_SELF_TEXT"}},{"kind":"t3","data":{"name":"t3_rec1","subreddit":"recommended","title":"DO_NOT_STORE_RECOMMENDATION","permalink":"/r/recommended/comments/rec1/nope/","created_utc":1788598800,"score":9999,"num_comments":9999,"stickied":false,"selftext":"DO_NOT_STORE_RECOMMENDATION"}}]}}
```

`test/fixtures/reddit/included_hot.json`:

```json
{"kind":"Listing","data":{"after":null,"children":[{"kind":"t3","data":{"name":"t3_extra1","subreddit":"extra","title":"Explicit discussion","permalink":"/r/extra/comments/extra1/discussion/","created_utc":1788595200,"score":100,"num_comments":200,"stickied":false,"selftext":"DO_NOT_STORE_SELF_TEXT"}},{"kind":"t3","data":{"name":"t3_ruby1","subreddit":"Ruby","title":"Ruby release discussion","permalink":"/r/ruby/comments/ruby1/release/","created_utc":1788598800,"score":200,"num_comments":120,"stickied":false,"selftext":"DO_NOT_STORE_SELF_TEXT"}}]}}
```

`test/fixtures/reddit/news_hot.json`:

```json
{"kind":"Listing","data":{"after":null,"children":[{"kind":"t3","data":{"name":"t3_mega","subreddit":"news","title":"Election Megathread","permalink":"/r/news/comments/mega/election/","created_utc":1788516000,"score":500,"num_comments":900,"stickied":true,"selftext":"DO_NOT_STORE_SELF_TEXT"}},{"kind":"t3","data":{"name":"t3_daily","subreddit":"news","title":"Daily discussion","permalink":"/r/news/comments/daily/discussion/","created_utc":1788598800,"score":800,"num_comments":500,"stickied":true,"selftext":"DO_NOT_STORE_SELF_TEXT"}}]}}
```

- [ ] **Step 2: Write failing scope/request tests**

Extend the adapter fake HTTP client so token POST and URL-matched listing GETs
return fixtures while recording every call. Add a test that configures
subscriptions `Ruby` and `news`, includes `Extra` twice with different case,
and excludes `memes`. Assert URLs include:

```ruby
assert requested_paths.include?("/subreddits/mine/subscriber")
assert requested_paths.include?("/message/unread")
assert requested_paths.include?("/hot")
assert requested_paths.any? { |path| path.include?("/r/extra/hot") }
assert requested_paths.any? { |path| path.include?("/r/news/hot") }
assert requested_urls.all? { |url| url.include?("raw_json=1") }
```

Assert excluded/recommended candidates never appear, the duplicate fullname
appears once, subscription pagination completes, additions are lowercase/sorted
and divided into groups of 25, and an empty effective set skips every hot
request but can still return unread messages.

- [ ] **Step 3: Write failing normalization and selection tests**

Assert the direct message is:

```ruby
assert_equal "t4_dm1", message.canonical_id
assert_equal ["https://www.reddit.com/message/messages/dm1"], message.urls
assert_equal "Project update", message.title
assert_nil message.body
assert_equal 100, message.priority
assert_equal true, message.action_item
assert_equal({ kind: "direct_message", unread: true }, message.info)
```

Assert the megathread precedes higher-scoring normal threads after messages,
normal threads follow the Task 3 rank, and the combined result length never
exceeds `num_items_to_fetch`. For a selected thread assert:

```ruby
assert_equal "t3_mega", thread.canonical_id
assert_equal ["https://www.reddit.com/r/news/comments/mega/election/"], thread.urls
assert_nil thread.body
assert_equal "thread", thread.info.fetch(:kind)
assert_equal "news", thread.info.fetch(:subreddit)
assert_equal 500, thread.info.fetch(:vote_score)
assert_equal 900, thread.info.fetch(:comment_count)
assert_kind_of Integer, thread.info.fetch(:activity_score_milli)
assert_equal true, thread.info.fetch(:megathread)
refute_includes JSON.generate(result.items.map(&:to_h)), "DO_NOT_STORE"
```

Assert metadata equals an allowlisted aggregate shape:

```ruby
assert_equal "unsupported_by_documented_data_api", result.metadata.fetch(:chat_collection)
assert_equal result.items.length, result.metadata.fetch(:selected_count)
assert_kind_of Integer, result.metadata.fetch(:request_count)
refute result.metadata.key?(:subreddits)
refute_includes JSON.generate(result.metadata), "Project update"
```

Add failures for invalid `t4`/`t3` fullname, blank title, nonnumeric timestamp,
nonnumeric score/comments, unsafe permalink, and malformed listing. Confirm
each failure contains zero new items and no sentinel content/credentials.

- [ ] **Step 4: Run adapter tests and verify source behavior fails**

Run:

```bash
bundle exec ruby -Itest test/adapters/reddit_test.rb
```

Expected: FAIL because `Adapters::Reddit#fetch_from_source` is not implemented.

- [ ] **Step 5: Implement effective scope and bounded candidate requests**

In `Adapters::Reddit`, create a `RedditClient` with the configured credentials,
the injected `http_client`, and request budget 90. Capture `fetched_at =
clock.call` once, authenticate, then use:

```ruby
subscriptions = client.listing(
  "/subreddits/mine/subscriber", params: { limit: 100 },
  paginate: true, max_items: nil
).map { |child| subscription_name!(child) }

included = normalized_names(:include_subreddits)
excluded = normalized_names(:exclude_subreddits)
effective = ((subscriptions.map(&:downcase) | included) - excluded).sort

messages = client.listing(
  "/message/unread",
  params: { limit: instance.num_items_to_fetch, mark: false, max_replies: 0 },
  paginate: false, max_items: instance.num_items_to_fetch
).select { |child| child["kind"] == "t4" }.map { |child| message_item!(child, fetched_at) }
```

If `effective` is nonempty, request one `/hot` page. Request explicit additions
in `included.sort.each_slice(SUBREDDITS_PER_BATCH)` batches through
`/r/#{batch.join("+")}/hot`. Request `/r/news/hot` when effective includes
`news`. Each hot listing uses `limit: 100`, `paginate: false`, and
`max_items: 100`. Filter every raw candidate by the effective set before
deduplicating by fullname.

- [ ] **Step 6: Implement strict body-free normalization and selection**

Convert candidates using source `name`, `subreddit`, `title`, `permalink`,
`created_utc`, `score`, `num_comments`, and `stickied` only. Require fullnames
to match `\At3_[a-z0-9]+\z`, message fullnames to match
`\At4_[a-z0-9]+\z`, and permalinks to begin with `/r/` and contain no scheme or
host. Convert timestamps with `Time.at(Float(value)).utc` and reject non-finite
values.

Use:

```ruby
ranked = RedditActivity.rank(candidates, fetched_at: fetched_at)
priority_by_fullname = ranked.each_with_index.to_h do |candidate, index|
  [candidate.fullname, RedditActivity.priority(rank_index: index, candidate_count: ranked.length)]
end
megathreads, normal_threads = ranked.partition { |candidate| RedditActivity.megathread?(candidate) }
selected = (messages + (megathreads + normal_threads).map do |candidate|
  thread_item(candidate, fetched_at, priority_by_fullname.fetch(candidate.fullname))
end).first(instance.num_items_to_fetch)
```

Construct thread info exactly as:

```ruby
{
  kind: "thread",
  subreddit: candidate.subreddit.downcase,
  vote_score: [candidate.vote_score, 0].max,
  comment_count: [candidate.comment_count, 0].max,
  activity_score_milli: RedditActivity.activity_score_milli(candidate, fetched_at: fetched_at),
  megathread: RedditActivity.megathread?(candidate),
  stickied: candidate.stickied == true
}
```

Return `sync_state: {}` and successful metadata containing only
`chat_collection`, `subscription_count`, `effective_subreddit_count`, raw
candidate/message counts, `selected_count`, `request_count`, and
`client.rate_metadata`. Do not include names, titles, URLs, or OAuth values.

- [ ] **Step 7: Run adapter/client/activity tests**

Run:

```bash
bundle exec ruby -Itest test/adapters/reddit_test.rb
bundle exec ruby -Itest test/reddit_client_test.rb
bundle exec ruby -Itest test/reddit_activity_test.rb
bundle exec ruby -Itest test/adapters/base_test.rb
```

Expected: PASS with no failures or errors.

- [ ] **Step 8: Commit collection behavior and fixtures**

```bash
git add lib/cybort/adapters/reddit.rb test/adapters/reddit_test.rb test/fixtures/reddit/unread.json test/fixtures/reddit/home_hot.json test/fixtures/reddit/included_hot.json test/fixtures/reddit/news_hot.json
git commit -m "feat: collect Reddit messages and active threads"
```

---

### Task 6: Prove CLI Cache, Failure Isolation, and Retention

**Files:**
- Modify: `test/system/cli_system_test.rb`

**Interfaces:**
- Consumes: default registry, CLI, existing orchestrator/persistence retention path, and Reddit fixtures.
- Produces: system-level evidence without changing production orchestration or persistence.

- [ ] **Step 1: Add a configurable fake Reddit HTTP client**

In `test/system/cli_system_test.rb`, add a fake that implements `post_form` and
`get`, records calls, returns the Reddit fixtures by URL path, and can raise:

```ruby
Cybort::HttpError.new(429, headers: { "Retry-After" => "60" })
```

Add `write_reddit_config(root, ttl_minutes:, retention_ttl_minutes: nil,
num_items_to_fetch: 10)` using only fixture credentials and the documented
User-Agent. Never place real credentials in tests.

- [ ] **Step 2: Write a forced-fetch and cache test**

Run the CLI with `--force-fetch`, parse JSON, and assert one message/thread has
`body == nil`, a thread contains vote/comment/activity metadata, and metadata
reports unsupported chat. Run again inside TTL with a fake that raises on every
method and assert status `cached`, exit 0, identical persisted canonical IDs,
and zero fake calls.

- [ ] **Step 3: Write failure, retention, and source-isolation tests**

Add three tests:

1. Seed a successful Reddit run, advance past TTL, return HTTP 429, and assert
   exit 1, safe `status: 429`/`retry_after_seconds: 60`, and unchanged items.
2. Configure `retention_ttl_minutes = 60`; seed a selected thread, advance two
   hours, return a successful fixture without it, and assert it is absent after
   the second successful fetch while current items remain.
3. Configure Reddit and RSS together, fail Reddit OAuth, return local RSS XML,
   and assert `partial_failure`, Reddit last-known-good data, and successful RSS
   data.

- [ ] **Step 4: Run the system test and inspect any failure**

Run:

```bash
bundle exec ruby -Itest test/system/cli_system_test.rb
```

Expected: PASS. If the retention test fails because the missing thread remains,
check fixture timestamps and the existing last-seen cutoff; do not add
Reddit-specific deletion.

- [ ] **Step 5: Run focused integration regressions**

Run:

```bash
bundle exec ruby -Itest test/multi_adapter_integration_test.rb
bundle exec ruby -Itest test/orchestrator_test.rb
bundle exec ruby -Itest test/persistence_test.rb
```

Expected: PASS with no failures or errors.

- [ ] **Step 6: Commit system coverage**

```bash
git add test/system/cli_system_test.rb
git commit -m "test: cover Reddit CLI lifecycle"
```

---

### Task 7: Document Reddit Setup and Durable Constraints

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify only after a real smoke test yields evidence: `docs/LEARNINGS.md`

**Interfaces:**
- Consumes: implemented configuration and observed test behavior.
- Produces: user-facing setup instructions and durable agent guidance.

- [ ] **Step 1: Add the Reddit README section**

After the Gmail connector section, document the exact TOML example from the
spec and explain:

- external approved-app/refresh-token provisioning;
- the `read mysubreddits privatemessages` scopes;
- the required descriptive User-Agent format;
- `(subscriptions + inclusions) - exclusions` with exclusion precedence;
- the 100-item combined limit and message/megathread/thread precedence;
- the integer activity formula and that `score` is Reddit's visible/fuzzed
  score rather than exact votes;
- direct messages but not consumer Chat in V1;
- no bodies/authors/raw payloads and no marking read;
- 100-QPM policy awareness and safe failure behavior; and
- `retention_ttl_minutes = 2880` as a strong recommendation, including the
  limits of success-triggered cleanup and the user's obligation to follow
  current Reddit terms.

Link directly to the three current official sources from the spec and label the
OAuth2 wiki as legacy documentation linked by Reddit's current help page.

- [ ] **Step 2: Add the stable project invariant**

In `AGENTS.md`, add one concise invariant:

```markdown
- The Reddit adapter uses the documented OAuth Data API with read-only
  `read`, `mysubreddits`, and `privatemessages` scopes. It stores unread direct
  message subjects and ranked thread metadata but no bodies/authors/raw
  payloads; consumer Chat remains unsupported until Reddit documents a read
  endpoint. Release support remains gated on a sanitized authenticated contract
  smoke test.
```

- [ ] **Step 3: Perform the optional authenticated smoke test only with explicit credentials available**

Do not invent credentials and do not put them on command lines that will be
logged. With an approved app and secrets supplied through a private local
mechanism, verify token refresh, scopes, subscriptions, unread `mark=false`,
home hot, an explicit `+` listing, `r/news` hot, and rate headers. Record only
endpoint status, scope names, response field names/types, and header names.

If no credentials are available, leave the gate open and do not edit
`docs/LEARNINGS.md`. If it runs, add a dated learning with status, observation,
sanitized evidence, impact, and next action; never record tokens, usernames,
subjects, titles, or memberships.

- [ ] **Step 4: Validate documentation without running project tests**

Run:

```bash
rg -n "Reddit|reddit|chat_collection|activity_score_milli|retention_ttl_minutes" README.md AGENTS.md docs/LEARNINGS.md
git diff --check
```

Expected: the README and invariant agree with the spec and implementation;
`git diff --check` prints nothing.

- [ ] **Step 5: Commit documentation**

```bash
git add README.md AGENTS.md
git add docs/LEARNINGS.md # only when Step 3 produced sanitized evidence
git commit -m "docs: explain Reddit integration"
```

---

### Task 8: Final Verification and Review

**Files:**
- Verify all files listed above; make no scope-expanding production changes.

**Interfaces:**
- Consumes: the complete Reddit implementation.
- Produces: evidence that the feature and existing source contracts pass together.

- [ ] **Step 1: Run the complete test suite**

Run:

```bash
bundle exec rake test
```

Expected: PASS with zero failures and zero errors; test output must show no
external-service request.

- [ ] **Step 2: Run formatting and secret/content scans**

Run:

```bash
git diff --check
rg -n "DO_NOT_STORE|fixture-access|Bearer secret|a\+b secret" lib README.md AGENTS.md
rg -n "selftext|selftext_html|author|thumbnail|media" lib/cybort/adapters/reddit.rb
```

Expected: the first two commands print nothing. The field-name scan may show
only explicit rejection/absence guards or comments; no value from those fields
is assigned to `Item`, sync state, or metadata.

- [ ] **Step 3: Review architecture boundaries and repository status**

Run:

```bash
git diff --stat HEAD~7..HEAD
git status --short
rg -n "Reddit|reddit" lib/cybort/orchestrator.rb lib/cybort/persistence.rb lib/cybort/schema.rb
```

Expected: orchestrator, persistence, and schema contain no Reddit-specific
branch; status contains only intended work; the diff contains no
`docs/initial-spitballing.md` change.

- [ ] **Step 4: Request code review**

Use `superpowers:requesting-code-review` to compare the completed implementation
against `docs/superpowers/specs/2026-09-05-reddit-integration-design.md` and this
plan. Resolve correctness, privacy, policy, and secret-handling findings before
claiming completion.

- [ ] **Step 5: Commit review fixes if needed**

Stage each review-fix file explicitly after checking status, then commit:

```bash
git status --short
git commit -m "fix: address Reddit integration review"
```

Skip this commit when review requires no changes. Re-run Steps 1 through 3 after
any review fix. Never use `git add -A` for this checkpoint.
