# Adversarial Review: External Command Connectors and Dependency Preflight

**Review date:** 2026-09-04  
**Repository SHA reviewed:** `c5bbb1f8f5fdc8981e6678637113a21215bf48f3`  
**Working-tree state at start:** clean  
**Verdict:** Request changes; do not accept ADR 0002 or begin implementation
from the current design.

## Scope

This review covers:

- `docs/superpowers/specs/2026-09-04-external-command-connectors-design.md`;
- `docs/adr/0002-external-command-dependencies-and-cli-adapters.md` and
  `docs/adr/README.md`;
- the accepted persistence decision in `docs/adr/0001-persistence-storage-and-write-ownership.md`;
- the core design, `AGENTS.md`, `README.md`, and `docs/LEARNINGS.md`;
- the current configuration, adapter, registry, orchestrator, CLI, result,
  persistence, and item implementations under `lib/cybort/`; and
- all current tests under `test/`.

The `gws` assumptions were checked specifically against
[`googleworkspace/cli`](https://github.com/googleworkspace/cli): its current
README, shared/Gmail skill documentation, changelog, and current issues. `gws`
was not installed in the review environment, so no live Gmail or local binary
smoke test was performed. That is consistent with Cybort's offline test
invariant, but it means the proposed command contract is not yet backed by a
known-good captured version and fixture set.

Baseline verification passed:

```text
bundle exec rake test
51 runs, 176 assertions, 0 failures, 0 errors, 0 skips
```

## Severity convention

- **Critical:** an architectural contradiction, security failure, or global
  availability failure that must be resolved before the ADR can be accepted.
- **Important:** a material implementation blocker or missing contract likely
  to produce incorrect, fragile, or untestable behavior.
- **Minor:** a documentation or edge-case gap that should be resolved in the
  design or implementation plan.

## Critical findings

### C1. Strict preflight converts one source's missing dependency into a global outage and breaks the existing cache/failure contract

**Evidence:** The proposal requires all dependencies for all configured
instances to be present before any adapter work, even when the affected cache
is fresh, and maps absence to startup exit status 2
(`external-command-connectors-design.md:13-18, 110-125, 243-269`; ADR 0002
lines 25-30). In contrast, the authoritative project invariant says a failed
source must not discard successful results from other sources
(`AGENTS.md:20-26`). The core design says each adapter independently returns
cached data or fetches, errors are isolated at adapter-instance level, prior
data remains available, and the command presents current items and per-source
statuses (`cybort-core-design.md:145-157, 321-351`). The current system test
asserts exactly that behavior (`test/system/cli_system_test.rb:98-113`).

The current CLI emits its JSON payload only after `Orchestrator#run` returns
(`lib/cybort/cli.rb:20-35`). A preflight `ConfigurationError` instead goes to
stderr and exits 2 (`lib/cybort/cli.rb:36-38`). Therefore, uninstalling `gws`
would make a fresh cached Gmail instance unavailable and would also prevent
unrelated RSS/GitHub instances from running or even being presented. This is
not preservation of the existing failure contract; it is a new run-wide
failure mode.

**Recommended fix:** Choose and document one coherent policy before accepting
the ADR:

1. Prefer per-instance dependency readiness. Load contexts first, require a
   dependency only for instances that actually need a remote fetch (or for all
   affected instances under `--force-fetch`), return a normal failure status
   for an unavailable command, and continue unrelated instances. Preserve and
   present the affected instance's last-known-good items.
2. If global strict preflight is intentional, explicitly supersede the relevant
   core error-isolation/cache semantics, update `AGENTS.md` and `README.md`, and
   define the non-JSON startup output as part of the CLI contract. The design
   must stop claiming that the existing failure and CLI contracts are
   preserved.

Tests must cover a missing `gws` with (a) fresh Gmail cache, (b) stale Gmail
cache plus healthy RSS, and (c) `--force-fetch`, including stdout, stderr, exit
status, persistence writes, and retained item presentation.

### C2. The documented authentication command does not guarantee read-only, least-privilege access

**Evidence:** The design calls this a read-only Gmail connector
(`external-command-connectors-design.md:58, 70, 153-162`) but tells users to run
`gws auth login -s gmail`. Current upstream behavior does not make that command
a safe least-privilege contract. A current v0.22.5 report shows the
service-selection path adding `cloud-platform` even when deselected; that scope
grants broad Google Cloud access. Upstream also documents that the exact
`--scopes` path avoids this injection. See [googleworkspace/cli issue
#918](https://github.com/googleworkspace/cli/issues/918) and the related
[service-filter issue #741](https://github.com/googleworkspace/cli/issues/741).

The connector only needs Gmail read access, yet the proposed setup delegates
scope selection to a changing interactive preset. This violates the stated
read-only boundary independently of whether Cybort itself exposes mutations.

**Recommended fix:** Replace the service preset with an explicit, reviewed
scope command using only the minimum scope compatible with `q` plus message
metadata (currently `https://www.googleapis.com/auth/gmail.readonly`; Gmail's
metadata-only scope does not support `q`). Pin that guidance to a tested `gws`
version and add a documented `gws auth status` verification step. Do not accept
the design until the selected version has been manually verified to request no
unexpected scopes. Record this as a security requirement, not an incidental
README detail.

### C3. Raw external stderr is routed into durable storage and user-visible JSON despite the design's “safe summary” claim

**Evidence:** The command-runner section promises a safe summary and says
command output is not logged by default
(`external-command-connectors-design.md:143-150`), while the guidance section
says authentication failures “will include the CLI's stderr”
(`external-command-connectors-design.md:237-239`). The design also promises not
to record credentials or raw message bodies (`lines 221-222`). Those statements
are incompatible unless a concrete sanitizer and size limit exist.

Today, `Base#fetch` retains the original exception in a failure result
(`lib/cybort/adapters/base.rb:36-42`); `InstanceRunStatus#to_h` serializes the
exception message verbatim (`lib/cybort/orchestrator.rb:13-20`); and
`Persistence#insert_fetch_run` stores it verbatim in `error_message`
(`lib/cybort/persistence.rb:139-160`). Copying arbitrary `gws` stderr into the
exception therefore copies it to both JSON output and SQLite. External stderr
can contain account/project identifiers, credential-file paths, request
details, terminal control characters, or unexpectedly large output. Future CLI
versions may add still more sensitive diagnostics.

**Recommended fix:** Define a bounded, sanitized command-error contract before
implementation. Store/report only the executable name, normalized exit
category/code, and a short scrubbed diagnostic. Strip control characters,
redact credential paths/tokens/email addresses where appropriate, cap bytes,
and never concatenate stdout. If raw output is useful, make it an explicit
opt-in debug path with a clear local-data warning and no persistence by default.
Add sentinel tests proving secrets and oversized output do not reach the
exception message, CLI JSON, stderr, or `fetch_runs.error_message`.

## Important findings

### I1. `CommandRunner` has no timeout, cancellation, or output bound, so one child can block the entire run indefinitely

**Evidence:** The proposed runner is exactly `Open3.capture3(env, *argv)`
(`external-command-connectors-design.md:135-146`). `capture3` waits for process
completion and buffers stdout/stderr. The existing orchestrator calls
`threads.map(&:value)` and does not persist any successful adapter until every
thread finishes (`lib/cybort/orchestrator.rb:54-75`), matching accepted ADR
0001's wait-before-write model. Gmail performs up to `num_items_to_fetch + 1`
sequential subprocesses (`external-command-connectors-design.md:183-194`). A
hung `gws` process therefore prevents all persistence and CLI completion; a
chatty process can consume unbounded memory.

**Recommended fix:** Make deadline and output limits part of the runner API,
including TERM-then-KILL cleanup and child reaping. Define per-command and
per-adapter budgets, and include the command index/operation in a sanitized
timeout error. Test timeout, TERM escalation, reaping, stdout/stderr truncation,
and a timed-out Gmail detail request. Consider whether the Gmail details should
use a supported batch mechanism or bounded parallelism, but keep concurrency
bounded and failure atomic at the adapter-result level.

### I2. Version compatibility is deferred even though the chosen boundary is known to evolve and has current correctness failures

**Evidence:** Preflight checks only that an executable named `gws` exists
(`external-command-connectors-design.md:110-131`), while minimum-version checks
are deferred (`lines 364-368`). The same design acknowledges an evolving
command surface and says a tested version should be documented (`lines
351-362`). Current upstream documentation says the surface is dynamically
generated from Discovery documents, and the changelog only recently added
structured exit codes and repaired repeated query-parameter handling. A current
open report documents `gmail users messages get` sometimes returning exit 0
with empty stdout, which this adapter could misclassify as malformed data rather
than a tool failure: [issue
#740](https://github.com/googleworkspace/cli/issues/740). The repeated
`metadataHeaders` bug also demonstrates why the exact version matters: [issue
#573](https://github.com/googleworkspace/cli/issues/573).

**Recommended fix:** Do not defer compatibility. Select a tested minimum (and,
if necessary, maximum) version, check `gws --version`, define how unparsable
versions are handled, and record executable path/version in safe fetch
metadata. Use field masks and captured output fixtures from that version. Add an
opt-in/manual contract smoke test outside the offline production suite so
upstream drift is detectable before changing the supported version.

### I3. The proposed injection and registry interfaces do not fit the current construction path

**Evidence:** `AdapterRegistry#register` currently stores only a factory, and
`#build` has the fixed keywords `instance`, `context`, `http_client`, and
`clock` (`lib/cybort/adapter_registry.rb:10-34`). `Adapters::Base` accepts only
those same dependencies (`lib/cybort/adapters/base.rb:4-10`). `Orchestrator` and
`CLI.start` have no `CommandRunner` or `DependencyChecker` injection point
(`lib/cybort/orchestrator.rb:39-46`; `lib/cybort/cli.rb:9-26`). Passing a new
keyword to all adapter classes will break RSS/GitHub; special-casing Gmail in
the orchestrator will violate the desired mechanism independence.

The design also assigns preflight ownership jointly to “Orchestrator and CLI”
(`external-command-connectors-design.md:294-298`) without saying which layer
executes it. That ambiguity makes it easy to run it twice or make direct
`Orchestrator` callers behave differently from CLI callers.

**Recommended fix:** Specify one construction contract and one preflight owner.
For example, make registry entries explicit values containing `factory` and
immutable dependency declarations, have each factory close over or select only
the services it needs, inject the checker/runner into the orchestrator, and have
the orchestrator perform preflight exactly once so non-CLI callers get the same
behavior. Preserve the existing lambda-factory tests and add RSS/GitHub
regression tests proving they do not receive unsupported keywords.

### I4. “Load and validate configuration” is not achievable in the stated order with the current validation lifecycle

**Evidence:** `Configuration` validates only common keys and puts all
source-specific values into `Instance#options`
(`lib/cybort/configuration.rb:39-72`). Source validation occurs in adapter
constructors; for example, GitHub checks its token in `initialize`
(`lib/cybort/adapters/github.rb:8-12`). Adapters are currently constructed
inside threads and all construction exceptions become per-source failure
results (`lib/cybort/orchestrator.rb:54-70`). The new sequence says configuration
is validated before dependency preflight and threads
(`external-command-connectors-design.md:110-118`) but does not add an
adapter-specific validation phase.

Consequences include a missing `gws` masking an invalid Gmail option, while a
missing/invalid Gmail option can still become exit 1 instead of the documented
configuration exit 2. Existing GitHub behavior already illustrates the
classification ambiguity.

**Recommended fix:** Define a side-effect-free, adapter-specific configuration
validation API that the registry can run before dependency/readiness decisions,
or explicitly retain in-thread validation and correct the sequence/exit-status
claims. Specify whether multiple configuration errors aggregate, and test
ordering when both options and dependencies are invalid.

### I5. The checked executable is not necessarily the executable that runs

**Evidence:** `DependencyChecker` searches `PATH`, but the runner example later
invokes the unresolved `argv[0]` through a second `PATH` lookup
(`external-command-connectors-design.md:127-144`). This creates a check/use gap
and leaves selection behavior underspecified for duplicate names, relative or
empty PATH entries, symlinks, and a changed environment. Merely finding a path
also does not establish that it is a regular executable file.

**Recommended fix:** Have preflight resolve and return the exact absolute
executable path after regular-file/executable checks, and invoke that path.
Define PATH semantics explicitly and test duplicate entries, non-executable
files, directories named `gws`, empty PATH entries, and paths containing spaces.
If portability beyond POSIX is intended, define Windows/PATHEXT behavior;
otherwise state the supported platforms.

### I6. Gmail's valid empty response and normalization edge cases are unspecified

**Evidence:** The design says a successful result may contain zero items by
inheriting the existing adapter contract, but also says missing “required JSON
fields” fails the whole adapter (`external-command-connectors-design.md:200-219`).
Gmail list responses can omit the `messages` member when no messages match. The
design does not say whether that is a valid empty success. It also does not
define case-insensitive header lookup, duplicate headers, a present-but-empty
Subject, `internalDate`'s string-millisecond representation, missing snippet,
or duplicate list IDs. `Item` rejects an empty title
(`lib/cybort/item.rb:12-22`), so a blank Subject will fail unless the fallback
applies to blank as well as absent values.

**Recommended fix:** Add a precise accepted response shape and normalization
table. Treat omitted/empty `messages` as a successful empty fetch; require a
nonblank ID for each listed/detail message; define duplicate/mismatched ID
handling; make headers case-insensitive; use `(no subject)` for absent or blank
subjects; and define invalid/absent timestamp behavior. Add fixtures for every
case before implementing the parser.

### I7. Failure metadata cannot satisfy the proposed command-status recording contract without changing `FetchResult`

**Evidence:** The design says fetch metadata records command-level status
(`external-command-connectors-design.md:221-222`) and claims the result contract
does not change (`lines 86-89`). Yet `FetchResult.failure` accepts no metadata
and hardcodes `{}` (`lib/cybort/fetch_result.rb:27-35`). `Base#fetch` converts
all source/parse errors to that failure constructor
(`lib/cybort/adapters/base.rb:36-42`). Persistence can store failure metadata,
but it receives the empty hash (`lib/cybort/persistence.rb:139-160`). For a
multi-command Gmail fetch, “command-level status” is also undefined: list
status, every detail status, first failure, or aggregate.

**Recommended fix:** State whether metadata is success-only. If failure
diagnostics are required, extend the failure factory with a deliberately safe,
bounded metadata structure (for example tool, operation, command ordinal, exit
category/code, and version), and test its persistence. Do not force these facts
into the free-form error string; that worsens C3.

### I8. Credential-file behavior is security-sensitive but lacks a validation and path contract

**Evidence:** The optional `credentials_file` points to an unmasked exported
OAuth credential or service-account file and is passed through
`GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE`
(`external-command-connectors-design.md:164-180`). The design does not specify
whether relative paths are allowed or what they are relative to, whether `~` is
expanded, whether the target must be a readable regular file, or how its path is
redacted from errors. `Open3.capture3(env, *argv)` also inherits the rest of the
parent environment by default.

**Recommended fix:** Require and validate a resolved absolute, readable regular
file; reject directories and ambiguous relative paths; never persist or print
its contents and redact its path in normal errors. Document file-permission
expectations for plaintext exports. Explicitly decide whether child processes
inherit all of Cybort's environment or a minimal allowlist, and test that
unrelated secret environment variables are not surfaced in diagnostics.

## Minor findings

### M1. The setup hint omits a prerequisite and is not portable

The upstream README says `gws auth setup` requires `gcloud`; manual Cloud
Console setup is the alternative. The proposed actionable hint only installs
`gws`, then unconditionally runs `gws auth setup`
(`external-command-connectors-design.md:155-162, 224-235`). It also provides
only Homebrew guidance even though `gws` supports release binaries, npm, Cargo,
and Nix.

**Recommended fix:** Label Homebrew as a macOS convenience, mention the
supported-platform policy, state the `gcloud` prerequisite for automated setup,
and link to manual OAuth setup. Do not add `gcloud` as a runtime dependency
unless Cybort actually invokes it.

### M2. The support wording is substantively correct but conflates ownership with support

The reviewed project is specifically
[`googleworkspace/cli`](https://github.com/googleworkspace/cli), hosted in the
Google Workspace GitHub organization. At the same time, its own README states
twice that it is “not an officially supported Google product,” labels the
project pre-1.0 and under active development, and warns users to expect breaking
changes. Therefore, organization ownership supports describing it as
Google-maintained, but does not justify calling it an officially supported
Google product. The design's support disclaimer is correct; the word
“third-party” (`external-command-connectors-design.md:351-354`) is the imprecise
part because readers may take it to mean unrelated to Google.

**Recommended fix:** Say: “Cybort depends on the Google-maintained
`googleworkspace/cli`, whose upstream README explicitly says it is not an
officially supported Google product and warns of pre-1.0 breaking changes.”
Record the exact upstream URL, Apache-2.0 license, tested release, and Cybort's
own compatibility policy. Do not call it “officially supported” unless upstream
removes or supersedes that disclaimer.

### M3. The Gmail fetch is not a mailbox snapshot, and query changes retain old items

The design says all-or-nothing detail fetching avoids an “incomplete mailbox
snapshot” (`external-command-connectors-design.md:215-219`), but the operation
fetches only the first bounded page, has no pagination/history sync, and the
existing persistence layer only upserts returned items; it does not remove
items no longer returned (`lib/cybort/persistence.rb:61-73, 77-89`). Changing
`query` therefore accumulates data from earlier query scopes.

**Recommended fix:** Call this a bounded collection attempt, not a snapshot,
and document that changing the query does not prune previously collected data.
No deletion behavior should be added implicitly because retention is explicitly
out of scope.

### M4. The proposed ADR refers to an implementation plan that does not exist

ADR 0002 says “The design and implementation plan define” the exact registry,
runner, Gmail contract, and fixtures (`docs/adr/0002-external-command-dependencies-and-cli-adapters.md:87-93`), but the only
plan present is the 2026-08-16 core implementation plan. The design itself also
defers exact command construction to that absent plan
(`external-command-connectors-design.md:188-198`).

**Recommended fix:** Change the ADR to future tense until a plan exists, then
require the plan to close C1-C3 and I1-I8 before implementation begins.

### M5. Adoption requires documentation-memory updates not listed in the design

`AGENTS.md:28-30` currently says Gmail is not implemented or architected, and
`README.md` documents only RSS/GitHub configuration. That is accurate while
ADR 0002 remains proposed, but will become stale when this design is accepted
or implemented.

**Recommended fix:** Add acceptance/implementation checklist items to update
`AGENTS.md`, `README.md`, `docs/adr/README.md`, and any durable `LEARNINGS.md`
entry required by actual `gws` behavior. Keep ADR 0002 Proposed until the
critical issues are resolved.

## Overall verdict

The hybrid HTTP/CLI direction is reasonable, and retaining the current RSS and
GitHub implementations is the right simplicity choice. The proposal is not yet
safe or internally consistent enough to accept, however. Its strict preflight
changes Cybort's central isolation/cache behavior while claiming to preserve
it; its documented auth flow does not currently enforce least privilege; and
its error path can persist and expose arbitrary external stderr. The runner
lifecycle, upstream version contract, registry injection path, configuration
validation phase, and Gmail response contract also need to be explicit before
an implementation plan can be reliable.

**Decision gate:** Keep ADR 0002 **Proposed**. Revise the design to close C1-C3,
then specify and test I1-I8 in an implementation plan. Re-review the resulting
documents before coding the Gmail adapter.
