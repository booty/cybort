# Adversarial Review: External Command Connectors Implementation Plan

**Review date:** 2026-09-04

**Repository SHA reviewed:** `0488120639514501cd6411140bcb67162778848a`

**Branch:** `main`

**Working-tree state at start:** clean

**Primary artifact:** `docs/superpowers/plans/2026-09-04-external-command-connectors.md`

**Verdict:** Request changes. The plan is directionally strong but is not safe
to execute as written.

## Scope and method

The review traced every plan task and introduced interface against:

- the revised external-command design and proposed ADR 0002;
- accepted ADR 0001 and the core design;
- `AGENTS.md`, `README.md`, and `docs/LEARNINGS.md`;
- all current implementation files under `lib/cybort/`; and
- all current tests under `test/`.

The process assumptions were also checked against current Ruby `Open3` and
`Process` documentation. Gmail limits and response behavior were checked
against the current official Gmail API documentation. The upstream executable
was confirmed to mean
[`googleworkspace/cli`](https://github.com/googleworkspace/cli), whose README
describes it as Google Workspace CLI while explicitly disclaiming official
Google product support and warning of pre-1.0 breaking changes.

Fresh baseline verification at the reviewed SHA:

```text
bundle exec rake test
51 runs, 176 assertions, 0 failures, 0 errors, 0 skips
```

## Severity convention

- **Critical:** the plan can hang, violate a core runtime guarantee, or accept
  an unverified security/external contract.
- **Important:** a material interface contradiction, missing implementation
  step, or test gap likely to produce incorrect behavior.
- **Minor:** an ambiguity or maintenance issue that should be corrected before
  handoff but does not independently invalidate the architecture.

## Critical findings

### C1. Cache readiness is evaluated twice, so preflight and execution can disagree

**Evidence:** Task 3 adds `Base#needs_remote_fetch?`, implemented by calling the
time-sensitive `fresh_cache?`, and also makes `Base#fetch` use that method
(`plan:224-234`). Task 4 then builds an adapter synchronously, calls
`needs_remote_fetch?`, skips dependencies for a fresh plan, and later starts an
adapter thread which calls `fetch` (`plan:282-286`). The current
`fresh_cache?` obtains a new clock value on every invocation
(`lib/cybort/adapters/base.rb:47-50`).

An instance can be fresh during planning, skip `gws` resolution, cross the TTL
boundary before its thread executes, and then choose a remote fetch without a
resolved dependency. This breaks the plan's central guarantee that fresh cache
works without `gws` while every remote fetch has passed preflight. Task 4 is
also ambiguous about object identity: it says to build an adapter before
resolution and then pass resolutions “into the adapter” when creating threads,
which implies either mutating the planned adapter or building a second adapter.

**Concrete correction:** Introduce an immutable per-instance `AdapterPlan`
with an explicit `fetch_mode` (`:cached` or `:remote`), context, and one captured
run timestamp. Perform validation before planning, resolve dependencies for
`:remote` plans, then build the execution adapter once with its resolutions.
Execution must consume the frozen plan decision rather than recalculate
freshness. Alternatively, produce cached `FetchResult`s synchronously and give
remote-only adapters a method that cannot fall back to the cache branch. Add a
test whose fake clock crosses the exact TTL boundary between planning and
thread start.

### C2. The proposed runner can still deadlock despite its timeout

**Evidence:** Task 1 opens stdin/stdout/stderr with `Open3.popen3`, monitors only
the leader's wait thread, and closes all pipes in `ensure`
(`plan:125-133`). It never says to close child stdin immediately. A command that
reads until EOF will wait forever until the runner's timeout even though Cybort
never intends to provide input. A local Ruby probe confirmed that such a child
remains alive until stdin is explicitly closed.

There is a second hang path: the leader can exit after spawning a descendant
that inherits stdout/stderr. `wait_thr.join` then succeeds, but the reader
threads still wait for EOF. Because the plan joins readers only after leader
completion and applies no deadline to pipe draining, the runner can block
forever outside the advertised timeout. Ruby's
[`Open3` documentation](https://docs.ruby-lang.org/en/master/Open3.html) also
requires stdout and stderr to be drained concurrently to avoid filled-pipe
deadlocks; the proposed 200-byte truncation test is too small to prove this.

**Concrete correction:** Close stdin immediately after spawn. Apply one
monotonic deadline to the entire process-and-pipe lifecycle, not only to the
leader. Continue draining both streams after retention caps are reached. If the
leader exits but pipes remain open past a short drain grace period, terminate
the process group, close the read ends, join the readers, and handle
`Errno::ESRCH`/closed-stream races. Add tests for:

- a child that exits only on stdin EOF;
- a leader that exits while a descendant retains both output descriptors;
- a TERM-ignoring process requiring KILL;
- simultaneous stdout and stderr larger than OS pipe capacity; and
- reader/spawn exceptions without leaked processes or threads.

### C3. The plan accepts a “tested” `gws` range without requiring the initial contract test to pass

**Evidence:** The global constraint declares `>= 0.22.5, < 0.23.0` supported
and the design calls this a tested range (`plan:15`; design spec lines
143-147). Task 6 marks ADR 0002 Accepted and pushes implementation, but asks a
learning entry to cite only the smoke-test *command*, not a successful result
(`plan:394-416`). The manual smoke test is described only as a prerequisite for
a later range *update* (`plan:418-428`). No successful `gws` contract run is
recorded in `docs/LEARNINGS.md`; the review environment does not have `gws`
installed.

The listed smoke test executes only `messages list`. It never executes the
planned `messages get` request with `format=metadata` and repeated
`metadataHeaders`, so it cannot validate the most version-sensitive response
and argument contract or produce the detail fixtures Task 5 relies on. Nor does
it state how scope verification succeeds or fails.

**Concrete correction:** Make a successful manual contract test a gate before
Task 5 fixtures are finalized and before Task 6 marks the ADR Accepted. Require
and record the exact version, `auth status` scope set, list command, detail
command with the exact planned parameters, exit statuses, and sanitized JSON
shape comparison. Capture fixtures from that run after removing personal data.
If an authenticated test account is unavailable, implementation may proceed
experimentally, but the ADR must remain Proposed and the connector must not be
documented as supported. Repeat the gate for every version-range change.

## Important findings

### I1. Source-specific validation is ordered after persistence and is not actually assigned for all adapters

**Evidence:** The design requires adapter-name and source configuration
validation before instances are registered or contexts loaded (design spec
lines 114-126). Task 4 instead says to keep `register_instance` and context
loading before building an adapter and calling validation (`plan:282-286`). A
bad option can therefore mutate `adapter_instances` before the run exits 2.

The registry hook is optional, and the plan only says to register RSS/GitHub
with empty dependency arrays (`plan:276-280`). It does not add validation hooks
for RSS or GitHub, nor does its file map allow changes to their adapter files.
Currently GitHub validates its token in its constructor
(`lib/cybort/adapters/github.rb:9-12`), while RSS does not access its required
URL until `fetch_from_source` (`lib/cybort/adapters/rss.rb:10-13`). The design
also says the registry aggregates configuration errors, but the plan defines no
aggregate type, message, or multiple-error test.

**Concrete correction:** Add a first orchestration phase that validates all
registry names and all source options before any `register_instance` call.
Define required side-effect-free validators for RSS (`url`), GitHub (`token`
and optional URL), and Gmail (`user_id`, `query`, limits), either as adapter
class methods or mandatory registry callables. Add the RSS/GitHub files and
tests to the task map if needed. Specify and test deterministic aggregation of
multiple invalid instances and prove persistence received no calls.

### I2. Dependency resolution is per instance in the plan but de-duplicated across plans in the design

**Evidence:** The design requires aggregate/de-duplicated dependency
requirements (design spec lines 404-414). Task 4 explicitly tests and performs
one checker call per remote-fetch instance (`plan:263-269, 282-284`). Two stale
Gmail instances therefore run `gws --version` twice, serially, and future
multi-dependency adapters can repeat the same work and guidance. At the
30-second runner limit, duplicated readiness checks can materially delay all
threads.

**Concrete correction:** Resolve each unique executable once per run, cache the
path and parsed version, evaluate every declaration's requirement against that
version, then fan the resolution/failure out to affected instances. Define the
deduplication key and behavior when declarations for one executable have
different requirements or hints. Test two stale Gmail instances, duplicate
declarations, and multiple missing tools with stable grouped output.

### I3. Safe command failure metadata has no complete type or propagation path

**Evidence:** The design requires a `CommandError` with bounded metadata
(design spec lines 193-196), but the plan says “a `SourceError` or dedicated
`CommandError`” and lists no file/interface for the error
(`plan:341-349`). `SourceError` currently has no metadata API
(`lib/cybort.rb:4-6`). Task 3 says Base should “pass safe metadata through
rescue” without defining how it distinguishes trusted structured metadata from
an arbitrary exception (`plan:224-234`).

The final hop is also incomplete. `InstanceRunStatus` has no metadata field and
`persist_result` does not copy `FetchResult#metadata`
(`lib/cybort/orchestrator.rb:2-20, 80-98`). Task 4 vaguely asks
`InstanceRunStatus#to_h` to emit metadata but gives no constructor/interface
change (`plan:288-290`). Dependency failures bypass Base entirely, adding a
second propagation path.

**Concrete correction:** Define one `CommandError < SourceError` interface
with a frozen, allow-listed scalar metadata hash; add it to the module map and
requires. Base should copy metadata only from that trusted type. Add metadata to
`InstanceRunStatus` and pass it in every success/failure/persistence-rescue
constructor. Specify the CLI JSON shape. Test the same sentinel through adapter,
`FetchResult`, SQLite `fetch_runs.metadata_json`, `RunResult`, CLI stdout, and
stderr, proving raw output and control characters never appear.

### I4. The happy-path and failure fixtures are mutually contradictory

**Evidence:** Task 5 requires the one list fixture to contain duplicate IDs, a
blank invalid entry, and a valid ID, while also asserting normalization and
first-seen de-duplication (`plan:318-320`). Step 4 correctly says any blank ID
fails the entire attempt (`plan:341-345`; design spec lines 264-268, 294-297).
Thus that fixture cannot drive a successful de-duplication test. Likewise, the
only two detail fixtures must include valid/invalid timestamps and a mismatched
ID; a mismatch correctly makes the whole fetch fail, so those same fixtures
cannot establish the normal two-item path.

**Concrete correction:** Split fixtures by behavior: valid list with
duplicates, blank-ID list, empty/omitted list, valid detail variants,
mismatched-ID detail, malformed JSON, and optionally non-object roots/records.
Name the exact fixture files in the map and pair each with one expected outcome.

### I5. Aggregate-deadline tests are not executable deterministically

**Evidence:** Task 5 requires a five-minute monotonic deadline and an aggregate
deadline test (`plan:341-349`), but none of the introduced interfaces accepts a
monotonic clock. `clock` in current adapters returns wall-clock `Time` and is
used for item/fetch timestamps (`lib/cybort/adapters/base.rb:4-10`); it is not a
monotonic numeric clock. A fake runner that returns immediately will not consume
the five-minute budget, while a real-time test would be unacceptably slow and
flaky.

**Concrete correction:** Inject `monotonic_clock: -> {
Process.clock_gettime(Process::CLOCK_MONOTONIC) }` into both runner and Gmail
deadline owner, or inject a deadline/budget object. Add exact tests showing
`min(30, remaining_budget)` on each call, zero/negative remaining budget without
spawn, and list/detail cumulative exhaustion. Keep the wall clock separate.

### I6. The Gmail request limit is neither API-valid nor defensively enforced

**Evidence:** Common configuration accepts any positive integer
(`lib/cybort/configuration.rb:51-58`). Task 5 passes it directly as
`maxResults` and trusts the returned list after de-duplication
(`plan:327-345`). Official Gmail API documentation caps `messages.list`
`maxResults` at 500: [List Gmail
messages](https://developers.google.com/workspace/gmail/api/guides/list-messages).
A configured value above 500 becomes a remote failure rather than an actionable
configuration error. A malformed or changed CLI can also return more records
than requested, causing more detail subprocesses than `num_items_to_fetch` and
violating the project invariant that it limits one source fetch.

**Concrete correction:** Choose and document either Gmail-specific validation
of `1..500` or explicit clamping to 500. Independently cap the parsed response
to the configured/effective limit before detail calls; never trust the external
tool to honor the request. Test 500, 501, and an over-returning fake response.

### I7. Runner spawn failures and several result fields have no defined semantics

**Evidence:** `Open3.popen3` raises `Errno::ENOENT` when an executable
disappears between preflight and spawn. The runner contract says it does not
raise for nonzero exit, timeout, or truncation, but does not say what happens on
spawn/permission failures (`plan:64-79, 125-129`). `CommandResult` includes
`executable` and `version`, although the runner receives the executable in
`argv[0]` and does not discover a version. No task says how those fields are
populated or typed. The dependency checker also does not explicitly reject a
timed-out/truncated/nonzero version result before parsing.

**Concrete correction:** Remove redundant/unowned fields or define each field's
type and source. Add an explicit `spawn_error` result category (without raw OS
paths/messages) or a dedicated safe exception and make both checker and Gmail
handle it. Validate positive finite timeout and nonnegative integer output cap.
Tests must cover disappeared, non-executable, and invalid-format executables,
plus timeout/truncation/nonzero outcomes from `--version`.

### I8. Version parsing accepts the wrong release classes

**Evidence:** Task 2 parses the first `X.Y.Z` token and checks a
`Gem::Requirement` (`plan:157-168`). This can select an unrelated semantic
version appearing earlier in output, discard prerelease suffixes, and accept a
`0.23.0-rc` build under `< 0.23.0` even though the stated support line is stable
0.22.x. The test matrix covers only 0.22.5, 0.23.0, and malformed output.

**Concrete correction:** Pin and parse the documented `gws --version` output
format, anchor the match to the tool name, preserve prerelease/build syntax,
and explicitly reject prereleases unless separately tested. Add lower-bound,
upper-bound, prerelease, multiple-version-token, stderr-only, whitespace, and
truncated-output cases.

### I9. The focused multi-file test commands execute only the first file

**Evidence:** Tasks 3 and 4 invoke Ruby as:

```text
bundle exec ruby -Itest test/fetch_result_test.rb test/adapters/base_test.rb
bundle exec ruby -Itest test/adapter_registry_test.rb test/orchestrator_test.rb test/cli_test.rb
```

(`plan:219-238, 271-294`). Ruby treats only the first path as the program; the
remaining paths are `ARGV`. Running the equivalent commands at the reviewed SHA
executed only 2 `FetchResultTest` cases and only 3 `OrchestratorTest` cases,
respectively. The later full suite limits the damage on green runs, but the
claimed focused red/green evidence is false.

**Concrete correction:** Run each file as a separate command joined with
`&&`, or use one Ruby loader that explicitly requires every path. Include the
observed expected test counts so accidental omission is visible.

### I10. CLI dependency guidance is described but no output schema or aggregation task exists

**Evidence:** The design promises grouped affected tools/instances and
actionable install/auth guidance (design spec lines 306-324). Task 4 converts
each failed resolution to one `FetchResult.failure`; Task 6 merely says the
README should describe guidance (`plan:282-290, 381-392`). Current source
failures appear only inside each instance's JSON `error` field and are not
written to stderr (`lib/cybort/cli.rb:28-38`). The plan never says where the
grouped block lives, how duplicate guidance is suppressed, or what exact JSON a
client receives.

**Concrete correction:** Define the run-result/CLI contract. Either add a
top-level structured `unavailable_dependencies` array with instances, tool,
category, purpose, install hint, and safe auth hint, or explicitly choose
per-instance metadata and revise the design's grouped example. Add exact JSON,
stderr, and exit-status assertions for one and multiple affected instances and
for mixed healthy/failing runs.

### I11. The environment policy is internally inconsistent and the platform contract is unstated

**Evidence:** The global rule allows “connector-provided environment
variables,” but Task 1 rejects all explicit keys except `HOME`, `PATH`,
`TMPDIR`, and `CYBORT_*` (`plan:20-21, 125-130`). A future external connector
cannot pass its vendor-defined credential/config variable without changing the
generic runner. Stripping the environment also removes common proxy,
certificate, and `XDG_CONFIG_HOME` settings that may be required for `gws` to
reach Google or find the already-authenticated context.

The implementation assumes POSIX executable bits, empty-PATH semantics,
negative process-group signaling, and `pgroup: true`, but neither README nor the
plan states that Windows is unsupported. The tech stack simply says Ruby 3.x.

**Concrete correction:** Make the runner accept an explicit per-call allowed
environment-key set owned by the registered connector, while retaining
`unsetenv_others: true`; document which proxy/certificate/config variables are
supported. State and test the OS support matrix. If this slice is macOS/POSIX
only, say so. If Windows is supported, design separate executable lookup and
process-tree termination semantics before implementation.

### I12. Documentation acceptance steps leave the design record inconsistent

**Evidence:** Task 6 changes ADR 0002 and its index to Accepted but does not
modify the design spec, whose status is “Proposed for implementation planning.”
The design is absent from Task 6's file list (`plan:363-396`). The same step
asks `LEARNINGS.md` to cite tests and a manual smoke-test command, even though
project rules require evidence and forbid recording speculation as settled
fact (`AGENTS.md:69-92`). A command that was not successfully run is not
evidence of external compatibility.

**Concrete correction:** Add the design spec to Task 6 and set a coherent final
status (for example, Implemented) only after implementation, smoke test, and
review. Record actual smoke-test result/date/version or leave the compatibility
learning Open and ADR Proposed. Verify all new document links, including README
links to the connector design, ADR, implementation plan, and review.

## Minor findings

### M1. The declared Ruby version conflicts with the repository requirement

The plan says Ruby 3.x (`plan:9`), while `README.md` requires Ruby 4.0.1 and the
reviewed runtime is 4.0.1. Process behavior is exactly where version/OS
differences matter.

**Concrete correction:** State Ruby 4.0.1 and test against that version, or
explicitly broaden the repository's supported matrix with CI evidence.

### M2. `fetched_at` is required but omitted from the Gmail normalization instructions

`Item` requires a nonblank `fetched_at` (`lib/cybort/item.rb:10-20`), while Task
5 enumerates title/body/timestamp/info, URLs, state, and metadata without saying
how `fetched_at` is assigned (`plan:341-345`). The requested Gmail `Date` header
is also normalized but has no destination; `remote_created_at` uses
`internalDate`.

**Concrete correction:** State that every item receives the adapter's captured
fetch time (preferably one consistent UTC `Time` per attempt), and either remove
`Date` from `metadataHeaders` or name its `info` key and behavior.

### M3. The shell-injection test uses a shared fixed filesystem path and never checks it

The sample argument includes `touch /tmp/nope`, but the assertion only checks
`ARGV` and never proves `/tmp/nope` was not created (`plan:100-117`). A
pre-existing file also makes the path unsuitable as evidence.

**Concrete correction:** Use a unique path inside `Dir.mktmpdir`, assert it does
not exist before and after, and retain the exact-argv assertion.

### M4. The final verification scan is not reproducible

Task 6 says to scan for unresolved placeholder markers without providing the
patterns or command (`plan:398-408`). Words such as “optional,” “later,” and
“exact” occur intentionally, so different workers can reach different results.

**Concrete correction:** List the exact prohibited markers and the `rg` command,
or remove this weak gate and replace it with a requirement-by-requirement
checklist against the design.

## Requirement-to-task coverage summary

The plan has concrete tasks for the basic runner, dependency lookup/version
gate, Gmail list/detail parsing, per-instance continuation, offline adapters,
persistence integration, and documentation. The following design requirements
are not yet represented by an executable task/test:

- one immutable cache-versus-remote decision from planning through execution;
- whole-process-tree and pipe-lifecycle timeout enforcement;
- successful initial manual verification of both `gws` commands and scopes;
- validation of every built-in adapter before persistence side effects;
- cross-instance dependency de-duplication and grouped guidance;
- one typed safe-error metadata path through SQLite and CLI presentation;
- deterministic aggregate-deadline testing;
- Gmail's API maximum and defensive response cap; and
- a declared platform/environment compatibility policy.

## Overall verdict

The revised plan correctly adopts per-instance preflight, explicit Gmail
read-only scopes, absolute executable paths, bounded output, version gating,
safe diagnostics, and offline fixtures. Those are meaningful improvements over
the original design. However, the cache decision race and runner lifecycle gaps
can violate the two most important runtime guarantees, and the initial external
contract is still accepted without evidence. Several promised design behaviors
also lack a complete interface or task.

Keep ADR 0002 **Proposed** and do not execute the implementation plan until
C1-C3 are corrected. Revise Tasks 1-6 to close I1-I12, then re-review the plan
before implementation.
