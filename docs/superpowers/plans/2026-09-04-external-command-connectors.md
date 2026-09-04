# External Command Connectors and Gmail Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add safe, context-aware external-command support and a read-only Gmail adapter backed by the Google-maintained `gws` CLI while preserving Cybort's existing adapter, cache, persistence, and failure contracts.

**Architecture:** Adapters declare executable dependencies in `AdapterRegistry`. The orchestrator validates configuration, loads contexts, asks each adapter whether a remote fetch is needed, resolves dependencies only for those instances, and then starts ready adapter threads. A bounded injectable `CommandRunner` invokes absolute executable paths; `Adapters::Gmail` constructs `gws` arguments, parses JSON, normalizes messages, and returns the same `FetchResult` used by HTTP adapters. Persistence remains sequential and SQLite-backed.

**Tech Stack:** Ruby 3.x, Minitest, `Open3`, `Timeout`-free monotonic deadlines, TOML configuration, SQLite persistence, Google Workspace CLI (`gws`) 0.22.x.

**Spec:** `docs/superpowers/specs/2026-09-04-external-command-connectors-design.md`

## Global Constraints

- Support `gws` versions `>= 0.22.5, < 0.23.0`; update this range only after a manual contract smoke test and new fixtures.
- Gmail authentication is performed outside Cybort with `gws auth login --scopes https://www.googleapis.com/auth/gmail.readonly`; Cybort never owns OAuth credentials or invokes interactive login.
- Resolve and pass the exact absolute executable path; never invoke a shell or `which`.
- Preflight dependencies per instance and only when that instance needs a remote fetch; fresh cache hits must work without `gws`.
- Missing dependencies and command/authentication failures are source failures (exit status `1`); malformed configuration and unknown adapters remain run-wide configuration errors (exit status `2`).
- Never persist or emit raw subprocess stdout/stderr, credential paths, tokens, email addresses, control characters, or unbounded output in errors.
- `CommandRunner` caps each output stream at `1_048_576` bytes, uses a 30-second default command timeout, terminates and reaps children, and allows only `HOME`, `PATH`, `TMPDIR`, and connector-provided environment variables.
- Gmail fetches one bounded list page and message metadata only; no send/mutate operations, pagination, MIME/attachment extraction, history synchronization, retry, retention, or query-based deletion.
- Production tests are offline and use fake HTTP/command clients and fixtures; no test invokes `gws`, `gh`, Gmail, GitHub, or another external service.
- Do not modify `docs/initial-spitballing.md`.

---

## File and module map

Create or modify only the following files unless a failing test demonstrates a necessary adjacent change:

| File | Responsibility |
| --- | --- |
| `lib/cybort/command_runner.rb` | Safe bounded subprocess execution and `CommandResult`. |
| `lib/cybort/dependency.rb` | Dependency declaration and resolution value objects. |
| `lib/cybort/dependency_checker.rb` | PATH lookup, executable checks, and tool-version validation. |
| `lib/cybort/adapters/base.rb` | Injectable runner/dependency context and public cache-plan decision. |
| `lib/cybort/fetch_result.rb` | Optional safe failure metadata. |
| `lib/cybort/adapter_registry.rb` | Factory, dependency, and adapter validation registry. |
| `lib/cybort/orchestrator.rb` | Per-instance planning/preflight and thread coordination. |
| `lib/cybort/cli.rb` | Construct/inject checker and runner; preserve exit/output contracts. |
| `lib/cybort/adapters/gmail.rb` | Gmail `gws` command construction, parsing, normalization, and safe failures. |
| `lib/cybort.rb` | Require new modules and register Gmail through the default registry. |
| `test/command_runner_test.rb` | Runner process, timeout, bounds, and environment tests. |
| `test/dependency_checker_test.rb` | Resolution/version tests. |
| `test/adapter_registry_test.rb` | Registry dependency/configuration behavior. |
| `test/adapters/base_test.rb` | Cache-plan and injected dependency behavior. |
| `test/fetch_result_test.rb` | Failure metadata behavior. |
| `test/orchestrator_test.rb` | Preflight and thread-isolation behavior. |
| `test/cli_test.rb` | Dependency guidance and exit status behavior. |
| `test/adapters/gmail_test.rb` | Gmail fixtures, normalization, command failures, and deadlines. |
| `test/fixtures/gmail/list.json` | Representative list response. |
| `test/fixtures/gmail/details/*.json` | Representative detail responses. |
| `test/fixtures/gmail/empty.json` | Successful empty-list response. |
| `test/system/cli_system_test.rb` | End-to-end fake-runner SQLite path and cache isolation. |
| `README.md` | User setup, dependency/authentication instructions, and smoke test. |
| `AGENTS.md` | Stable external-dependency invariant. |
| `docs/LEARNINGS.md` | Dated implementation gotchas with evidence/tests. |
| `docs/adr/0002-external-command-dependencies-and-cli-adapters.md` | Mark decision Accepted and link implementation. |
| `docs/adr/README.md` | Keep ADR status/index current. |

## Interfaces introduced

Later tasks consume these exact interfaces:

```ruby
CommandResult = Struct.new(
  :argv, :stdout, :stderr, :status, :executable, :version,
  :stdout_truncated, :stderr_truncated, :timed_out, keyword_init: true
)

CommandRunner#run(argv, env: {}, timeout_seconds: 30, max_output_bytes: 1_048_576)
# => CommandResult

Dependency = Struct.new(:executable, :purpose, :install_hint, :version_requirement, keyword_init: true)
DependencyResolution = Struct.new(:dependency, :path, :version, :error, keyword_init: true)

DependencyChecker#resolve(dependency, env: ENV.to_h)
# => DependencyResolution

Adapters::Base#needs_remote_fetch?(force_fetch: false)
# => true/false

FetchResult.failure(instance_id:, error:, started_at:, finished_at:, metadata: {})
```

---

### Task 1: Add the bounded command runner

**Files:**
- Create: `lib/cybort/command_runner.rb`
- Create: `test/command_runner_test.rb`
- Modify: `lib/cybort.rb` to require the runner

**Interfaces:**
- Consumes: absolute executable paths and argument arrays from adapters/checkers.
- Produces: `Cybort::CommandRunner`, `Cybort::CommandResult`, and safe process results for Tasks 2 and 5.

- [ ] **Step 1: Write failing tests for process behavior**

```ruby
def test_run_passes_arguments_without_shell_interpretation
  result = runner.run([ruby, "-e", "puts ARGV.inspect", "a;$(touch /tmp/nope)"])
  assert_equal ["a;$(touch /tmp/nope)"], JSON.parse(result.stdout)
  assert result.status.success?
end

def test_rejects_empty_argv
  assert_raises(ArgumentError) { runner.run([]) }
end

def test_limits_output_and_marks_truncation
  result = runner.run([ruby, "-e", "print 'x' * 200"], max_output_bytes: 32)
  assert_equal 32, result.stdout.bytesize
  assert result.stdout_truncated
end
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run: `bundle exec ruby -Itest test/command_runner_test.rb`
Expected: FAIL because `Cybort::CommandRunner` and `CommandResult` do not yet exist.

- [ ] **Step 3: Implement `CommandRunner#run`**

Use `Open3.popen3(env, executable, *argv.drop(1), unsetenv_others: true, pgroup: true)` after validating an absolute executable path. Start concurrent readers for stdout and stderr, retain at most `max_output_bytes` per stream, and record truncation. Poll `wait_thr.join(0.01)` against `Process.clock_gettime(Process::CLOCK_MONOTONIC)`. On deadline, send `TERM` to the process group, wait 0.25 seconds, send `KILL` if still alive, then reap. Return `timed_out: true` with the resulting status; do not raise for non-zero exit, timeout, or truncated output.

The child environment must be built from `HOME`, `PATH`, `TMPDIR`, plus explicit `env` keys. Reject environment keys outside that allow-list unless they are prefixed `CYBORT_`. Close all pipes in `ensure` and join reader threads before returning.

- [ ] **Step 4: Add timeout/environment tests and run the suite**

Test a child that sleeps past a 0.05-second timeout, assert `timed_out`, assert the child is reaped, and test that a parent-only secret is absent when the child prints its environment. Also test stderr truncation and non-zero status.

Run: `bundle exec ruby -Itest test/command_runner_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cybort/command_runner.rb lib/cybort.rb test/command_runner_test.rb
git commit -m "feat: add bounded command runner"
```

### Task 2: Add dependency declarations and checking

**Files:**
- Create: `lib/cybort/dependency.rb`
- Create: `lib/cybort/dependency_checker.rb`
- Create: `test/dependency_checker_test.rb`
- Modify: `lib/cybort.rb` to require both modules

**Interfaces:**
- Consumes: `Dependency` declarations and a `PATH` string.
- Produces: exact absolute paths, tested versions, and safe `DependencyResolution` errors for the registry/orchestrator.

- [ ] **Step 1: Write failing resolution/version tests**

Use a temporary directory containing executable and non-executable files. Assert that duplicate PATH entries are de-duplicated, an empty PATH component searches `Dir.pwd`, directories are rejected, and missing tools report purpose/install hint. Inject a fake command runner for `gws --version` and assert `0.22.5` passes while `0.23.0` and malformed output fail.

- [ ] **Step 2: Run the focused tests and verify failure**

Run: `bundle exec ruby -Itest test/dependency_checker_test.rb`
Expected: FAIL because the value objects/checker are absent.

- [ ] **Step 3: Implement `Dependency` and `DependencyChecker`**

`Dependency` validates a nonblank executable and `Gem::Requirement`-compatible version requirement. `DependencyChecker#resolve` scans `env.fetch("PATH", "")` directly, treats `""` as `Dir.pwd`, requires `File.file?` and `File.executable?`, and returns the first expanded absolute path. If a version requirement exists, call the injected runner with `[path, "--version"]`, parse the first semantic `X.Y.Z` token, and check `Gem::Version`. Return a `DependencyResolution` with a static error category (`missing`, `version_check_failed`, or `unsupported_version`) and no command output.

- [ ] **Step 4: Run focused and full tests**

Run: `bundle exec ruby -Itest test/dependency_checker_test.rb && bundle exec rake test`
Expected: PASS with the existing 51-test suite plus the new tests.

- [ ] **Step 5: Commit**

```bash
git add lib/cybort/dependency.rb lib/cybort/dependency_checker.rb lib/cybort.rb test/dependency_checker_test.rb
git commit -m "feat: add external dependency checking"
```

### Task 3: Extend fetch results and adapter planning

**Files:**
- Modify: `lib/cybort/fetch_result.rb`
- Modify: `lib/cybort/adapters/base.rb`
- Modify: `test/fetch_result_test.rb`
- Modify: `test/adapters/base_test.rb`

**Interfaces:**
- Consumes: optional safe metadata and injected `command_runner`/dependency resolutions.
- Produces: `FetchResult.failure(..., metadata:)` and public `Base#needs_remote_fetch?` for orchestrator preflight.

- [ ] **Step 1: Write failing result and cache-plan tests**

```ruby
def test_failure_preserves_safe_metadata
  result = FetchResult.failure(
    instance_id: "gmail",
    error: SourceError.new("gws failed"),
    started_at: now,
    finished_at: now,
    metadata: { tool: "gws", exit_category: "nonzero", exit_code: 1 }
  )
  assert_equal({ tool: "gws", exit_category: "nonzero", exit_code: 1 }, result.metadata)
end

def test_stale_cache_needs_remote_fetch
  adapter = build_adapter(last_successful_fetch: now - 3_600)
  assert adapter.needs_remote_fetch?
end

def test_fresh_cache_does_not_need_remote_fetch
  adapter = build_adapter(last_successful_fetch: now - 60)
  refute adapter.needs_remote_fetch?
end
```

- [ ] **Step 2: Run focused tests to verify failure**

Run: `bundle exec ruby -Itest test/fetch_result_test.rb test/adapters/base_test.rb`
Expected: FAIL because `FetchResult.failure` drops metadata and `Base#needs_remote_fetch?` is absent.

- [ ] **Step 3: Implement the smallest compatible changes**

Add `metadata: {}` to `FetchResult.failure`. In `Base`, accept optional `command_runner:` and `dependency_resolutions:` keyword arguments, expose readers, and implement:

```ruby
def needs_remote_fetch?(force_fetch: false)
  force_fetch || !fresh_cache?
end
```

Make `fetch` use this method and pass safe metadata through rescue. Preserve the existing cached-result shape and all existing adapter constructor calls by giving new arguments defaults.

- [ ] **Step 4: Run focused and full tests**

Run: `bundle exec ruby -Itest test/fetch_result_test.rb test/adapters/base_test.rb && bundle exec rake test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cybort/fetch_result.rb lib/cybort/adapters/base.rb test/fetch_result_test.rb test/adapters/base_test.rb
git commit -m "feat: expose fetch planning and safe failure metadata"
```

### Task 4: Integrate registry metadata and per-instance preflight

**Files:**
- Modify: `lib/cybort/adapter_registry.rb`
- Modify: `lib/cybort/orchestrator.rb`
- Modify: `lib/cybort/cli.rb`
- Modify: `lib/cybort.rb`
- Create or modify: `test/adapter_registry_test.rb`, `test/orchestrator_test.rb`, `test/cli_test.rb`

**Interfaces:**
- Consumes: `DependencyChecker#resolve`, adapter `validate_configuration!` hooks, and `Base#needs_remote_fetch?`.
- Produces: registry entries with factories/dependencies and an orchestrator that preflights exactly once before starting ready threads.

- [ ] **Step 1: Write failing integration tests**

Cover these cases explicitly:

1. Registry validation rejects an unknown adapter and an adapter-level invalid option before any dependency checker call.
2. A fresh Gmail context with a missing `gws` dependency returns `:cached`, and the checker is not called.
3. A stale Gmail context with missing `gws` returns `:failure` without starting a Gmail thread; a concurrent RSS instance still fetches and persists.
4. `force_fetch: true` makes a fresh Gmail instance require the dependency.
5. A dependency checker call occurs once per remote-fetch instance, before the adapter thread begins.

- [ ] **Step 2: Run focused tests to verify failure**

Run: `bundle exec ruby -Itest test/adapter_registry_test.rb test/orchestrator_test.rb test/cli_test.rb`
Expected: FAIL because registry entries do not carry dependency metadata and orchestration has no preflight phase.

- [ ] **Step 3: Extend `AdapterRegistry`**

Change `register` to accept `dependencies: []` and store an entry struct containing `factory`, `dependencies`, and optional `validate_configuration`. Keep existing class/callable factories working. Add `validate_configuration!(instance)` that calls the hook without HTTP, command, or persistence side effects. Add `dependencies_for(instance)` and pass `command_runner:` and `dependency_resolutions:` through `build`.

Register `rss` and `github` with empty dependency arrays. Register `gmail` in Task 5 with the `gws` declaration.

- [ ] **Step 4: Refactor `Orchestrator#run` into explicit phases**

Keep `register_instance` and context loading before planning. Build an adapter synchronously for each instance, call `validate_configuration!`, then `needs_remote_fetch?`. For remote plans, call the checker once per declared dependency and retain the exact path/version. Convert an unsuccessful resolution to a `FetchResult.failure` with static safe metadata and do not create a thread. Build threads only for ready plans, passing the resolved dependency and runner into the adapter. Merge preflight failures and thread results in configuration order, then reuse sequential `persist_result` handling unchanged.

Do not preflight fresh cache hits. Do not rescue a configuration validation error as a source failure; let it reach the existing CLI status-2 rescue. Rescue only dependency and command-readiness failures as source failures with bounded metadata.

- [ ] **Step 5: Inject dependencies from `CLI`**

Construct one `CommandRunner` and one `DependencyChecker` (the latter receives the runner) in `CLI.start`, and pass them to `Orchestrator`. Preserve optional test injection by adding keyword arguments with defaults. Sanitize `InstanceRunStatus#to_h` so only safe error class/message and metadata are emitted; do not add raw command output.

- [ ] **Step 6: Run focused and full tests**

Run: `bundle exec ruby -Itest test/adapter_registry_test.rb test/orchestrator_test.rb test/cli_test.rb && bundle exec rake test`
Expected: PASS; existing RSS/GitHub behavior and exit statuses remain unchanged.

- [ ] **Step 7: Commit**

```bash
git add lib/cybort/adapter_registry.rb lib/cybort/orchestrator.rb lib/cybort/cli.rb lib/cybort.rb test/adapter_registry_test.rb test/orchestrator_test.rb test/cli_test.rb
git commit -m "feat: preflight connector dependencies per instance"
```

### Task 5: Implement the read-only Gmail adapter through `gws`

**Files:**
- Create: `lib/cybort/adapters/gmail.rb`
- Create: `test/adapters/gmail_test.rb`
- Create: `test/fixtures/gmail/list.json`
- Create: `test/fixtures/gmail/empty.json`
- Create: `test/fixtures/gmail/details/one.json`, `test/fixtures/gmail/details/two.json`
- Modify: `lib/cybort/adapter_registry.rb` and `lib/cybort.rb`

**Interfaces:**
- Consumes: resolved `gws` dependency, injected `CommandRunner`, `Configuration::Instance`, and `Item`/`FetchResult` contracts.
- Produces: normalized Gmail `Item` values and safe source failures for Task 6.

- [ ] **Step 1: Add fixtures and failing normalization tests**

The list fixture must include duplicate IDs, an invalid blank entry, and a valid ID. Detail fixtures must exercise case-insensitive headers, blank subject, missing snippet, labels/thread metadata, valid and invalid `internalDate`, and a mismatched ID. Assert canonical identity, title/body/timestamp/info mapping and first-seen de-duplication.

- [ ] **Step 2: Run focused tests to verify failure**

Run: `bundle exec ruby -Itest test/adapters/gmail_test.rb`
Expected: FAIL because the Gmail adapter is absent.

- [ ] **Step 3: Implement configuration validation and command construction**

Accept `user_id` (default `"me"`), `query` (default `""`), and positive `num_items_to_fetch` from the common instance. Build arguments without a shell:

```ruby
[gws_path, "gmail", "users", "messages", "list", "--params", JSON.generate(params)]
[gws_path, "gmail", "users", "messages", "get", "--params", JSON.generate(
  { "userId" => user_id, "id" => message_id, "format" => "metadata",
    "metadataHeaders" => ["Subject", "From", "Date", "Message-ID"] }
)]
```

Include `maxResults` equal to `num_items_to_fetch` and add `q` only when nonblank. Use the exact resolved path from the dependency checker.

- [ ] **Step 4: Implement bounded fetch, parsing, and normalization**

Use a monotonic five-minute adapter deadline and pass the remaining seconds to each 30-second maximum command. Treat an omitted or empty `messages` array as success with zero items. Reject non-object records, blank IDs, mismatched detail IDs, malformed JSON, empty stdout, non-zero status, timeouts, and output truncation. De-duplicate IDs before detail calls and fail the entire attempt if any detail fails.

Normalize headers case-insensitively, choose the first nonblank value, use `(no subject)` for a blank/missing subject, retain snippet or `nil`, parse only positive integer millisecond timestamps to UTC, and keep optional labels/thread/sender/Message-ID in `info`. Set `urls: []`, `sync_state: {}`, and metadata containing only tool/version/query/limit/command statuses. Raise a `SourceError` or dedicated `CommandError` whose message is static and whose metadata excludes all command output.

- [ ] **Step 5: Register Gmail and test failures/deadlines**

Register `gmail` with `Dependency.new(executable: "gws", purpose: "Google-maintained Google Workspace CLI", install_hint: "brew install googleworkspace-cli", version_requirement: ">= 0.22.5, < 0.23.0")`. Test list/detail argument JSON, empty results, safe malformed/non-zero/timeout failures, aggregate deadline enforcement, and that no partial items are returned.

- [ ] **Step 6: Run adapter and full tests**

Run: `bundle exec ruby -Itest test/adapters/gmail_test.rb && bundle exec rake test`
Expected: PASS with no external process or network access.

- [ ] **Step 7: Commit**

```bash
git add lib/cybort/adapters/gmail.rb lib/cybort/adapter_registry.rb lib/cybort.rb test/adapters/gmail_test.rb test/fixtures/gmail
git commit -m "feat: add read-only Gmail gws adapter"
```

### Task 6: Complete integration, documentation, and verification

**Files:**
- Modify: `test/system/cli_system_test.rb`
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `docs/LEARNINGS.md`
- Modify: `docs/adr/0002-external-command-dependencies-and-cli-adapters.md`
- Modify: `docs/adr/README.md`

**Interfaces:**
- Consumes: all implementation tasks and the approved design/ADR.
- Produces: documented installation/authentication procedure, durable invariants, accepted ADR status, and evidence-backed offline/system coverage.

- [ ] **Step 1: Add system tests**

Use a fake command runner and temporary SQLite/configuration to prove Gmail items persist through the normal CLI/orchestrator path. Add one fresh-cache/missing-`gws` case, one stale-cache/missing-`gws` plus healthy RSS case, one `--force-fetch` case, and one command-failure case proving existing SQLite items remain intact.

- [ ] **Step 2: Update user-facing setup**

In `README.md`, document:

```bash
brew install googleworkspace-cli
gws auth setup
gws auth login --scopes https://www.googleapis.com/auth/gmail.readonly
gws auth status
```

Explain that `gws` is Google-maintained but its README says it is not an officially supported Google product and is pre-1.0. Explain that `gcloud` is needed only for automated `gws auth setup`; manual Cloud Console setup is an alternative. Document that Cybort scans required tools before stale/forced fetches, gives Homebrew guidance, and never performs interactive login.

- [ ] **Step 3: Update durable memory and ADR index**

Add the implemented dependency-preflight invariant to `AGENTS.md`. Add a dated `docs/LEARNINGS.md` entry with evidence (tests and manual smoke-test command) for the `gws` version/scope boundary and any implementation gotcha discovered. Change ADR 0002 status to `Accepted`, add implementation links, and update `docs/adr/README.md` status/links. Do not alter the historical spitballing document.

- [ ] **Step 4: Run complete verification**

Run:

```bash
bundle exec rake test
git diff --check
git diff --exit-code -- docs/initial-spitballing.md
```

Also scan the plan and spec for unresolved placeholder markers; expected: no matches. All tests pass, no whitespace errors, and the historical document is unchanged.

- [ ] **Step 5: Commit and push the implementation**

```bash
git add test/system/cli_system_test.rb README.md AGENTS.md docs/LEARNINGS.md docs/adr/0002-external-command-dependencies-and-cli-adapters.md docs/adr/README.md
git commit -m "feat: integrate Gmail connector workflow"
git push origin main
```

## Manual contract smoke test before a `gws` version-range update

Run this only with an installed, authenticated test account; it is not part of the offline suite:

```bash
gws --version
gws auth status
gws gmail users messages list --params '{"userId":"me","maxResults":1}'
```

Confirm the explicit read-only scope, inspect the JSON shapes captured by the Gmail fixtures, and record the date/version in `docs/LEARNINGS.md` before changing the supported range.

## Execution handoff

Execute Tasks 1 through 6 in order. Each task is independently testable and ends in a focused commit. After Task 6, request the required high-effort Sol code-quality review against the implementation commits, apply verified findings, run `bundle exec rake test` again, and push the review fixes as a separate commit.
