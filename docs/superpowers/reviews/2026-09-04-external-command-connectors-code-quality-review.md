# Adversarial Code-Quality Review: External Command Connectors

**Review date:** 2026-09-04

**Baseline SHA:** `d78dff9`

**Implementation SHA reviewed:** `a6512fd6c9d70e7cc5ea11b79c3f5d881882ca7c`

**Branch:** `main`

**Working-tree state at start:** clean

**Verdict:** Request changes; do not treat the Gmail connector or generic
command-runner boundary as releasable at this SHA.

## Scope and method

This review inspected the complete `d78dff9..a6512fd` change set: all changed
production code and tests, `AGENTS.md`, `README.md`, `docs/LEARNINGS.md`, ADR
0002 and its index, and the revised design and implementation plan. The review
also traced the new APIs into the pre-existing configuration, item, persistence,
CLI, and adapter contracts.

The implementation comprises six commits:

```text
b7c7d9f feat: add bounded command runner
d9f478c feat: add external dependency checking
0408e04 feat: freeze adapter cache planning
5c3364a feat: preflight connector dependencies per instance
3fe62c7 feat: add read-only Gmail gws adapter
a6512fd feat: integrate Gmail connector workflow
```

Fresh verification at the reviewed SHA passed:

```text
bundle exec rake test
96 runs, 346 assertions, 0 failures, 0 errors, 0 skips

git diff --check d78dff9..a6512fd
passed (no output)

git diff --exit-code d78dff9..a6512fd -- docs/initial-spitballing.md
passed (no output)
```

Two focused production-runner probes were also performed. Their results are
included under C2 and I2. Any child created by the lifecycle probe was killed
explicitly after the liveness check.

The documentation now characterizes
[`googleworkspace/cli`](https://github.com/googleworkspace/cli) accurately: it
is Google-maintained and hosted in the Google Workspace GitHub organization,
but its own README disclaims official Google product support and warns that it
is pre-1.0. Keeping ADR 0002 and the design Proposed, and Gmail experimental,
until an authenticated contract smoke test is therefore appropriate. The
findings below do not rely on calling the project “officially supported.”

## Severity convention

- **Critical:** breaks the primary connector in normal use, or violates the
  process containment guarantee in a way that can leave work running after a
  reported timeout.
- **Important:** a material correctness, security-boundary, compatibility, or
  required-test gap that should be fixed before accepting the implementation.
- **Minor:** a bounded diagnostic, immutability, or documentation defect that
  does not independently block the current happy path.

## Critical findings

### C1. Every Gmail API command drops the required `gmail` service token

**Evidence:** The adapter builds the intended relative vectors beginning with
`"gmail"` for list and get (`lib/cybort/adapters/gmail.rb:31-35, 44-48`).
`run_gws`, however, calls the runner with
`[gws_path(dependency), *argv.drop(1)]` (`gmail.rb:102-112`). The actual list
command is consequently:

```text
/resolved/path/gws users messages list --params ...
```

rather than:

```text
/resolved/path/gws gmail users messages list --params ...
```

The same defect affects every detail request. This directly contradicts the
design's list/get flow (`external-command-connectors-design.md:250-256`) and
the exact vectors in the plan (`external-command-connectors.md:365-375`). A
real authenticated `gws` invocation cannot reach the Gmail service through
these arguments.

The tests conceal the error. `StubCommandRunner` and `FakeGwsRunner` decide
whether a request is list or get by searching for those later tokens
(`test/adapters/gmail_test.rb:15-25` and
`test/system/cli_system_test.rb:65-80`). The argument test asserts the path and
JSON parameters but never asserts the complete command vector
(`test/adapters/gmail_test.rb:55-81`). Thus all 96 tests pass while the new
connector's only real command path is invalid.

**Concrete fix:** Change the runner call to
`[gws_path(dependency), *argv]` (or have callers construct the complete vector
once). Add exact-array assertions for both list and detail commands, including
the `gmail` token and token ordering. Prefer an additional local fake-executable
system test that records `ARGV`; unlike the current semantic fake, it exercises
the real `CommandRunner` boundary without contacting Google. Do not advance the
experimental/Proposed status until the documented authenticated smoke test also
passes with the corrected vector.

### C2. A timed-out command can leave a TERM-ignoring descendant running

**Evidence:** When the command leader exits but a descendant retains an output
pipe, the runner reaches its drain timeout and calls
`terminate_process_group` (`lib/cybort/command_runner.rb:59-67`). That method
sends `TERM`, but sends `KILL` only when the leader's `wait_thread` is still
alive (`command_runner.rb:149-167`). Once the leader has exited, the condition
is false even if descendants in the process group remain alive. Closing the
parent pipe descriptors does not terminate those descendants.

A focused probe used a leader that forked a descendant, installed a no-op TERM
handler in the descendant, detached it, and exited. The runner returned quickly
and reported timeout, but the descendant was still live:

```text
{timed_out: true, elapsed: 0.102, descendant_pid: 42335,
 descendant_alive: true}
```

The probe then explicitly sent `KILL` to that controlled child. This violates
the design's explicit guarantee that timeout cleanup sends KILL if necessary
and “will never leave a child process or pipe behind”
(`external-command-connectors-design.md:172-179`). For a connector, the leaked
process can continue network or credential activity after Cybort has recorded
a failure.

The existing descendant test uses a default signal handler and checks only
`result.timed_out` (`test/command_runner_test.rb:61-69`); it never establishes
that the descendant died, so TERM is sufficient and the faulty KILL branch is
not exercised.

**Concrete fix:** Track the process-group ID independently of leader liveness.
On a process or drain deadline, send TERM to the group, allow the bounded grace
period, then send KILL to the group regardless of whether the leader wait
thread has already completed; treat `ESRCH` as the “group is gone” result.
Separately reap the leader and bound all joins. Add an IPC-backed regression
test with a TERM-ignoring descendant that records its PID, assert that the group
is gone when `run` returns, and clean it up defensively if the assertion fails.

## Important findings

### I1. Declared connector environment keys are allow-listed but never supplied

**Evidence:** `CommandRunner#child_environment` inherits only `HOME`, `PATH`,
and `TMPDIR`; extra names are present only if the caller supplies values via
the `env:` hash (`lib/cybort/command_runner.rb:119-132`). Gmail passes
`allowed_env_keys:` but no `env:` (`lib/cybort/adapters/gmail.rb:107-112`). The
dependency version check does the same
(`lib/cybort/dependency_checker.rb:11-17`). Therefore all registry declarations
for `XDG_CONFIG_HOME`, proxy settings, and SSL certificate settings are inert
(`lib/cybort/adapter_registry.rb:13-20`).

A production-runner probe set `ENV["XDG_CONFIG_HOME"]`, allowed that key, and
asked the child to print it. The result was:

```text
"missing"
```

This contradicts the plan's claim that the explicit boundary preserves
proxy/configuration opt-in (`external-command-connectors.md:377-380`) and can
make authenticated or proxied environments fail despite a valid declaration.

**Concrete fix:** Define one explicit source of connector environment values.
For example, capture a process-environment snapshot in the orchestrator and
pass only `dependency.environment_keys` selected from it as `env:` to both
version and adapter commands. Alternatively inject a connector-specific env
hash directly. Tests must prove that a declared value reaches the child and an
undeclared value does not. Reconcile `XDG_CONFIG_HOME` with the design's
default-credential-context boundary before enabling it.

### I2. The output cap falsely reports exact-size output as truncated

**Evidence:** `read_stream` appends a chunk, then recomputes the remaining
capacity from the already-updated output before deciding whether the chunk
overflowed (`lib/cybort/command_runner.rb:134-146`). Any nonempty final chunk
that brings output exactly to the cap is marked truncated. A production-runner
probe that wrote exactly 32 bytes with a 32-byte cap returned:

```text
[32, true, true]
```

The third value is the successful process status. Gmail treats either stream's
truncation flag as a command failure (`lib/cybort/adapters/gmail.rb:180-185`),
so a valid JSON response exactly at the configured boundary is rejected.
Current tests cover 200 bytes against a 32-byte cap, not exact-fit output
(`test/command_runner_test.rb:28-36`).

**Concrete fix:** Compute `remaining` before appending and set truncation only
when `chunk.bytesize > remaining`, or track total bytes observed separately.
Add stdout and stderr tests for cap-minus-one, exact cap, and cap-plus-one,
including `max_output_bytes: 0`.

### I3. Executable de-duplication caches a dependency verdict, not executable discovery/version

**Evidence:** The orchestrator caches the first `DependencyResolution` by
executable name and sends that object to `validate_version!` for later
declarations (`lib/cybort/orchestrator.rb:88-105`). A resolution already marked
unavailable is returned unchanged because `validate_version!` evaluates only
an available resolution (`lib/cybort/dependency_checker.rb:28-35`). This creates
several incorrect generic behaviors:

- if the first declaration's range rejects the installed version, a later
  compatible declaration is also failed and inherits the first dependency's
  guidance;
- if the first declaration has no version requirement, its cached version is
  `nil`, so a later declaration that does require a version becomes
  `version_check_failed` without ever obtaining the version; and
- an adapter with several dependencies stops after its first failure
  (`lib/cybort/orchestrator.rb:97-109`), so Cybort does not detect “every missing
  executable” or report all affected tools as the design promises.

The implementation happens to register only one dependency declaration today,
but this is the foundational generic connector API. It contradicts both the
plan's requirement to resolve a unique executable/version once and apply every
declaration's requirement (`external-command-connectors.md:314-318`) and the
new durable invariant (`AGENTS.md:34-38`). The only shared-resolution test uses
the same dependency and a fake checker that returns the first result unchanged
(`test/orchestrator_test.rb:105-121, 241-259`).

**Concrete fix:** Cache neutral executable discovery and parsed version facts,
not a declaration-specific availability verdict. Evaluate every declaration's
requirement and guidance against those facts. Resolve all dependencies for all
remote plans before fanning failures out. Add tests for compatible and
incompatible ranges on the same executable in both declaration orders, a
versionless declaration followed by a versioned one, and one adapter with two
missing tools.

### I4. Registry construction breaks previously valid callable factories

**Evidence:** Before this change, registry factories received the four
keywords `instance`, `context`, `http_client`, and `clock`. The new implementation
unconditionally adds `command_runner` and `dependency_resolutions`, and may add
`monotonic_clock` (`lib/cybort/adapter_registry.rb:74-91`). A callable using the
previous exact keyword interface now raises. A focused compatibility probe
returned:

```text
ArgumentError: unknown keywords: :command_runner, :dependency_resolutions
```

This violates the plan's explicit “Keep existing class/callable factories
working” requirement (`external-command-connectors.md:308-312`). New tests all
define factories with `**kwargs` or `**_kwargs`, so they cannot detect the
regression (`test/adapter_registry_test.rb:10-14, 26-28` and
`test/orchestrator_test.rb:147-168`).

**Concrete fix:** Establish and document a versioned construction protocol.
For backward compatibility, pass only keywords a callable declares (while
always passing the required legacy four), or wrap legacy factories separately
from the new adapter interface. Add class and callable tests using exact legacy
keyword signatures, plus exact new signatures.

### I5. Configuration errors are not fully aggregated or deterministic

**Evidence:** `AdapterRegistry#validate!` raises immediately for the first
unknown adapter in configuration insertion order
(`lib/cybort/adapter_registry.rb:41-47`). Only after that pass does
`validate_configuration!` sort IDs and aggregate registered-adapter validator
errors (`adapter_registry.rb:49-66`; `lib/cybort/orchestrator.rb:56-60`). A
configuration containing unknown adapters and invalid known adapters therefore
reports only the first unknown adapter, and its selection depends on TOML/hash
order.

This contradicts the design statement that the registry aggregates
configuration errors (`external-command-connectors-design.md:365-370`) and the
plan's required deterministic multi-error case
(`external-command-connectors.md:292-301`). Existing aggregation tests contain
only registered instances (`test/adapter_registry_test.rb:24-37`).

**Concrete fix:** Perform one sorted validation pass that adds an unknown-
adapter message or calls the registered validator for every instance, then
raise one `ConfigurationError`. Add mixed known-invalid/multiple-unknown tests
in deliberately reversed insertion order and assert no persistence or checker
calls.

### I6. Installed-but-unauthenticated `gws` failures omit the promised setup guidance

**Evidence:** The design says an installed but unauthenticated command should
produce a safe source failure “with ... setup guidance” and later says the user
can run setup/status commands directly
(`external-command-connectors-design.md:145-152, 320-324`). In the
implementation, a nonzero Gmail command produces only tool, operation, command
index, category, exit code, and version metadata
(`lib/cybort/adapters/gmail.rb:180-203`). Top-level
`unavailable_dependencies` is populated only by preflight failures
(`lib/cybort/orchestrator.rb:113-120, 184-192`). Consequently the likely first
runtime failure after installation says only that a `gws` command failed; it
does not offer `gws auth setup`, scoped login, or `gws auth status` guidance.

**Concrete fix:** Without inspecting or persisting raw stderr, attach static
connector remediation to Gmail command failures (or a separate bounded
guidance field) so any authentication/authorization-like nonzero result points
to the documented read-only setup/status procedure. Do not claim to distinguish
authentication solely from exit code unless upstream documents a stable code.
Add CLI/system assertions for the static hint and continued absence of raw
output.

### I7. Required integration coverage is incomplete, allowing the critical command defect through

**Evidence:** Task 6 explicitly required system cases for force-fetching a fresh
cache, the exact TTL boundary between planning/preflight/thread execution,
multiple grouped instances with deterministic order, persisted safe
`fetch_runs.metadata_json`, and no raw output
(`external-command-connectors.md:418-420`). The implemented system suite adds
only fresh-cache/missing-tool, Gmail-plus-RSS dependency isolation, and
last-known-good data after command failure
(`test/system/cli_system_test.rb:196-280`). The second case uses
`--force-fetch` only after advancing the clock by 3,601 seconds, so it does not
prove that force overrides a genuinely fresh cache. Multiple-instance grouping,
the orchestration boundary race, and persisted metadata are not asserted.

The Gmail “aggregate deadline” test performs only the list request and succeeds;
it never advances through multiple detail requests to exhaustion
(`test/adapters/gmail_test.rb:180-188`). The command tests assert a timeout flag
but not the no-process/no-thread/no-pipe postcondition. Most importantly, no
test asserts the full Gmail command vector, enabling C1.

**Concrete fix:** Implement every enumerated Task 6 case and strengthen tests
around observable boundaries rather than fake-internal behavior. Add full argv,
exact-cap, descendant-liveness, mixed-version preflight, environment-forwarding,
fresh-force-fetch, multi-command budget exhaustion, deterministic grouping,
and persisted-metadata assertions. Keep production tests offline; a local fake
executable is sufficient for process integration.

### I8. Adapters are instantiated before dependency preflight, contrary to the planned phase boundary

**Evidence:** The orchestrator constructs every adapter while creating plans
(`lib/cybort/orchestrator.rb:62-86`), then resolves dependencies
(`orchestrator.rb:88-120`). Thus even an instance that should become an
immediate missing-dependency failure has already run its adapter constructor.
An external factory with constructor validation, allocation, or side effects
can raise or mutate state before preflight and turn an isolated dependency
failure into a run-wide exception. The implementation plan specifies unique
dependency resolution followed by adapter construction, and says to build each
ready adapter once with its resolved dependency
(`external-command-connectors.md:314-318`).

The current built-in constructors are benign, so this does not break Gmail by
itself, but it makes the generic registry contract materially less safe than
documented.

**Concrete fix:** Separate side-effect-free planning from runtime adapter
construction. Put cache planning on registry metadata/a planner object or
require an explicitly side-effect-free planning factory, resolve dependencies,
then instantiate only ready remote adapters. Cached paths can return from a
small cache-result path or receive a ready adapter after planning. Test that an
unavailable dependency never invokes the runtime factory.

### I9. The durable agent guide contradicts the implemented adapter set

**Evidence:** `AGENTS.md:28-30` still says the only implemented adapters are RSS
and GitHub and that Gmail is “not currently implemented or architected.” The
same file then records command-backed adapter invariants at lines 34-40, while
`README.md:64-102` documents the implemented experimental Gmail connector and
`lib/cybort/adapter_registry.rb:9-22` registers it. Because `AGENTS.md` is the
required durable entry point and gives code/tests top authority, this stale
statement will misdirect future implementation and review work.

**Concrete fix:** After the code defects are resolved, state that RSS and GitHub
are direct HTTP adapters and Gmail is an implemented but experimental
command-backed adapter pending its contract smoke test. Preserve the distinction
between “implemented” and “accepted/supported”; do not call `gws` an officially
supported Google product.

## Minor findings

### M1. Detail-command failure metadata uses the wrong command index

**Evidence:** `run_gws` increments `@command_index`, making list command 1 and
the first detail command 2 (`lib/cybort/adapters/gmail.rb:102-107`). After the
detail returns, parsing and ID validation receive `index + 1`, so the first
detail is recorded as command 1, the same as the list
(`gmail.rb:43-51`). Command-execution failures use the correct field, while
invalid JSON or a mismatched detail ID use the incorrect one.

**Concrete fix:** Pass the captured actual `@command_index` returned alongside
the command result, rather than deriving it from the zero-based message index.
Assert exact indices for list invalid JSON, first/second detail invalid JSON,
and mismatched IDs.

### M2. Objects described as immutable are only shallowly frozen

**Evidence:** `AdapterPlan` duplicates and freezes its context hash but retains
the same nested `items` array and objects (`lib/cybort/adapters/base.rb:2-16`).
`Dependency` freezes the struct and environment-key array, but its executable,
purpose, install hint, and auth hint strings remain mutable
(`lib/cybort/dependency.rb:4-30`). Registry entries themselves are mutable, and
their dependency arrays are only shallowly frozen
(`lib/cybort/adapter_registry.rb:3, 30-38`). Callers holding original string or
array references can mutate values after registration/planning, undermining the
“immutable plan” and stable-guidance claims.

**Concrete fix:** Either rename/document these as shallow snapshots or deep-copy
and freeze all boundary values that must remain stable. Add mutation tests for
the context's item collection and dependency declaration strings.

### M3. Timestamp normalization accepts a type the design rejects

**Evidence:** The design permits only a string `internalDate` containing a
positive integer (`external-command-connectors-design.md:270-275`). The adapter
calls `value.to_s`, so a JSON numeric value is also accepted
(`lib/cybort/adapters/gmail.rb:172-177`). This is tolerant but contradicts the
captured response contract and can mask upstream shape drift.

**Concrete fix:** Require `value.is_a?(String)` before the numeric pattern, or
explicitly change the design and add fixtures if numeric values are intentionally
supported.

## Overall verdict

The architecture has several good properties at this SHA: argument-vector
execution avoids shell interpolation, stdout/stderr are drained concurrently,
stdin is closed, output is bounded, source failures retain last-known-good
items, configuration validation precedes persistence registration, cache mode
is frozen across the TTL boundary, raw command output is absent from failure
metadata, and the documentation correctly avoids claiming official Google
product support.

Those strengths do not offset the release blockers. The only new connector
constructs an invalid real command, and the generic runner can return while a
TERM-ignoring descendant remains active. The passing suite demonstrates useful
internal behavior but does not validate the critical process and executable
boundaries. C1 and C2 should be fixed first, followed by environment
propagation, executable/version cache semantics, and boundary-focused tests.
After fixes, rerun the full offline suite and the focused lifecycle probes; keep
Gmail experimental and ADR/design status Proposed until the authenticated
`gws` contract smoke test records the supported version, effective read-only
scopes, and sanitized list/detail shapes.
