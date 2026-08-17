# Cybort Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first working Cybort application: configured adapter instances fetch concurrently, results are persisted in one SQLite database, and cached/current data is presented through the CLI.

**Architecture:** Adapter instances fetch and normalize source data but do not write to SQLite. The orchestrator starts one thread per configured instance, waits for all results, and persists them sequentially through a shared `Persistence` service. Each successful adapter result has an independent transaction.

**Tech Stack:** Ruby 4.0.1 runtime, `sqlite3`, `tomlrb`, Ruby standard-library `RSS`, `Net::HTTP`, `JSON`, `Digest`, and `Optparse`, with Minitest and Rake for tests.

## Global Constraints

- Keep the implementation simple, idiomatic Ruby, and split responsibilities into focused files.
- Keep individual source files below approximately 100 lines where practical; split a file when the design becomes difficult to read.
- Use one SQLite database as the canonical mutable datastore.
- Use one thread per configured adapter instance for the initial implementation.
- Adapter threads fetch and normalize only; they do not write to SQLite.
- The orchestrator waits for all adapter threads, then persists results sequentially.
- Use one transaction per successful adapter result; never require a global transaction across adapter instances.
- Use `num_items_to_fetch` for source-fetch limits; do not implement retention policy in this plan.
- Use fake HTTP clients and local fixtures in tests; tests must not depend on external network services.
- Preserve partial success: one adapter failure must not remove another adapter’s successful data.
- Do not modify `docs/initial-spitballing.md`.
- Do not implement scheduling, dashboards, or advanced analysis/external-access workflows.

## File and module map

The implementation will create these focused units:

- `Gemfile`, `Rakefile`, `.gitignore`, `bin/cybort`: dependency, test, executable, and local-runtime setup.
- `lib/cybort.rb`, `lib/cybort/configuration.rb`, `lib/cybort/item.rb`, `lib/cybort/fetch_result.rb`: public loading plus configuration and domain contracts.
- `lib/cybort/schema.rb`, `lib/cybort/persistence.rb`: SQLite schema and persistence boundary.
- `lib/cybort/http_client.rb`, `lib/cybort/adapter_registry.rb`, `lib/cybort/adapters/base.rb`: shared source-client and adapter infrastructure.
- `lib/cybort/adapters/rss.rb`, `lib/cybort/adapters/github.rb`: the first two concrete adapters.
- `lib/cybort/orchestrator.rb`, `lib/cybort/cli.rb`, `lib/cybort/installer.rb`: run coordination, command behavior, and safe initialization.
- `test/`: unit, integration, fixture, and orchestration tests mirroring the production responsibilities.

The plan is organized into vertical slices. Each slice leaves a runnable,
testable increment rather than building the entire infrastructure before a
source can be used.

---

## Vertical Slice 1: One RSS adapter end to end

This slice proves the complete path with the simplest real source: TOML
configuration → one RSS adapter → normalized items → SQLite → CLI output.
RSS is chosen before Gmail because it has no OAuth flow and exercises canonical
IDs, timestamps, URLs, body text, and malformed-source handling with a small
fixture.

### Task 1: Bootstrap the Ruby executable and test harness

**Files:**

- Create: `Gemfile`
- Create: `Rakefile`
- Create: `.gitignore`
- Create: `bin/cybort`
- Create: `lib/cybort.rb`
- Create: `test/test_helper.rb`
- Test: `test/cybort_boot_test.rb`

**Interfaces:**

- `Cybort::VERSION` returns the initial application version string `"0.1.0"`.
- `bin/cybort` loads `lib/cybort.rb` and delegates to `Cybort::CLI.start(ARGV)` once the CLI module exists.
- `rake test` runs all files matching `test/**/*_test.rb`.

- [ ] **Step 1: Write the failing boot test**

Create `test/cybort_boot_test.rb`:

```ruby
require "test_helper"

class CybortBootTest < Minitest::Test
  def test_cybort_loads_with_a_version
    assert_equal "0.1.0", Cybort::VERSION
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bundle exec ruby -Itest test/cybort_boot_test.rb`

Expected: FAIL because the application load path and `Cybort::VERSION` do not exist yet.

- [ ] **Step 3: Add the minimal project bootstrap**

Add runtime dependencies `sqlite3` and `tomlrb`, test dependency `minitest`, and development dependency `rake` to `Gemfile`. Configure `Rake::TestTask` in `Rakefile`, add `lib` and `bin` to the load path in `test/test_helper.rb`, define `Cybort::VERSION`, and make `bin/cybort` executable.

- [ ] **Step 4: Run the focused test and full test task**

Run: `bundle exec ruby -Itest test/cybort_boot_test.rb`

Expected: PASS.

Run: `bundle exec rake test`

Expected: PASS with one test.

- [ ] **Step 5: Commit the bootstrap**

```bash
git add Gemfile Rakefile .gitignore bin/cybort lib/cybort.rb test/test_helper.rb test/cybort_boot_test.rb
git commit -m "build: bootstrap Cybort Ruby application"
```

### Task 2: Add configuration and domain result contracts

**Files:**

- Create: `lib/cybort/configuration.rb`
- Create: `lib/cybort/item.rb`
- Create: `lib/cybort/fetch_result.rb`
- Modify: `lib/cybort.rb`
- Test: `test/configuration_test.rb`
- Test: `test/item_test.rb`
- Test: `test/fetch_result_test.rb`
- Fixture: `test/fixtures/configuration/single_rss.toml`

**Interfaces:**

- `Cybort::Configuration.load(path)` returns a configuration object with `instances`.
- Each instance exposes `id`, `name`, `adapter`, `ttl_minutes`, `num_items_to_fetch`, and an adapter-specific `options` hash.
- `Cybort::Item.new(instance_id:, canonical_id:, urls:, fetched_at:, remote_created_at:, title:, body:, priority:, action_item:, info:)` validates required fields and normalizes optional collections.
- `Cybort::FetchResult.success(instance_id:, items:, sync_state:, started_at:, finished_at:, metadata:, source_fetched:)` creates a successful result.
- `Cybort::FetchResult.failure(instance_id:, error:, started_at:, finished_at:)` creates a failure result.

- [ ] **Step 1: Write failing configuration tests**

Cover these exact cases:

1. A valid TOML file produces one instance with ID `personal_rss` and `num_items_to_fetch == 10`.
2. A missing `schema_version` raises `Cybort::ConfigurationError`.
3. A missing `adapter`, `ttl_minutes`, or `num_items_to_fetch` raises `Cybort::ConfigurationError` naming the instance and key.
4. A non-positive TTL or fetch limit raises `Cybort::ConfigurationError`.
5. The display `name` is retained separately from the stable instance ID.

- [ ] **Step 2: Run the focused configuration tests to verify failure**

Run: `bundle exec ruby -Itest test/configuration_test.rb`

Expected: FAIL because the configuration module and exception do not exist.

- [ ] **Step 3: Write failing item and fetch-result tests**

Cover these exact cases:

1. An item requires `instance_id`, `canonical_id`, `fetched_at`, and `title`.
2. `urls` defaults to an empty array and `info` defaults to an empty hash.
3. Priority accepts integers from 0 through 100 and rejects values outside that range.
4. A successful fetch result reports `success? == true` and preserves `source_fetched`.
5. A failure result reports `success? == false` and preserves the original exception.

- [ ] **Step 4: Implement the minimal contracts**

Use `Tomlrb.load_file(path, symbolize_keys: true)` for file parsing. Keep source-specific keys in `options`; only validate the common keys in `Configuration`. Use small keyword-initialized value objects and raise `Cybort::ConfigurationError` or `Cybort::ValidationError` with actionable messages.

- [ ] **Step 5: Run all focused tests**

Run: `bundle exec ruby -Itest test/configuration_test.rb test/item_test.rb test/fetch_result_test.rb`

Expected: PASS.

- [ ] **Step 6: Commit the contracts**

```bash
git add lib/cybort.rb lib/cybort/configuration.rb lib/cybort/item.rb lib/cybort/fetch_result.rb test/configuration_test.rb test/item_test.rb test/fetch_result_test.rb test/fixtures/configuration/single_rss.toml
git commit -m "feat: add configuration and fetch result contracts"
```

### Task 3: Implement the SQLite persistence boundary

**Files:**

- Create: `lib/cybort/schema.rb`
- Create: `lib/cybort/persistence.rb`
- Modify: `lib/cybort.rb`
- Test: `test/persistence_test.rb`

**Interfaces:**

- `Cybort::Persistence.new(path, clock: -> { Time.now.utc })` creates a persistence object.
- `#setup!` creates or migrates the database to schema version 1.
- `#register_instance(instance)` upserts stable instance metadata without storing credentials.
- `#context_for(instance_id:)` returns cached items, last successful fetch time, and parsed synchronization state.
- `#write_fetch_result(result)` upserts all items, updates synchronization state, and records one successful fetch in one transaction.
- `#record_fetch_failure(result)` records one failed fetch without changing last-known-good items or synchronization state.
- `#items_for(instance_id: nil, limit: nil)` returns persisted items for presentation tests.

Define these conceptual tables in schema version 1:

- `schema_migrations(version PRIMARY KEY)`;
- `adapter_instances(id PRIMARY KEY, name, adapter, last_successful_fetch, sync_state_json, created_at, updated_at)`;
- `items(instance_id, canonical_id, urls_json, fetched_at, remote_created_at, title, body, priority, action_item, info_json, PRIMARY KEY(instance_id, canonical_id))`; and
- `fetch_runs(id, instance_id, status, started_at, finished_at, item_count, error_message, metadata_json)`.

- [ ] **Step 1: Write failing database setup and registration tests**

Test that `setup!` creates the four tables, that it is safe to call twice, and that registering the same instance ID updates its display name without creating a duplicate row.

- [ ] **Step 2: Run the focused tests to verify failure**

Run: `bundle exec ruby -Itest test/persistence_test.rb`

Expected: FAIL because `Cybort::Persistence` does not exist.

- [ ] **Step 3: Implement schema initialization**

Open the SQLite database, enable foreign keys, use WAL mode, and apply schema version 1 inside a setup transaction. Keep schema SQL in `Cybort::Schema` so `Persistence` remains focused on operations.

- [ ] **Step 4: Write failing item and fetch-history persistence tests**

Test that:

1. A successful result inserts items and a fetch-run record.
2. Rewriting the same `(instance_id, canonical_id)` updates the item rather than inserting a duplicate.
3. Two instances may use the same canonical ID without colliding.
4. A failure records status and error text while preserving existing items and synchronization state.
5. An invalid item causes the entire adapter-result transaction to roll back.

- [ ] **Step 5: Implement persistence operations**

Serialize arrays and hashes as JSON, store booleans as SQLite integers, and serialize UTC timestamps as RFC 3339 strings. Wrap item upserts, synchronization-state update, and successful fetch-history insert in one transaction. Keep failed fetch recording in its own transaction.

- [ ] **Step 6: Run focused and full tests**

Run: `bundle exec ruby -Itest test/persistence_test.rb`

Expected: PASS.

Run: `bundle exec rake test`

Expected: PASS.

- [ ] **Step 7: Commit SQLite persistence**

```bash
git add lib/cybort/schema.rb lib/cybort/persistence.rb lib/cybort.rb test/persistence_test.rb
git commit -m "feat: add SQLite persistence boundary"
```

### Task 4: Implement the base adapter and RSS adapter

**Files:**

- Create: `lib/cybort/http_client.rb`
- Create: `lib/cybort/adapters/base.rb`
- Create: `lib/cybort/adapters/rss.rb`
- Modify: `lib/cybort.rb`
- Test: `test/http_client_test.rb`
- Test: `test/adapters/base_test.rb`
- Test: `test/adapters/rss_test.rb`
- Fixture: `test/fixtures/rss/basic.xml`
- Fixture: `test/fixtures/rss/no_guid.xml`

**Interfaces:**

- `Cybort::HttpClient#get(url, headers: {})` returns `Cybort::HttpResponse(status:, headers:, body:)`.
- `Cybort::Adapters::Base.new(instance:, context:, http_client:, clock:)` provides common cache freshness and result timing behavior.
- `#fetch(force_fetch: false)` returns a `Cybort::FetchResult`.
- `Cybort::Adapters::RSS` consumes `url`, `ttl_minutes`, and `num_items_to_fetch` from the instance configuration.

- [ ] **Step 1: Write failing HTTP-client contract tests**

Use a fake transport object and verify that `HttpClient` passes the URL and headers through, returns status/body/headers, and raises a source error for non-success responses.

- [ ] **Step 2: Implement the injectable HTTP client**

Use `Net::HTTP` in production and keep the transport injectable so no adapter test performs external I/O. Do not add retry policy in this slice.

- [ ] **Step 3: Write failing base-adapter cache tests**

Test with an injected clock and context that:

1. A fresh cached context returns cached items without calling the HTTP client.
2. A stale context calls the source.
3. `force_fetch: true` calls the source despite a fresh cache.
4. A source exception becomes a failure result with start and finish timestamps.

- [ ] **Step 4: Implement base freshness behavior**

Use `last_successful_fetch` and `ttl_minutes` to determine freshness. Treat only a successful remote fetch as advancing freshness. Preserve cached items in failure results through the context/persistence path.

- [ ] **Step 5: Write failing RSS normalization tests**

Using the XML fixtures, verify that RSS maps:

1. title, description/content, link, publication time, and feed metadata;
2. the first `num_items_to_fetch` records in feed order;
3. a source GUID to `canonical_id`; and
4. a stable SHA-256 fallback based on link, publication time, and title when GUID is absent.

Also test malformed XML as a failure result.

- [ ] **Step 6: Implement RSS parsing**

Use Ruby’s standard-library `RSS` parser. Return one normalized `Item` per selected entry, mark remote fetches with `source_fetched: true`, and include the feed URL in item metadata. Keep the parser independent from SQLite.

- [ ] **Step 7: Run the adapter tests and full suite**

Run: `bundle exec ruby -Itest test/http_client_test.rb test/adapters/base_test.rb test/adapters/rss_test.rb`

Expected: PASS.

Run: `bundle exec rake test`

Expected: PASS.

- [ ] **Step 8: Commit the RSS slice components**

```bash
git add lib/cybort/http_client.rb lib/cybort/adapters/base.rb lib/cybort/adapters/rss.rb lib/cybort.rb test/http_client_test.rb test/adapters/base_test.rb test/adapters/rss_test.rb test/fixtures/rss
git commit -m "feat: add RSS adapter and source client"
```

### Task 5: Add the orchestrator and first CLI path

**Files:**

- Create: `lib/cybort/adapter_registry.rb`
- Create: `lib/cybort/orchestrator.rb`
- Create: `lib/cybort/cli.rb`
- Modify: `bin/cybort`
- Modify: `lib/cybort.rb`
- Test: `test/orchestrator_test.rb`
- Test: `test/cli_test.rb`

**Interfaces:**

- `Cybort::AdapterRegistry.register(name, adapter_class)` registers an adapter.
- `Cybort::AdapterRegistry.build(instance:, context:, http_client:, clock:)` constructs the configured adapter.
- `Cybort::Orchestrator.new(configuration:, persistence:, registry:, http_client:, clock:)` creates a run coordinator.
- `#run(force_fetch: false)` returns a run result containing per-instance statuses and an overall status.
- `Cybort::CLI.start(argv, out:, err:, home:, http_client:)` handles `init`, `--force-fetch`, JSON output, and exit status.

- [ ] **Step 1: Write failing registry and orchestrator tests**

Test that a configured `rss` instance resolves to `Cybort::Adapters::RSS` and that an unknown adapter produces a configuration error before starting threads.

- [ ] **Step 2: Write the concurrency and persistence-order test**

Use two fake adapters that each signal `started` through a `Queue` and wait on a release `Queue`. Assert both start before either is released, then assert a persistence spy receives both results only after both threads return and receives calls sequentially from the orchestrator thread.

- [ ] **Step 3: Implement the orchestrator**

Register all configured instances with `Persistence`, read their contexts before starting workers, create one thread per instance, capture exceptions into failure results, join every thread, and then iterate through returned results to call `write_fetch_result` or `record_fetch_failure`. Never call persistence from a worker thread.

- [ ] **Step 4: Write failing first-slice CLI tests**

Test that:

1. `cybort init PATH` creates the installation directory, schema, and a `cybort.toml` containing `schema_version = 1`.
2. `cybort --force-fetch` loads a one-instance RSS configuration and emits one JSON object to stdout.
3. A second run with fresh data does not call the fake HTTP client.
4. The output includes overall status, instance ID, instance status, and normalized item data.

- [ ] **Step 5: Implement the CLI path**

Use `OptionParser` for `--force-fetch` and a positional `init` command. Keep `home:` and `http_client:` injectable for tests. Emit one JSON document to stdout and diagnostics to stderr. Return status 0 for full success, 1 for partial/total adapter failure, and 2 for configuration or usage errors.

- [ ] **Step 6: Run the first vertical-slice acceptance test**

Run: `bundle exec ruby -Itest test/cli_test.rb test/orchestrator_test.rb`

Expected: PASS with a single RSS instance flowing from TOML through the adapter, orchestrator, SQLite, and CLI output.

Run: `bundle exec rake test`

Expected: PASS.

- [ ] **Step 7: Commit Vertical Slice 1**

```bash
git add bin/cybort lib/cybort.rb lib/cybort/adapter_registry.rb lib/cybort/orchestrator.rb lib/cybort/cli.rb test/orchestrator_test.rb test/cli_test.rb
git commit -m "feat: complete RSS vertical slice"
```

### Vertical Slice 1 acceptance criteria

- A fresh installation can initialize a SQLite database.
- A valid TOML configuration can define one RSS instance.
- The RSS adapter can fetch a fixture-backed feed, normalize entries, and produce stable IDs.
- The orchestrator runs the adapter in a thread and persists its result after the thread completes.
- A second run can return cached items without a source request.
- The CLI reports JSON status and item data.

---

## Vertical Slice 2: Add a second adapter and prove multi-source execution

This slice adds GitHub as a second concrete adapter. GitHub is preferable to
Gmail for this slice because a token-authenticated JSON endpoint exercises a
different response shape and headers without introducing an OAuth flow.

### Task 6: Implement the GitHub notifications adapter

**Files:**

- Create: `lib/cybort/adapters/github.rb`
- Modify: `lib/cybort/adapter_registry.rb`
- Test: `test/adapters/github_test.rb`
- Fixture: `test/fixtures/github/notifications.json`

**Interfaces:**

- `Cybort::Adapters::GitHub` implements the same `Base` constructor and `#fetch(force_fetch: false)` contract as RSS.
- Configuration keys are `api_url` (defaulting to `https://api.github.com/notifications`) and `token`.
- The adapter sends `Accept: application/vnd.github+json` and `Authorization: Bearer <token>` headers.

- [ ] **Step 1: Write failing GitHub mapping tests**

Using the JSON fixture, verify that the adapter maps notification ID, subject title, repository URL, subject URL, reason, and updated timestamp into an `Item`. Verify that `num_items_to_fetch` limits the returned records.

- [ ] **Step 2: Write the missing-token and HTTP-error tests**

Assert that missing `token` is rejected during configuration validation and that a non-success response becomes a failure result without producing partial items.

- [ ] **Step 3: Implement the GitHub adapter**

Parse JSON with the standard library, use the shared HTTP client, map the fixture fields, and register the adapter under `github`. Keep pagination and incremental GitHub cursors out of this slice; preserve the adapter result’s `sync_state` field for later source-specific state.

- [ ] **Step 4: Run the focused adapter tests**

Run: `bundle exec ruby -Itest test/adapters/github_test.rb`

Expected: PASS.

- [ ] **Step 5: Commit the second adapter**

```bash
git add lib/cybort/adapters/github.rb lib/cybort/adapter_registry.rb test/adapters/github_test.rb test/fixtures/github/notifications.json
git commit -m "feat: add GitHub notifications adapter"
```

### Task 7: Add the two-adapter concurrent run and partial-success proof

**Files:**

- Modify: `test/orchestrator_test.rb`
- Modify: `test/cli_test.rb`
- Modify: `test/persistence_test.rb`
- Fixture: `test/fixtures/configuration/rss_and_github.toml`

**Interfaces:**

- No production interface changes; this task proves that the existing registry, orchestrator, and persistence contracts work for multiple adapter types.

- [ ] **Step 1: Write the two-instance integration test**

Load one RSS and one GitHub instance from the fixture configuration, inject a fake HTTP client with one response per endpoint, run the orchestrator, and assert both instances have persisted items in the same SQLite database.

- [ ] **Step 2: Write the concurrency assertion**

Use an instrumented fake client that records both requests before allowing either response to finish. Assert the orchestrator starts both adapter threads before persistence begins. Do not use elapsed-time thresholds.

- [ ] **Step 3: Write the partial-failure assertion**

Seed an existing RSS item, make the GitHub request fail, and assert that the RSS result commits, GitHub’s previous data remains unchanged, and the GitHub fetch run is recorded as failed.

- [ ] **Step 4: Run the multi-source tests**

Run: `bundle exec ruby -Itest test/orchestrator_test.rb test/cli_test.rb test/persistence_test.rb`

Expected: PASS.

Run: `bundle exec rake test`

Expected: PASS.

- [ ] **Step 5: Commit Vertical Slice 2**

```bash
git add test/orchestrator_test.rb test/cli_test.rb test/persistence_test.rb test/fixtures/configuration/rss_and_github.toml
git commit -m "test: prove concurrent multi-adapter persistence"
```

### Vertical Slice 2 acceptance criteria

- RSS and GitHub use the same adapter result and persistence contracts.
- Both sources can be configured in one TOML file and stored in one SQLite database.
- Their fetches overlap in the test without concurrent persistence writes.
- A failure in one source does not roll back the other source.
- Same canonical IDs remain isolated by adapter-instance ID.

---

## Vertical Slice 3: Freshness, forced fetches, and durable fetch history

This slice makes cache behavior and failure state durable and observable without
adding retention or retry policy.

### Task 8: Harden TTL, force-fetch, synchronization state, and transaction behavior

**Files:**

- Modify: `lib/cybort/adapters/base.rb`
- Modify: `lib/cybort/orchestrator.rb`
- Modify: `lib/cybort/persistence.rb`
- Modify: `test/adapters/base_test.rb`
- Modify: `test/orchestrator_test.rb`
- Modify: `test/persistence_test.rb`

**Interfaces:**

- Freshness is based on the last successful remote fetch, not the last failed attempt.
- `#run(force_fetch: true)` passes the force flag to every adapter instance.
- Synchronization state advances only in the same transaction as successful item persistence.

- [ ] **Step 1: Write fake-clock TTL tests**

Use a fixed clock to test a fresh cache, a cache exactly at the TTL boundary, a stale cache, and a forced fetch. Assert the HTTP client call count for each case.

- [ ] **Step 2: Write synchronization-state rollback tests**

Return a new synchronization state from a fake adapter, force a persistence failure, and assert the stored state remains the prior value. Then run a successful result and assert the new state is stored.

- [ ] **Step 3: Write fetch-history assertions**

Assert successful rows contain start time, finish time, status, and item count; failed rows contain status and error text; and failures do not update `last_successful_fetch`.

- [ ] **Step 4: Implement the minimal behavior**

Keep retry and exponential backoff out of the implementation. Ensure a cache hit is reported as a non-remote source result, while a successful empty remote result still updates successful-fetch state.

- [ ] **Step 5: Run the reliability tests**

Run: `bundle exec ruby -Itest test/adapters/base_test.rb test/orchestrator_test.rb test/persistence_test.rb`

Expected: PASS.

- [ ] **Step 6: Commit Vertical Slice 3**

```bash
git add lib/cybort/adapters/base.rb lib/cybort/orchestrator.rb lib/cybort/persistence.rb test/adapters/base_test.rb test/orchestrator_test.rb test/persistence_test.rb
git commit -m "feat: persist freshness and fetch history"
```

### Vertical Slice 3 acceptance criteria

- Normal runs avoid remote calls while cached data is fresh.
- `--force-fetch` bypasses TTL checks.
- Failed fetches preserve the last known-good data and freshness state.
- Synchronization state and item writes commit together.
- Fetch history explains successful and failed remote attempts.

---

## Vertical Slice 4: Safe initialization, configuration UX, and release hardening

This slice finishes the user-facing initialization flow and makes the core
behavior easy to run and verify locally.

### Task 9: Implement safe installation initialization

**Files:**

- Create: `lib/cybort/installer.rb`
- Modify: `lib/cybort/cli.rb`
- Modify: `bin/cybort`
- Test: `test/installer_test.rb`
- Modify: `test/cli_test.rb`

**Interfaces:**

- `Cybort::Installer.new(io:, clock:)` provides interactive initialization with injectable I/O.
- `#run(location:)` creates a new installation or requires an explicit choice for an existing installation.
- Existing-install choices are: keep/cancel, back up and retain configuration while resetting data, back up and reset everything, or reset without backup after a second confirmation.

- [ ] **Step 1: Write failing new-install tests**

Assert that a new location receives `cybort.toml`, SQLite storage, and the schema version marker, and that the command can be run with a temporary directory.

- [ ] **Step 2: Write failing existing-install safety tests**

Assert that an existing location is never changed without an explicit choice, that backup choices create a timestamped sibling `.tar.gz` backup before reset, and that the no-backup reset path requires a second confirmation.

- [ ] **Step 3: Implement the installer**

Use `FileUtils` to create directories and `tar -czf` through `Open3.capture3` to create a timestamped sibling `.tar.gz` backup before destructive reset choices. Verify the command succeeds before deleting or replacing the installation. Keep the current configuration only for the “retain configuration” choice. Abort on cancel or a negative second confirmation.

- [ ] **Step 4: Run installer and CLI tests**

Run: `bundle exec ruby -Itest test/installer_test.rb test/cli_test.rb`

Expected: PASS.

- [ ] **Step 5: Commit safe initialization**

```bash
git add lib/cybort/installer.rb lib/cybort/cli.rb bin/cybort test/installer_test.rb test/cli_test.rb
git commit -m "feat: add safe Cybort initialization"
```

### Task 10: Document local usage and run the full verification suite

**Files:**

- Modify: `README.md`
- Modify: `Gemfile`
- Modify: `Rakefile`
- Create: `test/system/cli_system_test.rb`

- [ ] **Step 1: Write the system-test scenarios**

Cover these command-level scenarios with temporary home/config/database paths:

1. `cybort init PATH` creates a usable installation.
2. A one-instance RSS run returns JSON and persists an item.
3. A two-instance RSS/GitHub run reports both statuses.
4. A failed source produces a nonzero partial-failure status while retaining another source’s data.

- [ ] **Step 2: Implement the system tests and test command**

Keep the fake HTTP client injected at the CLI boundary. Make `bundle exec rake test` run unit, integration, and system tests in one invocation.

- [ ] **Step 3: Update README usage**

Document installation, `cybort init`, the TOML shape with `num_items_to_fetch`, normal fetches, `--force-fetch`, JSON output, partial-failure behavior, and the location of the design/ADR documents.

- [ ] **Step 4: Run the complete verification suite**

Run:

```bash
bundle exec rake test
bundle exec ruby -Ilib bin/cybort --help
git diff --check
```

Expected: all tests pass, help exits successfully, and `git diff --check` reports no whitespace errors.

- [ ] **Step 5: Commit release hardening**

```bash
git add README.md Gemfile Rakefile test/system/cli_system_test.rb
git commit -m "docs: document Cybort local usage"
```

### Vertical Slice 4 acceptance criteria

- Initialization is explicit and safe for existing installations.
- The command-line workflow is documented and testable without external services.
- Full tests cover one adapter, two adapters, concurrency, persistence, cache behavior, and partial failure.
- The README and design records describe the implemented boundaries accurately.

## Final verification checklist

- [ ] `docs/initial-spitballing.md` remains unchanged.
- [ ] All runtime dependencies are declared in `Gemfile`.
- [ ] No production test contacts Gmail, GitHub, RSS, or another external service.
- [ ] One SQLite database is used in every integration/system test.
- [ ] Adapter threads never invoke SQLite writes.
- [ ] The orchestrator waits for every adapter result before persistence.
- [ ] Each successful adapter result has an independent transaction.
- [ ] Partial failure preserves successful data.
- [ ] `num_items_to_fetch` appears consistently in code, fixtures, tests, README, and examples.
- [ ] `bundle exec rake test` passes before implementation is declared complete.
