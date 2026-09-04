# External Command Connectors and Gmail Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add safe, context-aware external-command support and a read-only Gmail adapter backed by the Google-maintained `gws` CLI while preserving Cybort's existing adapter, cache, persistence, and failure contracts.

**Architecture:** Adapters declare executable dependencies in `AdapterRegistry`. The orchestrator validates configuration, loads contexts, asks each adapter whether a remote fetch is needed, resolves dependencies only for those instances, and then starts ready adapter threads. A bounded injectable `CommandRunner` invokes absolute executable paths; `Adapters::Gmail` constructs `gws` arguments, parses JSON, normalizes messages, and returns the same `FetchResult` used by HTTP adapters. Persistence remains sequential and SQLite-backed.

**Tech Stack:** Ruby 4.0.1, Minitest, `Open3`, `Timeout`-free monotonic deadlines, TOML configuration, SQLite persistence, Google Workspace CLI (`gws`) 0.22.x on macOS/POSIX.

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
| `lib/cybort/command_runner.rb` | Safe bounded subprocess execution, process-tree cleanup, and `CommandResult`. |
| `lib/cybort/errors.rb` | Typed safe `CommandError` metadata contract. |
| `lib/cybort/dependency.rb` | Dependency declaration and resolution value objects. |
| `lib/cybort/dependency_checker.rb` | PATH lookup, executable checks, and tool-version validation. |
| `lib/cybort/adapters/base.rb` | Injectable runner/dependency context and execution of a frozen cache plan. |
| `lib/cybort/fetch_result.rb` | Optional safe failure metadata. |
| `lib/cybort/adapter_registry.rb` | Factory, dependency, and adapter validation registry. |
| `lib/cybort/orchestrator.rb` | Validation, immutable per-instance plans, dependency preflight, grouping, and thread coordination. |
| `lib/cybort/cli.rb` | Construct/inject checker and runner; preserve exit/output contracts. |
| `lib/cybort/adapters/gmail.rb` | Gmail `gws` command construction, parsing, normalization, deadlines, and safe failures. |
| `lib/cybort.rb` | Require new modules and register Gmail through the default registry. |
| `test/command_runner_test.rb` | Runner process-tree lifecycle, timeout, bounds, and environment tests. |
| `test/errors_test.rb` | Safe `CommandError` metadata validation. |
| `test/dependency_checker_test.rb` | Resolution/version tests. |
| `test/adapter_registry_test.rb` | Registry dependency/configuration behavior. |
| `test/adapters/base_test.rb` | Frozen cache-plan execution and injected dependency behavior. |
| `test/fetch_result_test.rb` | Failure metadata behavior. |
| `test/orchestrator_test.rb` | Preflight and thread-isolation behavior. |
| `test/cli_test.rb` | Grouped dependency guidance, metadata, and exit status behavior. |
| `test/adapters/gmail_test.rb` | Gmail fixtures, normalization, command failures, and deadlines. |
| `test/fixtures/gmail/list_valid.json` | Valid list response with duplicate IDs. |
| `test/fixtures/gmail/list_blank_id.json` | Invalid list response with a blank ID. |
| `test/fixtures/gmail/list_over_limit.json` | List response exceeding the configured limit. |
| `test/fixtures/gmail/details/valid_one.json`, `valid_two.json` | Successful detail variants. |
| `test/fixtures/gmail/details/mismatched_id.json` | Invalid detail response with an ID mismatch. |
| `test/fixtures/gmail/details/malformed.json` | Malformed detail JSON fixture. |
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
  :argv, :stdout, :stderr, :status, :timed_out,
  :stdout_truncated, :stderr_truncated, :spawn_error_category,
  keyword_init: true
)

CommandRunner#run(argv, env: {}, allowed_env_keys: [], timeout_seconds: 30, max_output_bytes: 1_048_576)
# => CommandResult

Dependency = Struct.new(
  :executable, :purpose, :install_hint, :auth_hint, :version_requirement,
  :environment_keys, keyword_init: true
)
DependencyResolution = Struct.new(:dependency, :path, :version, :error, keyword_init: true)

DependencyChecker#resolve(dependency, env: ENV.to_h)
# => DependencyResolution
DependencyChecker#validate_version!(dependency, resolution)
# => DependencyResolution

AdapterPlan = Struct.new(
  :instance, :context, :fetch_mode, :planned_at, :dependency_requirements,
  :resolutions, keyword_init: true
)

Adapters::Base#fetch(fetch_mode:, planned_at:)
# => FetchResult

FetchResult.failure(instance_id:, error:, started_at:, finished_at:, metadata: {})

CommandError < SourceError
# safe_metadata => frozen hash containing only allow-listed scalar values
```

---

### Task 1: Add the bounded command runner and typed command errors

**Files:**
- Create: `lib/cybort/command_runner.rb`
- Create: `lib/cybort/errors.rb`
- Create: `test/command_runner_test.rb`
- Create: `test/errors_test.rb`
- Modify: `lib/cybort.rb` to require the error and runner modules

**Interfaces:**
- Consumes: absolute executable paths and argument arrays from adapters/checkers.
- Produces: `Cybort::CommandRunner`, `Cybort::CommandResult`, and `Cybort::CommandError` for Tasks 2 and 5.

- [ ] **Step 1: Write failing tests for process behavior**

```ruby
def test_run_passes_arguments_without_shell_interpretation
  path = File.join(Dir.mktmpdir, "should-not-exist")
  refute_path_exists path
  result = runner.run([ruby, "-e", "puts ARGV.inspect", "a;$(touch #{path})"])
  assert_equal ["a;$(touch #{path})"], JSON.parse(result.stdout)
  assert result.status.success?
  refute_path_exists path
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

Use `Open3.popen3(env, executable, *argv.drop(1), unsetenv_others: true, pgroup: true)` after validating an absolute executable path. Close `stdin` immediately because commands never receive input. Start concurrent readers for stdout and stderr, continue draining both streams after retention caps are reached, retain at most `max_output_bytes` per stream, and record truncation. Apply one monotonic deadline to process wait and pipe draining. Poll `wait_thr.join(0.01)` against `Process.clock_gettime(Process::CLOCK_MONOTONIC)`. On deadline, send `TERM` to the process group, wait 0.25 seconds, send `KILL` if still alive, then reap. If the leader exits while descendants retain output descriptors, allow only a short drain grace period before terminating the process group, close read ends, and join reader threads. Handle `Errno::ESRCH`, `IOError`, and closed-stream races. Return `timed_out: true` with the resulting status; do not raise for non-zero exit, timeout, or truncated output.

The child environment must be built from `HOME`, `PATH`, `TMPDIR`, plus explicit `env` keys listed in `allowed_env_keys` (and `CYBORT_*`). Reject environment keys outside that allow-list. The runner is POSIX/macOS-only for this slice; Windows process-tree termination is a deferred design. Close all pipes in `ensure` and join reader threads before returning. Validate a positive finite timeout and nonnegative integer output cap. On spawn/permission failure, return `spawn_error_category` as one of `not_found`, `permission`, or `other`, with no OS path/message in the result.

- [ ] **Step 4: Add timeout/environment tests and run the suite**

Test a child that exits only after stdin EOF, a leader that exits while a descendant retains stdout/stderr, and a TERM-ignoring child requiring KILL. Assert children are reaped and reader threads terminate. Test simultaneous stdout and stderr larger than the OS pipe capacity, a unique temporary shell-injection path that is not created, parent-only secrets absent from the child environment, spawn failure categories, stderr truncation, non-zero status, invalid timeout, and invalid output cap.

Run: `bundle exec ruby -Itest test/command_runner_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/cybort/command_runner.rb lib/cybort/errors.rb lib/cybort.rb test/command_runner_test.rb test/errors_test.rb
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

Use a temporary directory containing executable and non-executable files. Assert that duplicate PATH entries are de-duplicated, an empty PATH component searches `Dir.pwd`, directories are rejected, and missing tools report purpose/install hint. Inject a fake command runner for `gws --version` and assert `gws version 0.22.5` passes while `gws version 0.23.0`, `gws version 0.22.5-rc1`, an unrelated earlier version token, stderr-only output, truncated output, and malformed output fail. Test lower and upper bounds and whitespace around the documented line.

- [ ] **Step 2: Run the focused tests and verify failure**

Run: `bundle exec ruby -Itest test/dependency_checker_test.rb`
Expected: FAIL because the value objects/checker are absent.

- [ ] **Step 3: Implement `Dependency` and `DependencyChecker`**

`Dependency` validates a nonblank executable and `Gem::Requirement`-compatible version requirement. `DependencyChecker#resolve` scans `env.fetch("PATH", "")` directly, treats `""` as `Dir.pwd`, requires `File.file?` and `File.executable?`, and returns the first expanded absolute path. If a version requirement exists, call the injected runner with `[path, "--version"]`, parse the documented `gws version X.Y.Z` line (allowing a leading `v` but rejecting prerelease/build suffixes), and check `Gem::Version`. Return a `DependencyResolution` with a static error category (`missing`, `spawn_failed`, `version_check_failed`, or `unsupported_version`) and no command output. `validate_version!(dependency, resolution)` applies another declaration's requirement to an already resolved path/version without spawning a second process.

- [ ] **Step 4: Run focused and full tests**

Run: `bundle exec ruby -Itest test/dependency_checker_test.rb && bundle exec rake test`
Expected: PASS with the existing 51-test suite plus the new tests.

- [ ] **Step 5: Commit**

```bash
git add lib/cybort/dependency.rb lib/cybort/dependency_checker.rb lib/cybort.rb test/dependency_checker_test.rb
git commit -m "feat: add external dependency checking"
```

### Task 3: Extend fetch results and freeze cache planning

**Files:**
- Modify: `lib/cybort/fetch_result.rb`
- Modify: `lib/cybort/adapters/base.rb`
- Modify: `test/fetch_result_test.rb`
- Modify: `test/adapters/base_test.rb`

**Interfaces:**
- Consumes: optional safe metadata and a captured wall-clock planning timestamp.
- Produces: `FetchResult.failure(..., metadata:)`, immutable `AdapterPlan` fetch modes, and `Base#fetch(fetch_mode:, planned_at:)` for the orchestrator.

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

def test_plan_captures_stale_mode_once
  plan = adapter.plan(force_fetch: false, planned_at: now)
  assert_equal :remote, plan.fetch_mode
end

def test_execution_does_not_recheck_ttl_after_boundary
  plan = adapter.plan(force_fetch: false, planned_at: now)
  clock_moves_past_ttl
  result = adapter.fetch(fetch_mode: plan.fetch_mode, planned_at: plan.planned_at)
  assert result.source_fetched
end
```

- [ ] **Step 2: Run focused tests to verify failure**

Run: `bundle exec ruby -Itest test/fetch_result_test.rb && bundle exec ruby -Itest test/adapters/base_test.rb`
Expected: FAIL because `FetchResult.failure` drops metadata and the adapter has no immutable plan/fetch-mode interface.

- [ ] **Step 3: Implement the smallest compatible changes**

Add `metadata: {}` to `FetchResult.failure`. In `Base`, accept optional `command_runner:`, `dependency_resolutions:`, and `monotonic_clock:` keyword arguments, expose readers, and implement:

```ruby
def plan(force_fetch:, planned_at:)
  mode = force_fetch || !fresh_cache_at?(planned_at) ? :remote : :cached
  AdapterPlan.new(instance: instance, context: context.freeze,
                  fetch_mode: mode, planned_at: planned_at,
                  dependency_requirements: [], resolutions: {})
end
```

Make `fetch(fetch_mode:, planned_at:)` branch only on the supplied mode; it must never call the clock or recompute TTL. Use `planned_at` as the one `fetched_at` value for normalized items where the adapter opts in. Pass safe metadata through rescue only when the error is a `CommandError`; generic errors retain empty metadata. Preserve existing adapter constructor calls by giving new arguments defaults, and freeze the plan's mode/context/resolution collection before execution.

- [ ] **Step 4: Run focused and full tests**

Run: `bundle exec ruby -Itest test/fetch_result_test.rb && bundle exec ruby -Itest test/adapters/base_test.rb && bundle exec rake test`
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
- Modify: `lib/cybort/adapters/rss.rb`, `lib/cybort/adapters/github.rb`
- Create or modify: `test/adapter_registry_test.rb`, `test/orchestrator_test.rb`, `test/cli_test.rb`

**Interfaces:**
- Consumes: `DependencyChecker#resolve`/`validate_version!`, adapter validators, and immutable `AdapterPlan` values.
- Produces: registry entries with factories/dependencies, grouped unavailable-dependency guidance, and an orchestrator that preflights exactly once before starting ready threads.

- [ ] **Step 1: Write failing integration tests**

Cover these cases explicitly:

1. Registry validation rejects an unknown adapter and an adapter-level invalid option before any persistence registration or dependency checker call; multiple errors aggregate deterministically by instance ID.
2. A fresh Gmail context with a missing `gws` dependency returns `:cached`, and the checker is not called.
3. A stale Gmail context with missing `gws` returns `:failure` without starting a Gmail thread; a concurrent RSS instance still fetches and persists.
4. `force_fetch: true` makes a fresh Gmail instance require the dependency.
5. Two stale Gmail instances resolve the unique `gws` executable/version once, share the resolution, and produce one grouped guidance entry listing both instances.
6. A fake clock crosses the TTL boundary between planning and thread start, but the frozen `:cached` plan still reads cache and never invokes the checker.

- [ ] **Step 2: Run focused tests to verify failure**

Run: `bundle exec ruby -Itest test/adapter_registry_test.rb && bundle exec ruby -Itest test/orchestrator_test.rb && bundle exec ruby -Itest test/cli_test.rb`
Expected: FAIL because registry entries do not carry dependency metadata and orchestration has no preflight phase.

- [ ] **Step 3: Extend `AdapterRegistry`**

Change `register` to accept `dependencies: []` and store an entry struct containing `factory`, `dependencies`, and mandatory side-effect-free `validate_configuration`. Keep existing class/callable factories working. Add `validate_configuration!(instance)` that calls the hook without HTTP, command, or persistence side effects; collect all errors and raise one `ConfigurationError` whose lines are sorted by instance ID. Add `dependencies_for(instance)` and pass `command_runner:`, `dependency_resolutions:`, `monotonic_clock:`, and `fetch_mode:` through `build`.

Add class-level validators to RSS (`url` must be a nonblank HTTP(S) URI), GitHub (`token` must be nonblank and optional `api_url` must be HTTP(S)), and Gmail (`user_id`/`query` strings and `num_items_to_fetch` in `1..500`). Register RSS and GitHub with empty dependency arrays. Register Gmail in Task 5 with the `gws` declaration.

- [ ] **Step 4: Refactor `Orchestrator#run` into explicit phases**

Use these phases in order: registry/name validation; all side-effect-free source validation; instance context loading; immutable planning with one captured wall-clock `planned_at`; unique dependency resolution; adapter construction; thread execution; and sequential persistence. No `register_instance` call occurs until every configuration validator succeeds. Build a plan with `fetch_mode: :cached` or `:remote` once; execution receives that frozen mode and never rechecks TTL. Deduplicate resolution by executable name (the first declaration performs PATH/version lookup); apply every later declaration's version requirement with `validate_version!`, aggregate purposes/install/auth hints, and fan one failure out to all affected instances. Convert an unsuccessful resolution to a `FetchResult.failure` with static safe metadata and do not create a thread. Build each ready adapter once with its frozen plan and resolved dependency, then start its thread. Merge preflight failures and thread results in configuration order, then reuse sequential `persist_result` handling unchanged.

Do not preflight fresh cache hits. Do not rescue a configuration validation error as a source failure; let it reach the existing CLI status-2 rescue. Rescue only dependency and command-readiness failures as source failures with bounded metadata. Keep `planned_at` distinct from the wall-clock timestamps recorded in `FetchResult`.

- [ ] **Step 5: Inject dependencies from `CLI`**

Construct one `CommandRunner` and one `DependencyChecker` (the latter receives the runner) in `CLI.start`, and pass them to `Orchestrator`; preserve optional test injection by adding keyword arguments with defaults. Add `metadata` to `InstanceRunStatus` and `unavailable_dependencies` to `RunResult`. The CLI JSON shape is:

```json
{"status":"partial_failure","instances":[{"id":"mail_a","status":"failure","source_fetched":false,"item_count":0,"error":"Cybort::SourceError: dependency unavailable","metadata":{"tool":"gws","category":"missing"},"items":[]}],"unavailable_dependencies":[{"tool":"gws","instances":["mail_a","mail_b"],"purpose":"Google-maintained Google Workspace CLI","install_hint":"brew install googleworkspace-cli","auth_hint":"Run gws auth setup, then gws auth login with the documented read-only scope."}]}
```

Group guidance by tool/category/purpose/install/auth hint, sort groups and instance IDs, and emit no raw subprocess output or extra stderr for source failures. Configuration errors continue to emit only the safe message on stderr and status `2`.

- [ ] **Step 6: Run focused and full tests**

Run: `bundle exec ruby -Itest test/adapter_registry_test.rb && bundle exec ruby -Itest test/orchestrator_test.rb && bundle exec ruby -Itest test/cli_test.rb && bundle exec rake test`
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

Use separate fixtures for each outcome: `list_valid.json` contains duplicate valid IDs; `list_blank_id.json` contains a blank ID and must fail; `empty.json` omits or empties `messages` and must succeed; `list_over_limit.json` contains more than the configured limit. `details/valid_one.json` and `valid_two.json` exercise case-insensitive headers, blank subject, missing snippet, labels/thread metadata, valid and invalid `internalDate`; `mismatched_id.json` must fail; and `malformed.json` must fail. Assert canonical identity, title/body/timestamp/info mapping, first-seen de-duplication, and one captured fetched-at timestamp per attempt.

- [ ] **Step 2: Run focused tests to verify failure**

Run: `bundle exec ruby -Itest test/adapters/gmail_test.rb`
Expected: FAIL because the Gmail adapter is absent.

- [ ] **Step 3: Implement configuration validation and command construction**

Accept `user_id` (default `"me"`), `query` (default `""`), and `num_items_to_fetch` in `1..500` from the common instance. Build arguments without a shell:

```ruby
[gws_path, "gmail", "users", "messages", "list", "--params", JSON.generate(params)]
[gws_path, "gmail", "users", "messages", "get", "--params", JSON.generate(
  { "userId" => user_id, "id" => message_id, "format" => "metadata",
    "metadataHeaders" => ["Subject", "From", "Date", "Message-ID"] }
)]
```

Include `maxResults` equal to the effective `num_items_to_fetch` and add `q` only when nonblank. Use the exact resolved path from the dependency checker. The validator rejects values above 500 rather than silently issuing an API-invalid request.

Pass `dependency.environment_keys` as the runner's `allowed_env_keys`; Gmail itself supplies no connector-specific environment values in this slice, but the explicit boundary preserves opt-in proxy/configuration support without inheriting the full parent environment.

- [ ] **Step 4: Implement bounded fetch, parsing, and normalization**

Inject `monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }` into the adapter and use a five-minute deadline captured once per attempt. Pass `min(30, remaining_budget)` to each command; do not spawn when remaining time is zero or negative. Treat an omitted or empty `messages` array as success with zero items. Reject non-object records, blank IDs, mismatched detail IDs, malformed JSON, empty stdout, non-zero status, spawn errors, timeouts, and output truncation. De-duplicate IDs and cap the parsed list to the effective limit before detail calls; never trust `gws` to honor `maxResults`. Fail the entire attempt if any detail fails.

Normalize headers case-insensitively, choose the first nonblank value, use `(no subject)` for a blank/missing subject, retain snippet or `nil`, parse only positive integer millisecond timestamps to UTC, and keep optional labels/thread/sender/Message-ID in `info` (the `Date` header is stored as `info[:date_header]` when nonblank). Every item receives the one captured UTC `fetched_at` for the attempt. Set `urls: []`, `sync_state: {}`, and metadata containing only tool/version/query/limit/command statuses. Raise the typed `CommandError` whose message is static and whose frozen safe metadata excludes all command output.

- [ ] **Step 5: Register Gmail and test failures/deadlines**

Register `gmail` with `Dependency.new(executable: "gws", purpose: "Google-maintained Google Workspace CLI", install_hint: "brew install googleworkspace-cli", auth_hint: "Run gws auth setup, then gws auth login --scopes https://www.googleapis.com/auth/gmail.readonly", version_requirement: ">= 0.22.5, < 0.23.0", environment_keys: %w[XDG_CONFIG_HOME HTTPS_PROXY HTTP_PROXY NO_PROXY SSL_CERT_FILE SSL_CERT_DIR])`. Test list/detail argument JSON, empty results, over-limit responses, safe malformed/non-zero/spawn/timeout failures, aggregate deadline enforcement using an injected monotonic clock, and that no partial items are returned.

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
- Modify: `docs/superpowers/specs/2026-09-04-external-command-connectors-design.md`

**Interfaces:**
- Consumes: all implementation tasks and the approved design/ADR.
- Produces: documented installation/authentication procedure, durable invariants, a status-consistent ADR/design record, and evidence-backed offline/system coverage.

- [ ] **Step 1: Add system tests**

Use a fake command runner and temporary SQLite/configuration to prove Gmail items persist through the normal CLI/orchestrator path. Add one fresh-cache/missing-`gws` case, one stale-cache/missing-`gws` plus healthy RSS case, one `--force-fetch` case, one command-failure case proving existing SQLite items remain intact, and one exact-TTL-boundary case proving the frozen plan does not change between preflight and thread execution. Assert grouped `unavailable_dependencies` JSON for one and multiple affected instances, deterministic ordering, safe metadata in `fetch_runs.metadata_json`, and absence of raw fake stderr/stdout.

- [ ] **Step 2: Update user-facing setup**

In `README.md`, document:

```bash
brew install googleworkspace-cli
gws auth setup
gws auth login --scopes https://www.googleapis.com/auth/gmail.readonly
gws auth status
```

Explain that `gws` is Google-maintained and lives in the Google Workspace GitHub organization, but its README says it is not an officially supported Google product and is pre-1.0. Explain that `gcloud` is needed only for automated `gws auth setup`; manual Cloud Console setup is an alternative. Document that Cybort scans required tools before stale/forced fetches, gives Homebrew guidance, and never performs interactive login. State that this connector is experimental until the manual contract gate succeeds.

- [ ] **Step 3: Update durable memory and ADR index**

Add the implemented dependency-preflight invariant and macOS/POSIX support boundary to `AGENTS.md`. Add a dated `docs/LEARNINGS.md` entry with actual evidence: tests plus the manual smoke-test result, exact version, scope set, and sanitized list/detail shape. If the authenticated smoke test succeeds, change ADR 0002 status to `Accepted`, change the design spec status to `Implemented`, add implementation links, and update `docs/adr/README.md`. If `gws` is unavailable or the gate cannot be run, leave ADR 0002 `Proposed` and the design spec `Proposed for implementation planning`; record the compatibility learning as `Open` with the blocker rather than claiming support. Do not alter the historical spitballing document.

- [ ] **Step 4: Run complete verification**

Run:

```bash
bundle exec rake test
git diff --check
git diff --exit-code -- docs/initial-spitballing.md
```

Run `! rg -n 'T(BD|ODO)|F[I]X.ME' docs/superpowers/plans/2026-09-04-external-command-connectors.md docs/superpowers/specs/2026-09-04-external-command-connectors-design.md` (or an equivalent exact marker scan that does not report the command itself). Expected: all tests pass, no whitespace errors, historical document unchanged, and no unresolved placeholders.

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
