# Gmail Direct API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Gmail's `gws` dependency with bounded direct API collection and useful authentication diagnostics.

**Architecture:** An explicit `authorized_user` credential file supplies a
refresh token. A small `GmailClient` uses the existing `HttpClient`; the Gmail
adapter normalizes results and the existing orchestrator/persistence pipeline
stores them. Google Cloud CLI performs initial browser authorization outside
Cybort and is absent from collection.

**Tech Stack:** Ruby 4.0.1, existing Net::HTTP/JSON/URI infrastructure, Gmail
REST v1, Google OAuth token endpoint, existing SQLite and Minitest. No new gems.

**Spec:** [Gmail direct API design](../specs/2026-09-06-gmail-direct-api-design.md)

**Status:** Ready for implementation; none of these execution checkboxes have
been completed. The user explicitly waived human design/plan approval gates.
This document is the requested implementation plan, not a claim of delivered
connector code.

## Global Constraints

- Replace the implementation behind `adapter = "gmail"`.
- Add no gems.
- Neither `gws` nor `gcloud` is installed, resolved, version-checked, or executed by collection.
- No SQLite migration.
- Keep one bounded list page and sequential metadata gets.
- Keep the limit of 1–500 messages and the five-minute fetch budget.
- No application retries or backoff.
- Return `sync_state: {}` and `replace_existing_items: false`.
- Static validation performs no file reads or network I/O.
- Fresh cache hits never open the credential file.
- Test execution must be delegated to a read-only `gpt-5.6-luna` agent at medium effort per `AGENTS.md`.

All test commands below are instructions for that delegated executor, including
focused red/green runs. It returns command, pass/fail, relevant failures, first
actionable error, inferred cause, and next step. The primary agent edits code.
Never add live requests to tests. Run the full suite once after integration,
then repeat only if fixes or unresolved failures require it. Live smoke testing
is separate and conditional on an authorized account being available.

## File map and sequencing

| File | Responsibility/change |
|---|---|
| `lib/cybort/errors.rb` | Add Gmail-specific safe error category/message mapping |
| `lib/cybort/gmail_credentials.rb` | New bounded, read-only credential loader |
| `lib/cybort/gmail_client.rb` | New token/list/get HTTP boundary |
| `lib/cybort/adapters/gmail.rb` | Replace subprocess fetch with the client; retain item mapping |
| `lib/cybort/adapter_registry.rb` | Register Gmail with no executable dependencies |
| `lib/cybort.rb` | Require new credential/client files after errors/HTTP, before adapter |
| `test/gmail_credentials_test.rb`, `test/gmail_client_test.rb` | New boundary tests |
| `test/support/gmail_http_fixture.rb` | New reusable recording HTTP fake |
| `test/adapters/gmail_test.rb` | Port current normalization tests; add file/cache/error coverage |
| `test/adapter_registry_test.rb`, `test/orchestrator_test.rb` | New Gmail registration; preserve synthetic dependency tests |
| `test/system/cli_system_test.rb` | Replace Gmail command fakes with HTTP fixtures; verify SQLite behavior |
| `.cybort.example.toml`, `README.md`, `AGENTS.md`, `docs/LEARNINGS.md` | Publish implemented setup and observed limits |

Preserve existing `test/fixtures/gmail/` mail fixtures; add synthetic credential
and token data in test helpers, never real credentials. Do not change
`HttpClient`, `CommandRunner`, `DependencyChecker`, persistence schema, or
`Base#fetch` unless a focused failing test demonstrates a necessary adjustment.
`Base#fetch` already copies `safe_metadata`; it needs no new Gmail branch.

Read the spec, ADR 0005, current Gmail adapter/tests, `HttpClient`, `errors.rb`,
`AdapterRegistry`, and system-test helpers before Task 1. Use an isolated
worktree at execution time if needed; preserve all pre-existing user changes.

---

### Task 1: Load explicit credentials with safe source errors

**Files:** Create `lib/cybort/gmail_credentials.rb`,
`test/gmail_credentials_test.rb`; modify `lib/cybort/errors.rb`, `lib/cybort.rb`.

**Interfaces:**
- Produces `GmailApiError.new(operation:, category:, status: nil)` with
  `safe_metadata`, fixed message, and `SourceError` ancestry.
- Produces `GmailCredentials.load(path:)` and a frozen object with readers
  `client_id`, `client_secret`, `refresh_token` and redacted `inspect`/`to_s`.
- Produces `GmailCredentials.printable?(value, maximum_bytes)` for shared
  validation. It checks String, valid encoding, nonblank, size, and no C0/DEL.

- [x] **Step 1: Add focused failing tests.** Include this test skeleton in a
  new `GmailCredentialsTest < Minitest::Test` requiring `test_helper`:

  ```ruby
  def with_credentials(payload, mode: 0o600)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "credentials.json")
      File.write(path, payload.is_a?(String) ? payload : JSON.generate(payload))
      File.chmod(mode, path)
      yield path
    end
  end

  def authorized_user
    { "type" => "authorized_user", "client_id" => "fake-client",
      "client_secret" => "secret-sentinel", "refresh_token" => "refresh-sentinel" }
  end

  def test_reads_expected_fields_and_redacts_inspection
    with_credentials(authorized_user.merge("token_uri" => "https://untrusted.test")) do |path|
      credentials = Cybort::GmailCredentials.load(path: path)
      assert_equal "fake-client", credentials.client_id
      assert credentials.frozen?
      refute_includes credentials.inspect, "sentinel"
      refute_includes credentials.to_s, "sentinel"
      refute credentials.respond_to?(:token_uri)
    end
  end

  def test_downloaded_client_json_is_not_user_credentials
    with_credentials({ "installed" => authorized_user }) do |path|
      error = assert_raises(Cybort::GmailApiError) do
        Cybort::GmailCredentials.load(path: path)
      end
      assert_equal :invalid_credentials, error.safe_metadata.fetch(:category)
      refute_includes error.message, path
      refute_includes error.message, "sentinel"
    end
  end

  def test_group_readable_credentials_are_rejected
    with_credentials(authorized_user, mode: 0o640) do |path|
      error = assert_raises(Cybort::GmailApiError) do
        Cybort::GmailCredentials.load(path: path)
      end
      assert_equal :unreadable, error.safe_metadata.fetch(:category)
    end
  end
  ```

  Add table-driven tests with explicit expectations: nil path and nonexistent
  path → `missing`; malformed/invalid UTF-8 JSON, array root, wrong `type`,
  missing/blank/control-bearing/over-limit credentials, and 16,385-byte file →
  `invalid_credentials`; directory, leaf symlink, non-regular descriptor, or
  wrong owner → `unreadable`. Extract a private class method
  `validate_file!(stat)` containing the descriptor predicates below; test it
  with a fake stat object for wrong ownership using `.send`, without requiring
  root/chown. Prove bytes are read with an explicit limit and the
  descriptor is closed on failure. Do not create a blocking FIFO reader.

- [x] **Step 2: Delegate `bundle exec ruby -Itest test/gmail_credentials_test.rb`.**
  Expected failure: missing Gmail classes, not unrelated framework failures.

- [x] **Step 3: Add the error mapping.** In `errors.rb`, define operations
  `%i[credentials token list get]` and a frozen category-to-hint hash containing
  every category in the spec's error table. Reject unknown operations/categories
  and non-integer/non-100..599 HTTP statuses with fixed `ArgumentError` text.
  Store only the four allowlisted metadata keys. The construction pattern is:

  ```ruby
  @safe_metadata = {
    source: "gmail_api", operation: operation, category: category
  }
  @safe_metadata[:status] = status unless status.nil?
  @safe_metadata.freeze
  suffix = status ? ", HTTP #{status}" : ""
  super("Gmail #{operation} failed (#{category}#{suffix}). #{HINTS.fetch(category)}")
  ```

  All interpolated operation/category strings come from the validated enums.
  Hints are the static text from the spec table. Never accept a caller-provided
  error message or Google's error description. Add direct tests for unknown
  enum/status rejection and exact 403 guidance within the credential test file.

- [x] **Step 4: Implement the loader.** Use private initialization and copy/freeze
  the three strings, overriding inspection. Implement `.load` with this I/O
  structure (constants and helpers defined immediately below):

  ```ruby
  def self.load(path:)
    raise GmailApiError.new(operation: :credentials, category: :missing) if path.nil?
    expanded = File.expand_path(path)
    flags = File::RDONLY | File::NOFOLLOW | File::NONBLOCK
    payload = File.open(expanded, flags) do |file|
      validate_file!(file.stat)
      raw = file.read(MAX_FILE_BYTES + 1)
      if raw.bytesize > MAX_FILE_BYTES
        raise GmailApiError.new(operation: :credentials, category: :invalid_credentials)
      end
      JSON.parse(raw)
    end
    unless payload.is_a?(Hash) && payload["type"] == "authorized_user" &&
           LIMITS.all? { |key, limit| printable?(payload[key], limit) }
      raise GmailApiError.new(operation: :credentials, category: :invalid_credentials)
    end
    new(**LIMITS.keys.to_h { |key| [key.to_sym, payload.fetch(key).dup.freeze] }).freeze
  rescue Errno::ENOENT
    raise GmailApiError.new(operation: :credentials, category: :missing), cause: nil
  rescue JSON::ParserError, EncodingError, ArgumentError
    raise GmailApiError.new(operation: :credentials, category: :invalid_credentials), cause: nil
  rescue SystemCallError, IOError
    raise GmailApiError.new(operation: :credentials, category: :unreadable), cause: nil
  end
  ```

  `MAX_FILE_BYTES = 16_384`; `LIMITS = { "client_id" => 1_024,
  "client_secret" => 4_096, "refresh_token" => 8_192 }.freeze`.
  The descriptor validator and `.printable?` implementation are:

  ```ruby
  def self.validate_file!(stat)
    unless stat.file? && stat.uid == Process.euid && (stat.mode & 0o077).zero?
      raise GmailApiError.new(operation: :credentials, category: :unreadable)
    end
  end
  private_class_method :validate_file!

  def self.printable?(value, maximum_bytes)
    value.is_a?(String) && value.valid_encoding? && !value.strip.empty? &&
      value.bytesize <= maximum_bytes && !value.match?(/[\x00-\x1F\x7F]/)
  end
  ```

  Validate path format before calling `File.expand_path` in the adapter's
  static validation (Task 4). Expose `attr_reader` for the credential fields,
  explicitly assign them in `initialize(client_id:, client_secret:, refresh_token:)`,
  and return `"#<Cybort::GmailCredentials [REDACTED]>"` for `inspect` and `to_s`.
  Add the require after `errors.rb` in `lib/cybort.rb`.

- [x] **Step 5: Delegate the same focused test file; inspect the bounded summary.**
  Expected: all credential/error contracts pass without external access.
- [x] **Step 6: Commit only Task 1 files** with message
  `feat: load explicit Gmail OAuth credentials safely`.

### Task 2: Implement refresh-token requests and bounded HTTP behavior

**Files:** Create `lib/cybort/gmail_client.rb`, `test/gmail_client_test.rb`,
`test/support/gmail_http_fixture.rb`; modify `lib/cybort.rb`.

**Interfaces:**
- Consumes Task 1 credentials/errors and existing
  `HttpClient#get(url, headers:, timeout_seconds:, deadline_monotonic:)` /
  `post_form(url, form:, headers:, timeout_seconds:, deadline_monotonic:)`.
- Produces `GmailClient.new(http_client:, monotonic_clock:, deadline_monotonic:)`
  and `authenticate(credentials:)` → nil, with token state local to the client.
- Produces test helper `GmailHttpFixture.new(responses:)`, `calls`, `get`, and
  `post_form`. Responses are ordered `HttpResponse` or exception objects.

- [x] **Step 1: Add the recording fake and token tests.** Require the helper
  explicitly from each consumer, not automatically from production code:

  ```ruby
  class GmailHttpFixture
    attr_reader :calls
    def initialize(responses:)
      @responses = responses.dup
      @calls = []
    end
    def get(url, **options)
      record(:get, url, options)
    end
    def post_form(url, **options)
      record(:post_form, url, options)
    end
    private
    def record(method, url, options)
      @calls << { method: method, url: url }.merge(options)
      raise "unexpected fixture request" if @responses.empty?
      result = @responses.shift
      raise result if result.is_a?(Exception)
      result
    end
  end
  ```

  Define test helpers `response(payload)` returning status-200 `HttpResponse`
  with `JSON.generate(payload)`, and `credentials` returning a struct with
  `client_id: "fake-client", client_secret: "fake-secret", refresh_token:
  "fake-refresh"`. A struct is sufficient to test client behavior separately
  from loader behavior. Define `client(http, now: -> { 0.0 }, deadline: 300.0)`
  constructing the client with those injected values.

  ```ruby
  def test_refresh_uses_fixed_endpoint_and_form_without_bearer_header
    http = GmailHttpFixture.new(responses: [response({
      "access_token" => "fake-access", "token_type" => "Bearer", "expires_in" => 3600
    })])
    assert_nil client(http).authenticate(credentials: credentials)
    call = http.calls.fetch(0)
    assert_equal :post_form, call.fetch(:method)
    assert_equal "https://oauth2.googleapis.com/token", call.fetch(:url)
    assert_equal({ grant_type: "refresh_token", client_id: "fake-client",
                   client_secret: "fake-secret", refresh_token: "fake-refresh" },
                 call.fetch(:form))
    assert_equal 30.0, call.fetch(:deadline_monotonic)
    refute call.fetch(:headers).key?("Authorization")
  end

  def test_token_rejection_preserves_safe_status
    http = GmailHttpFixture.new(responses: [Cybort::HttpError.new(status: 400)])
    error = assert_raises(Cybort::GmailApiError) do
      client(http).authenticate(credentials: credentials)
    end
    assert_equal :authentication, error.safe_metadata.fetch(:category)
    assert_equal :token, error.safe_metadata.fetch(:operation)
    assert_equal 400, error.safe_metadata.fetch(:status)
    refute_includes error.message, "fake-secret"
  end
  ```

  Add cases for malformed JSON/root, blank/control/oversized access token,
  invalid token type, non-positive/non-integer expiry, optional absent scope,
  present wrong-type/missing-readonly scope, 403, 429, 500, network, timeout,
  oversized response, and deadline exhaustion before a request. For scope use
  the literal full `https://www.googleapis.com/auth/gmail.readonly` string.

- [x] **Step 2: Delegate `bundle exec ruby -Itest test/gmail_client_test.rb`.**
  Expected: new client is missing.

- [x] **Step 3: Implement the client boundary.** Define fixed `TOKEN_URL`,
  `DATA_URL = "https://gmail.googleapis.com/gmail/v1"`, `READONLY_SCOPE`, and
  `REQUEST_TIMEOUT_SECONDS = 30`. Initialize client/clock/deadline references
  and nil token/expiry. Private `fail_api(operation, category, status: nil)`
  raises `GmailApiError` with `cause: nil`. Private `ensure_deadline!(operation)`
  raises `deadline` when `@monotonic_clock.call >= @deadline_monotonic` and
  returns that validated clock reading when the deadline remains available.

  ```ruby
  def request_json(operation:, url:, form: nil, headers: {})
    now = ensure_deadline!(operation)
    request_deadline = [@deadline_monotonic, now + REQUEST_TIMEOUT_SECONDS].min
    options = { headers: headers, timeout_seconds: request_deadline - now,
                deadline_monotonic: request_deadline }
    response = if form
      @http_client.post_form(url, form: form, **options)
    else
      @http_client.get(url, **options)
    end
    now = ensure_deadline!(operation)
    fail_api(operation, :timeout) if now >= request_deadline
    payload = JSON.parse(response.body)
    fail_api(operation, :invalid_shape) unless payload.is_a?(Hash)
    payload
  rescue HttpError => error
    status = error.safe_metadata.fetch(:status)
    category = if status == 401 || (operation == :token && status == 400)
      :authentication
    elsif status == 403
      :authorization
    elsif status == 429
      :rate_limited
    else
      :http
    end
    fail_api(operation, category, status: status)
  rescue HttpTransportError => error
    fail_api(operation, error.safe_metadata.fetch(:category))
  rescue JSON::ParserError, EncodingError
    fail_api(operation, :invalid_json)
  end
  ```

  `HttpClient` owns status handling; fixture non-2xx outcomes must raise its
  `HttpError`, not return fake successful responses with error statuses. No
  response-body error parsing, generic exception interpolation, redirects,
  unbounded sleeping, or broad catch-and-retry logic.

  ```ruby
  def authenticate(credentials:)
    @access_token = @expires_at_monotonic = nil
    started_at = @monotonic_clock.call
    payload = request_json(operation: :token, url: TOKEN_URL, form: {
      grant_type: "refresh_token", client_id: credentials.client_id,
      client_secret: credentials.client_secret, refresh_token: credentials.refresh_token
    })
    unless GmailCredentials.printable?(payload["access_token"], 8_192) &&
           payload["token_type"].is_a?(String) && payload["token_type"].casecmp?("Bearer") &&
           payload["expires_in"].is_a?(Integer) && payload["expires_in"].positive?
      fail_api(:token, :invalid_shape)
    end
    if payload.key?("scope") &&
       (!payload["scope"].is_a?(String) || !payload["scope"].split.include?(READONLY_SCOPE))
      fail_api(:token, :scope)
    end
    @access_token = payload.fetch("access_token").dup.freeze
    @expires_at_monotonic = started_at + payload.fetch("expires_in")
    nil
  end
  ```

  Token expiry starts at request initiation, conservatively accounting for
  request latency. Do not retain the credential object or token response in
  client state. Give `GmailClient#inspect`/`to_s` a redacted string as well.
  Add the require after `http_client.rb` and before the Gmail adapter.

- [x] **Step 4: Delegate the focused client test file.** Assert single requests
  on failure, and no output contains sentinel secrets.
- [x] **Step 5: Commit Task 2 files** with message
  `feat: exchange Gmail refresh tokens through bounded HTTP`.

**Review evidence (2026-09-06):** Focused client tests pass with 14 runs and
101 assertions. Root review approved the refresh-token contract, safe error
classification, redaction, and one-reading deadline fix. The boundary
regression drives the clock across the attempt deadline and verifies that the
HTTP fake receives a positive 1.0-second timeout rather than zero or a
negative value. No live OAuth or Gmail account access was used.

### Task 3: Implement the bounded Gmail list/get contract

**Files:** Modify `lib/cybort/gmail_client.rb`, `test/gmail_client_test.rb`.

**Interfaces:**
- Consumes authenticated client from Task 2.
- Produces `list_message_ids(user_id:, query:, limit:, include_spam_trash:)`
  → ordered unique string IDs, and `get_message(user_id:, message_id:)` → Hash.
- Private `get_json(operation:, path:, params:)` creates the fixed-host URL and
  supplies the in-memory bearer header after deadline/expiry checks.
- Private `segment(value)` percent-encodes one path segment;
  `valid_id?(value)` implements the spec's bounded opaque-ID contract.

- [x] **Step 1: Add failing contract tests.** Use the existing client helper and
  a `token_response` helper returning the valid token fixture from Task 2.

  ```ruby
  def test_list_caps_before_deduplicating_and_does_not_follow_pages
    http = GmailHttpFixture.new(responses: [token_response, response({
      "messages" => [{"id" => "one"}, {"id" => "one"}, {"id" => "two"}],
      "nextPageToken" => "unused-page"
    })])
    gmail = client(http)
    gmail.authenticate(credentials: credentials)
    ids = gmail.list_message_ids(user_id: "me", query: "in:anywhere",
                                limit: 2, include_spam_trash: true)
    assert_equal ["one"], ids
    params = URI.decode_www_form(URI(http.calls.last.fetch(:url)).query).to_h
    assert_equal "2", params.fetch("maxResults")
    assert_equal "true", params.fetch("includeSpamTrash")
    assert_equal "in:anywhere", params.fetch("q")
    assert_equal 2, http.calls.length
  end

  def test_detail_id_mismatch_is_safe
    http = GmailHttpFixture.new(responses: [token_response, response({"id" => "other"})])
    gmail = client(http)
    gmail.authenticate(credentials: credentials)
    error = assert_raises(Cybort::GmailApiError) do
      gmail.get_message(user_id: "me", message_id: "one")
    end
    assert_equal :invalid_identity, error.safe_metadata.fetch(:category)
    refute_includes error.message, "other"
  end
  ```

  Add cases for absent/empty messages, null/wrong-type lists, blank/non-string/
  control-bearing/dot IDs, bad records in the inspected prefix, over-returned
  records after the limit ignored, query escaping (`&`, Unicode), and `me` vs
  encoded email address paths. Decode repeated query pairs as an array to
  assert all four `metadataHeaders` values. Assert token only in Authorization,
  correct fields mask, no pagination, no calls after expired token or deadline,
  and 404 get failure (without success/partial-result semantics).

- [x] **Step 2: Delegate `bundle exec ruby -Itest test/gmail_client_test.rb`.**
  Expected: missing list/get methods.

- [x] **Step 3: Implement listing and retrieval.** Use `URI.encode_www_form`
  for query encoding and `URI.encode_www_form_component(value).gsub("+", "%20")`
  for each path segment; never interpolate raw IDs into a path.

  ```ruby
  def list_message_ids(user_id:, query:, limit:, include_spam_trash:)
    params = { "maxResults" => limit, "includeSpamTrash" => include_spam_trash }
    params["q"] = query unless query.strip.empty?
    payload = get_json(operation: :list, path: "/users/#{segment(user_id)}/messages", params: params)
    messages = payload.fetch("messages", [])
    fail_api(:list, :invalid_shape) unless messages.is_a?(Array)
    messages.first(limit).map do |message|
      unless message.is_a?(Hash) && valid_id?(message["id"])
        fail_api(:list, :invalid_identity)
      end
      message.fetch("id")
    end.uniq
  end

  def get_message(user_id:, message_id:)
    fail_api(:get, :invalid_identity) unless valid_id?(message_id)
    params = [
      ["format", "metadata"],
      ["fields", "id,threadId,labelIds,snippet,internalDate,payload/headers"]
    ]
    %w[Subject From Date Message-ID].each { |name| params << ["metadataHeaders", name] }
    payload = get_json(operation: :get,
      path: "/users/#{segment(user_id)}/messages/#{segment(message_id)}", params: params)
    fail_api(:get, :invalid_identity) unless payload["id"] == message_id
    validate_optional_fields!(payload)
    payload
  end

  def get_json(operation:, path:, params:)
    now = ensure_deadline!(operation)
    fail_api(operation, :authentication) unless @access_token
    fail_api(operation, :token_expired) if now >= @expires_at_monotonic
    request_json(operation: operation, url: "#{DATA_URL}#{path}?#{URI.encode_www_form(params)}",
                 headers: { "Authorization" => "Bearer #{@access_token}" })
  end
  ```

  `valid_id?` delegates printable/length checking (256 bytes) and rejects `.`
  and `..`. `get_json`, `segment`, `valid_id?`, and validation helpers are private.

  Define `validate_optional_fields!(payload)` with these exact predicates;
  any false predicate raises `fail_api(:get, :invalid_shape)`:

  ```ruby
  %w[snippet threadId].each do |key|
    fail_api(:get, :invalid_shape) unless payload[key].nil? || payload[key].is_a?(String)
  end
  labels = payload["labelIds"]
  unless labels.nil? || (labels.is_a?(Array) && labels.all? { |label| label.is_a?(String) })
    fail_api(:get, :invalid_shape)
  end
  part = payload["payload"]
  fail_api(:get, :invalid_shape) unless part.nil? || part.is_a?(Hash)
  headers = part && part["headers"]
  unless headers.nil? || (headers.is_a?(Array) && headers.all? { |header|
    header.is_a?(Hash) && header["name"].is_a?(String) && header["value"].is_a?(String)
  })
    fail_api(:get, :invalid_shape)
  end
  ```

  Do not reject malformed `internalDate` here: adapter normalization tolerates
  it as nil. Add one test per wrong optional-field type and null-as-absent case.

- [x] **Step 4: Delegate the client tests.** Verify bounds and exact request
  arguments; no shared client state across instances.
- [x] **Step 5: Commit Task 3 changes** with message
  `feat: fetch bounded Gmail metadata over REST`.

**Review evidence (2026-09-06):** Root review approved the implementation's
prefix-before-deduplication bound, fixed encoded endpoints, typed metadata
parameters, safe failure behavior, and use of the validated monotonic reading
from `ensure_deadline!` for token expiry. Focused client tests pass with 29
runs and 206 assertions, with 0 failures, 0 errors, and 0 skips. The suite
covers empty and malformed list shapes, inspected-prefix bounds, opaque ID
validation, query/path encoding, repeated metadata headers, optional-field
validation, token/deadline guards, 404 handling, and per-client token
isolation. No live OAuth or Gmail account access was used.

### Task 4: Replace the Gmail adapter and registry entry

**Files:** Modify `lib/cybort/adapters/gmail.rb`,
`lib/cybort/adapter_registry.rb`, `test/adapters/gmail_test.rb`,
`test/adapter_registry_test.rb`.

**Interfaces:**
- Consumes Tasks 1–3; inherits existing `Base` constructor and result handling.
- Produces the same Gmail `Item` mapping and `FetchResult` semantics, with safe
  Gmail errors, no executable requirement, and the new configuration fields.

- [x] **Step 1: Port adapter fixture wiring, retaining meaningful assertions.**
  Replace `StubCommandRunner`/`dependency_resolution` helpers with the recording
  HTTP fake. Write an `authorized_user` fixture to a chmod-0600 file inside each
  test's `Dir.mktmpdir`; pass its absolute path in instance options. The adapter
  helper receives `http_client:` and `credentials_file:` and the existing
  injected wall/monotonic clocks. Existing `one`/`two` list/detail fixtures are
  consumed unchanged. Add a token response before list/detail responses.

  Keep the first normalization test's title, snippet, UTC date, From,
  Message-ID, nil body/date, deduplication, and fetched-at assertions. Replace
  process-argument assertions with client request contract assertions; do not
  preserve tests of a deleted subprocess implementation.

  ```ruby
  def test_default_gmail_has_no_executable_dependencies
    registry = Cybort::AdapterRegistry.default
    instance = Cybort::Configuration::Instance.new(
      id: "jer_gmail", name: "Personal Gmail", adapter: "gmail",
      ttl_minutes: 60, num_items_to_fetch: 200,
      options: { user_id: "me", query: "in:anywhere" }
    )
    registry.validate_configuration!(instance)
    assert_empty registry.dependencies_for(instance)
  end
  ```

  Add tests for cache hit with missing credentials (no file read/HTTP), remote
  missing credentials → `credentials/missing`, partial detail failure → no
  items, and unchanged `replace_existing_items == false`. Use a path guaranteed
  not to exist for the cache/remote pair; do not use the user's real directory.

- [x] **Step 2: Delegate the adapter and registry test files individually.**
  Commands: `bundle exec ruby -Itest test/adapters/gmail_test.rb` and
  `bundle exec ruby -Itest test/adapter_registry_test.rb`.
  Expected red cases demonstrate remaining `gws` construction/dependency.

- [x] **Step 3: Implement static validation.** Retain integer 1–500 validation.
  Add max lengths and path rules from the spec using `GmailCredentials.printable?`.
  For query allow `""`/whitespace without making `.printable?` reject it:

  ```ruby
  valid_query = query.is_a?(String) && query.valid_encoding? &&
    query.bytesize <= 4_096 && !query.match?(/[\x00-\x1F\x7F]/)
  valid_user = GmailCredentials.printable?(user_id, 320) &&
    (user_id == "me" || user_id.match?(%r{\A[^@\s/\\?#]+@[^@\s/\\?#]+\z}))
  if instance.options.key?(:credentials_file)
    path = instance.options[:credentials_file]
    valid_path = GmailCredentials.printable?(path, 4_096) &&
      (path.start_with?("/") || path.start_with?("~/"))
    raise ConfigurationError, "gmail credentials_file must be an absolute or ~/ path" unless valid_path
  end
  include_spam_trash = instance.options.fetch(:include_spam_trash, false)
  unless include_spam_trash == true || include_spam_trash == false
    raise ConfigurationError, "gmail include_spam_trash must be a boolean"
  end
  ```

  Raise fixed, content-free errors for false `valid_query`/`valid_user`.
  Add table-driven invalid config tests for nil/bool/numeric/oversized/control
  fields, relative/`~other` paths, 0/501 limits, and valid UTF-8 queries. Ensure
  the missing key is accepted but a present nil/blank file path is rejected.

- [x] **Step 4: Replace fetching and preserve normalization.**

  ```ruby
  def fetch_from_source
    deadline = monotonic_clock.call + ADAPTER_BUDGET_SECONDS
    fetched_at = clock.call
    credentials = GmailCredentials.load(path: instance.options[:credentials_file])
    client = GmailClient.new(http_client: http_client,
      monotonic_clock: monotonic_clock, deadline_monotonic: deadline)
    client.authenticate(credentials: credentials)
    ids = client.list_message_ids(user_id: user_id, query: query,
      limit: instance.num_items_to_fetch,
      include_spam_trash: instance.options.fetch(:include_spam_trash, false))
    items = ids.map do |id|
      item_from(client.get_message(user_id: user_id, message_id: id), id, fetched_at)
    end
    if monotonic_clock.call >= deadline
      raise GmailApiError.new(operation: :get, category: :deadline)
    end
    { items: items, sync_state: {}, replace_existing_items: false,
      metadata: { source: "gmail_api", limit: instance.num_items_to_fetch,
                  message_count: items.length } }
  end
  ```

  Keep `ADAPTER_BUDGET_SECONDS = 300`, `MAX_RESULTS = 500`, and current user/query
  accessors. Remove command constants, auth hints, argument builders, JSON
  parsing, dependency lookup, command status/index accounting, and command
  failure methods. Change `item_from` signature to `(message, requested_id,
  fetched_at)`; identity validation is now in `GmailClient`. Keep the existing
  header extraction, `Item.new` field mapping, and `parse_internal_date` logic.
  Since Task 3 validates optional shapes, malformed input cannot cause a raw
  `dig`/header exception to expose private payloads. Missing/null headers use
  `message.dig("payload", "headers") || []`.

  Replace the entire default Gmail dependency declaration with:

  ```ruby
  registry.register("gmail", Adapters::Gmail)
  ```

  Remove the registry test that asserts `GOOGLE_WORKSPACE_CLI_*` propagation;
  generic runner environment coverage remains in `command_runner_test.rb`.

- [x] **Step 5: Delegate the focused adapter/registry tests.** Include injected
  clock transitions proving credential time counts against the attempt budget,
  no detail request starts after expiry/deadline, and success is checked after
  the last response. Expected: no subprocess calls in any Gmail path.
- [x] **Step 6: Commit Task 4 files** with message
  `feat: replace Gmail gws adapter with direct API collection`.

### Task 5: Verify migration, failure isolation, and generic dependencies

**Files:** Modify `test/system/cli_system_test.rb`, `test/orchestrator_test.rb`;
extend `test/support/gmail_http_fixture.rb` only if shared routing is needed.

**Interfaces:**
- Consumes the default registry and existing CLI `http_client:`,
  `command_runner:`, `dependency_checker:`, `home:` test injections.
- Produces offline integration evidence with temporary configuration/SQLite and
  fake HTTP responses, retaining all generic command-preflight coverage.

- [x] **Step 1: Port system-test helpers and add failing regressions.**
  Change `write_gmail_config` to accept an explicit credential-file path and
  optional inclusion of its TOML key; keep retention and ID parameters. Create
  chmod-0600 authorized-user files in the temporary test installation. Replace
  `FakeGwsRunner`/`gmail_runner` usages for real Gmail with HTTP fixtures. Use
  `--json` when parsing CLI JSON. `CLI.start` currently defaults to JSON for
  programmatic compatibility, while `bin/cybort` selects diagnostic output;
  pass `output_mode: :diagnostic` explicitly in human-output tests. Inspect
  each touched test before porting; no general test-output migration is needed.

  Define a sentinel dependency checker whose `resolve` raises if invoked and
  a sentinel runner whose `run` raises. Pass both to real Gmail integration
  tests; any accidental runtime tool dependency fails immediately.

  Implement this primary scenario in the current system harness:

  ```ruby
  # After helper wiring has written the same jer_gmail config and credential file:
  first = Cybort::CLI.start(["--json", "--force-fetch"], home: directory,
    out: first_output, err: StringIO.new, http_client: successful_http,
    command_runner: refusing_runner, dependency_checker: refusing_checker)
  assert_equal 0, first
  failed = Cybort::CLI.start(["--json", "--force-fetch"], home: directory,
    out: failed_output, err: StringIO.new, http_client: token_rejected_http,
    command_runner: refusing_runner, dependency_checker: refusing_checker)
  assert_equal 1, failed
  payload = JSON.parse(failed_output.string)
  mail = payload.fetch("instances").find { |entry| entry.fetch("id") == "jer_gmail" }
  assert_equal "failure", mail.fetch("status")
  assert_equal "token", mail.fetch("metadata").fetch("operation")
  assert_equal "authentication", mail.fetch("metadata").fetch("category")
  assert_equal 400, mail.fetch("metadata").fetch("status")
  assert_equal "Quarterly review", mail.fetch("items").first.fetch("title")
  ```

  For this scenario `token_rejected_http` must be a recording fake raising
  `HttpError.new(status: 400)` on the token POST; assert operation `"token"`,
  category `"authentication"`, status `400` unconditionally. Define both output
  buffers as `StringIO.new`. Use the existing file-backed Gmail fixtures for
  `successful_http`. Keep these helpers local to the test file.

  Add the following concrete scenarios, with assertions at CLI and persistence
  boundaries as relevant:

  | Test scenario | Required assertions |
  |---|---|
  | Same ID migrated from seeded existing mail | Same canonical IDs upsert; no duplicate rows or schema change |
  | Fresh cache, file absent/config key omitted | Exit 0, cached items, no file/token/list/get or preflight calls |
  | Stale/forced cache, missing file | Exit 1, credentials/missing, old items and freshness retained |
  | Gmail 403 with healthy RSS | Gmail failure, RSS committed, partial failure exit 1 |
  | Detail failure after one successful get | No partial mail persisted and no retention pruning |
  | Empty successful list | Cache freshness advances, old items remain absent retention expiry |
  | Successful fetch with retention | Existing cutoff behavior prunes old unreturned items only on success |
  | Two accounts/files | Each token POST uses its own refresh token; each Gmail header uses corresponding bearer |
  | Safe diagnostics/history | No token, credential path, query, user ID, or raw error body in error/metadata fields |
  | Human output | Static token/403/file guidance appears in newline-terminated error message |

  In the two-account case, use a mutex-protected fake mapping credentials to
  tokens and routing GETs by bearer header, rather than an order-dependent
  response queue shared across adapter threads. Mail data is intentionally
  stored in items; secrecy assertions target diagnostics/metadata, not all
  successful item JSON.

- [x] **Step 2: Delegate focused system/orchestrator tests.** Commands:
  `bundle exec ruby -Itest test/system/cli_system_test.rb` and
  `bundle exec ruby -Itest test/orchestrator_test.rb`.
  Expected: old Gmail-as-command assumptions fail until Step 3 is complete.

- [x] **Step 3: Preserve command-infrastructure tests with synthetic adapters.**
  In `orchestrator_test.rb`, replace fake adapter names/tool labels `gmail/gws`
  with `command_fixture/fixture-tool` for tests already using `PlanningAdapter`
  and an explicitly registered dependency. In system tests requiring command
  preflight, inject a custom registry whose `command_fixture` entry has a
  declared `Dependency`; do not use the default Gmail entry. Preserve the
  missing-tool, fresh-cache, forced-fetch, per-run de-duplication, grouped hints,
  and version requirement assertions. Retain existing `CommandRunner` and
  `DependencyChecker` unit tests unchanged unless a real defect is discovered.

  ```ruby
  dependency = Cybort::Dependency.new(executable: "fixture-tool", purpose: "test fixture")
  registry = Cybort::AdapterRegistry.new
  registry.register("command_fixture", factory,
    dependencies: [dependency], validate_configuration: ->(_instance) {})
  ```

  Here `factory` is the existing test's `PlanningAdapter` factory (or the
  corresponding existing system fake); retain its constructor and returned
  `FetchResult`. Do not introduce a production synthetic connector.

- [x] **Step 4: Delegate focused tests again.** Repair only evidence-backed
  integration issues. Any runtime defect returns to its owning task's failing
  test; avoid rewriting shared orchestration just to accommodate test fakes.
- [x] **Step 5: Commit Task 5 changes** with message
  `test: cover Gmail REST migration and source isolation`.

#### Task 5 review evidence

Root review approved the Task 5 test diff after confirming that the privacy
regression exercises the real `HttpClient` body-discard path and that the Gmail
fixture derives bounded IDs directly from the parsed list. Focused verification:

- `bundle exec ruby -Itest test/system/cli_system_test.rb`: 28 runs, 249
  assertions, 0 failures, 0 errors.
- `bundle exec ruby -Itest test/orchestrator_test.rb`: 13 runs, 52 assertions,
  0 failures, 0 errors.
- `git diff --check`: clean before commit.

The Task 5 commit is `4e18f3c` on `gmail-direct-api`, pushed to
`origin/gmail-direct-api`. No full suite or live Gmail smoke test was run for
this task.

### Task 6: Publish setup, verify the implementation, and record release status

**Files:** Modify `.cybort.example.toml`, `README.md`, `AGENTS.md`,
`docs/LEARNINGS.md`, and status notes in the new spec/ADR as warranted by evidence.

**Interfaces:**
- Consumes tested runtime implementation and the exact setup procedure in the spec.
- Produces user-facing migration guidance and explicit offline/live verification status.

**Execution note (2026-09-06):** The delegation/medium-effort and no-push
constraints above record the planning-time workflow. For this implementation
task, the user explicitly authorized the assigned executor to run the full
offline suite with xhigh reasoning and permits a feature-branch commit/push
after root review. No live account calls, user-configuration changes, merge to
main, or release action is authorized. Root review has now approved the
documentation handoff; the offline verification is complete and the
authenticated live gate remains open.

- [x] **Step 1: Update the canonical Gmail example.** Replace the `gws` comments,
  preserve the stable instance format, and use this commented configuration:

  ```toml
  # Gmail: direct read-only Gmail API; authorize once via README Gmail setup.
  # Runtime does not execute gws or gcloud. Keep credentials outside the repo.
  # [instances.personal_gmail]
  # name = "Personal Gmail"
  # adapter = "gmail"
  # ttl_minutes = 60
  # num_items_to_fetch = 200 # integer 1..500; one bounded list page
  # credentials_file = "~/.cybort/google-auth/personal_gmail/application_default_credentials.json"
  # user_id = "me"
  # query = "in:anywhere"
  # include_spam_trash = true # optional; default false
  ```

- [x] **Step 2: Replace README Gmail setup with the spec's actual procedure.**
  Include Google Console links, Desktop OAuth client versus authorized-user
  file distinction, `CLOUDSDK_CONFIG` isolation, explicit Gmail scope, Testing
  token expiry, private file permissions, static errors, and per-account
  instance IDs. Link to `.cybort.example.toml`; do not duplicate TOML in README.
  Explain cache behavior for old configs and that keeping the same ID preserves
  the same account's data. Remove Gmail's gws version/install/auth guidance and
  the erroneous claim that runtime Gmail requires gcloud. Do not run login or
  delete previous gws state automatically.

- [x] **Step 3: Update durable records precisely.** In `AGENTS.md`, change Gmail's
  actual runtime description to direct API plus externally bootstrapped
  credentials, preserving the generic command adapter invariant. In the dated
  gws learning, mark the former runtime path superseded by this implementation
  and link to ADR 0005. Record the new implementation evidence/date and whether
  the manual gate is open. Do not erase the original auth failure observation.
  ADR 0005's decision is already Accepted; implementation/live readiness is a
  separate status. Keep ADR 0002 Superseded in the index.

- [x] **Step 4: Delegate `bundle exec rake test` for final offline verification.**
  Also run read-only `git diff --check`, review changed documentation links,
  inspect `git diff --stat`, and check production Gmail files contain no `gws`
  invocation or dependency. `Gemfile`, `Gemfile.lock`, schema, and historical
  spitballing documents should remain unchanged. Do not claim a test count
  before the delegated result supplies it. Investigate unrelated baseline
  failures separately and report them; do not hide them.

  **Verification (2026-09-06):** Under the user's explicit xhigh execution
  authorization, `bundle exec rake test` passed with 285 runs, 1,498
  assertions, 0 failures, 0 errors, and 0 skips. `git diff --check`, local
  Markdown-link checks, the production Gmail/registry `gws` scan, and checks
  for unchanged `Gemfile`, `Gemfile.lock`, schema, and historical
  spitballing paths also passed. No tests were rerun after the final docs-only
  review refinements.

- [ ] **Step 5: Complete the authenticated gate only if an authorized account is available.**
  Use the spec's dedicated credential setup and one-message adapter smoke test.
  Run live checks separately from the offline suite. Prefer calling the Gmail
  adapter alone with a local configuration object so unrelated configured
  sources are not fetched. Never print credentials or full mail JSON. Verify
  token/list/get, account scope, metadata shape, unchanged message labels, cache
  behavior, and no executable dependencies. Delegate output analysis per the
  repository rule. If unavailable, explicitly record the gate as open and
  retain the experimental designation; do not invent success or run login on
  a user's behalf without the required interactive participation.

  **Status (2026-09-06):** Open/skipped for this task. No authorized account or
  credential file was available, so no login, mailbox, token, or live Gmail
  request was run. Gmail remains experimental pending the dedicated
  authenticated token/list/get smoke test and unchanged read/unread-label
  check.

- [x] **Step 6: Commit documentation and final fixes** with message
  `docs: document direct Gmail authentication and migration`.
  Hand off the changes with offline results and live-gate status. A
  feature-branch commit/push is user-authorized after root review; merge,
  release, and changes to the user's real configuration remain out of scope.

#### Task 6 final verification evidence

- Documentation review approved by root on 2026-09-06.
- Offline suite: 285 runs, 1,498 assertions, 0 failures, 0 errors, 0 skips.
- Read-only checks passed: `git diff --check`, local Markdown links,
  production Gmail/registry `gws` scan, and unchanged dependency/schema/
  historical-document checks.
- No authenticated Gmail account was available. The live release gate remains
  explicitly open and Gmail remains experimental.

#### Final code-quality cleanup (2026-09-06)

Root-approved review removed the duplicate Gmail raw transport fixture, trimmed
an unused token-helper argument, and removed one redundant local assignment.
The focused system suite (28 runs, 249 assertions) and full offline suite (285
runs, 1,498 assertions) remained clean; no additional test rerun was needed
after this unchanged-docs review.

## Design-to-task coverage

| Design requirement | Task |
|---|---|
| Explicit read-only private credential file, safe errors | 1 |
| Refresh grant, scoped bearer, deadline/body bounds | 2 |
| Fixed hosts, encoded paths, bounded first page, typed responses | 3 |
| Same adapter identity, normalization, cache/no-process behavior | 4 |
| Failure isolation, retention, two-account isolation, generic commands | 5 |
| Configuration example, setup/migration, authority records, live gate | 6 |

Execute in dependency order. The design and plan were produced under the
user's instruction to proceed without human approval checkpoints; there is no
additional design approval gate between these tasks. This planning turn ends
with documentation. Implementation requires a subsequent execution task.
