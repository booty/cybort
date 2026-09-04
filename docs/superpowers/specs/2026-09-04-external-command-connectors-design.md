# External Command Connectors and Dependency Preflight Design

**Status:** Proposed for implementation planning
**Date:** 2026-09-04

## Summary

Cybort will support both direct HTTP adapters and adapters backed by local
command-line tools. The choice is made per connector: use direct HTTP when it
is already small and stable, and use an existing CLI when it removes
substantial authentication or protocol code.

Command-backed adapters will declare their executable dependencies. After
configuration and cached contexts are loaded, Cybort will determine which
instances actually need a remote fetch. It will resolve the dependencies for
those instances before starting their adapter threads. Missing dependencies are
reported as immediate per-instance failures, with all affected tools grouped in
the run result, while fresh cached instances and healthy adapters continue.

The first command-backed adapter will be Gmail through the Google-maintained
`googleworkspace/cli` project and its `gws` executable. The upstream README
explicitly says that it is not an officially supported Google product and that
it is under active pre-1.0 development; Cybort will therefore support a tested
version range and isolate command construction behind one adapter boundary.
`gws` owns Google OAuth setup and credential storage. Cybort will invoke it,
parse its structured JSON output, and normalize the returned Gmail messages
into the existing `FetchResult` and `Item` contracts. Cybort will not implement
a Gmail OAuth browser flow, token refresh, or credential store.

The current RSS and GitHub adapters remain direct HTTP adapters. This design
does not justify rewriting either one merely to make connector mechanisms
uniform.

## Context

Cybort is a local, single-user Ruby application whose primary priorities are
ease of implementation and maintenance. The existing adapter contract already
isolates source fetching from persistence: adapter threads return normalized
results, and the orchestrator persists them sequentially in one SQLite
database.

Authentication is the main source of unnecessary complexity for future
connectors. Gmail API requests require OAuth 2.0, including authorization-code
exchange, refresh-token storage, and revoked-credential handling. A personal
application can reasonably require that a user install and authenticate a
local CLI once instead of owning that flow.

This approach adds a runtime dependency boundary and a subprocess boundary.
Those boundaries must be explicit so missing tools fail before concurrent work,
command invocation is testable without real accounts, and adapters do not
silently grow shell-specific behavior.

## Goals

- Minimize connector-specific implementation and authentication code.
- Allow a connector to choose direct HTTP or an external CLI independently.
- Detect every missing executable required by instances that need a remote
  fetch before their threads start and report actionable installation guidance.
- Keep command invocation safe, argument-based, and independently testable.
- Preserve the existing adapter, orchestrator, persistence, and failure
  contracts.
- Add a useful Gmail read-only fetch without implementing OAuth in Cybort.
- Keep production tests offline and deterministic.

## Non-goals

This design does not include:

- a generic plugin marketplace or dynamic adapter loading;
- automatic installation or upgrading of external tools;
- an OAuth implementation, browser callback server, or token refresh store;
- a `jq` or `rg` runtime dependency when Ruby can perform the work;
- replacing the existing RSS or GitHub HTTP adapters;
- Gmail sending, mutating labels, archiving, deleting, or marking messages;
- Gmail attachment or complete MIME-part extraction;
- incremental Gmail history synchronization or pagination beyond the initial
  bounded request;
- retry, backoff, scheduling, retention, dashboard, or analysis workflows; or
- fixing the separate alternate-installation-path CLI gap.

## Design decisions

### 1. Hybrid connector mechanisms

Each adapter may use one of two implementation mechanisms:

1. direct HTTP through the existing injectable `HttpClient`; or
2. a local executable through the new injectable `CommandRunner`.

The adapter result contract does not change. The adapter still validates its
configuration, decides whether its cache is fresh, fetches when necessary,
normalizes source records, and returns a `FetchResult`. The orchestrator and
`Persistence` remain unaware of whether a result came from HTTP or a process.

Use a CLI only when it materially removes authentication or protocol work. A
CLI is not required just to parse JSON or make a simple HTTP request.

### 2. Declared executable dependencies and per-instance preflight

The adapter registry will associate each adapter name with:

- its factory; and
- zero or more dependency declarations.

A dependency declaration contains the executable name, a human-readable
purpose, and an installation hint. The initial declarations are:

| Adapter | Executable | Installation hint |
|---|---|---|
| `rss` | none | — |
| `github` | none | — |
| `gmail` | `gws` | `brew install googleworkspace-cli` |

The preflight sequence is:

1. load common configuration;
2. validate that every configured adapter is registered;
3. run each adapter's side-effect-free configuration validation;
4. register instances and load their cached contexts;
5. build an adapter plan for each instance and determine whether it needs a
   remote fetch (`--force-fetch` always means yes);
6. resolve and version-check dependencies only for plans that need a remote
   fetch;
7. convert an unavailable dependency into an immediate failure result for that
   instance; and
8. start threads for ready plans, then persist all results as usual.

This is still fail-fast, but at the adapter-instance boundary. A fresh Gmail
cache remains available when `gws` is absent. A stale Gmail instance with a
missing `gws` dependency is reported as a source failure without starting a
Gmail thread, while healthy RSS/GitHub instances continue. The same behavior
applies under `--force-fetch`, where the affected instance cannot use cache.
Dependency failures therefore use the existing per-source exit status `1`.
Only malformed configuration, an unknown adapter, or an invalid dependency
declaration is a run-wide configuration error with exit status `2`.

The checker resolves the exact absolute executable path by searching the
current process `PATH` directly rather than invoking `which`. A PATH entry is
valid only when it names a regular executable file; empty entries mean the
current working directory, matching POSIX PATH semantics. The resolved path is
then passed to the runner, eliminating a check/use race from a second lookup.

For `gws`, preflight also invokes `gws --version` with the bounded runner and
accepts versions in the tested range `>= 0.22.5, < 0.23.0`. A missing,
unparsable, or out-of-range version becomes the same per-instance dependency
failure. The supported version range is updated only after a manual contract
smoke test and new captured fixtures.

The checker never installs, modifies, or authenticates a tool. Authentication
readiness remains the external CLI's responsibility; an installed but
unauthenticated command produces a source-level failure with a safe static
diagnostic and setup guidance.

### 3. Safe, bounded, injectable command execution

`CommandRunner` will expose one narrow operation conceptually equivalent to:

```ruby
CommandResult = Struct.new(
  :argv, :stdout, :stderr, :status, :executable, :version,
  :stdout_truncated, :stderr_truncated, keyword_init: true
)

CommandRunner#run(
  argv,
  env: {},
  timeout_seconds: 30,
  max_output_bytes: 1_048_576
) # => CommandResult
```

The implementation will invoke an absolute executable path with
`Open3.popen3`, `unsetenv_others: true`, and an allow-listed environment
containing only `HOME`, `PATH`, `TMPDIR`, and connector-provided variables. It
will reject an empty argument vector, read stdout and stderr concurrently, cap
each stream at `max_output_bytes`, and preserve the exit status. If the deadline
expires, it will send `TERM`, wait a short grace period, send `KILL` if needed,
reap the child, and return a timeout result. The runner will never leave a
child process or pipe behind.

The Gmail adapter will use a 30-second per-command timeout and a five-minute
per-adapter monotonic deadline. Each detail command receives the remaining
adapter budget, so `num_items_to_fetch` cannot create an unbounded wait.

Captured stderr is never copied into a `FetchResult` error, CLI JSON, or
SQLite. Command failures use a bounded safe diagnostic containing only the
executable name, operation, exit category/code, and version. No stdout is
included in errors. This prevents account identifiers, credential paths,
terminal control characters, and arbitrarily large external diagnostics from
becoming durable data. A future explicit local debug facility may expose raw
output, but it is not part of this feature.

Adapters will inspect the result and raise a `CommandError` carrying that safe
diagnostic and bounded metadata when the command exits unsuccessfully, times
out, or emits invalid JSON. Tests will inject a fake runner that returns
fixture output; no test will invoke `gws` or contact Gmail.

### 4. Gmail uses `gws` for authentication and API access

The Gmail adapter will require the user to install and authenticate the
Google-maintained `googleworkspace/cli` project outside Cybort. Its upstream
README calls it an unsupported, pre-1.0 product; this is a deliberate
single-user maintenance tradeoff, not a claim that it has Google's normal
product-support guarantees. The expected macOS setup is:

```bash
brew install googleworkspace-cli
gws auth setup
gws auth login --scopes https://www.googleapis.com/auth/gmail.readonly
gws auth status
```

`gws auth setup` requires `gcloud` when it automates Google Cloud project and
credential creation. If `gcloud` is not installed, the user may perform the
documented manual Cloud Console setup and then run `gws auth login`. Cybort's
runtime dependency is only `gws`; it does not invoke `gcloud`.

The explicit `--scopes` form is required. Do not use the service-picker
`--services`/`-s` form, because the supported version has open reports of scope
drift and unexpected `cloud-platform` inclusion. The selected Gmail scope is
`https://www.googleapis.com/auth/gmail.readonly`; identity scopes that the CLI
itself adds are documented by the tested CLI version. Before accepting a new
supported version, manually inspect `gws auth status` and the authorization
request to verify that no mutating Gmail or unrelated broad scopes are added.

The CLI stores credentials using its own supported mechanism. Cybort stores no
OAuth client secret, access token, refresh token, or credential-file contents.
The first slice uses the default authenticated `gws` context only. Per-instance
credential-file selection and multiple Gmail accounts are deferred until the
upstream credential-file precedence behavior is verified and separately
designed.

The first Gmail configuration supports:

```toml
[instances.personal_gmail]
name = "Personal Gmail"
adapter = "gmail"
ttl_minutes = 60
num_items_to_fetch = 25
user_id = "me"
query = "in:anywhere"
```

`user_id` defaults to `me`. `query` is an optional Gmail search expression and
defaults to an empty query. The adapter will request at most
`num_items_to_fetch` message IDs, then fetch metadata for those IDs. It will
not fetch more detailed pages or continue pagination in this slice.

Conceptually, the command-backed fetch performs:

1. `gws gmail users messages list` with `userId`, `maxResults`, and optional
   `q` parameters;
2. for each returned message ID, `gws gmail users messages get` with
   `userId`, the message ID, and metadata format; and
3. JSON parsing and normalization into `Item` values.

The exact command argument construction belongs to the implementation plan,
but all parameters will be passed as structured JSON arguments rather than
shell interpolation.

### 5. Gmail normalization and failure semantics

The accepted list response is either an object with a `messages` array of
objects containing nonblank string `id` values, or an object with no
`messages` member. The latter is a successful empty collection. Duplicate IDs
are de-duplicated while preserving first-seen order. The detail response must
contain a nonblank `id` matching the requested ID; a mismatch is a failure.

Message headers are matched case-insensitively. The first nonblank `Subject`,
`From`, `Date`, and `Message-ID` values are used when present. A missing or
blank subject becomes `(no subject)`, and a missing snippet produces a `nil`
body. A string `internalDate` containing a positive integer number of
milliseconds is converted to UTC; a missing or invalid timestamp becomes a
`nil` `remote_created_at` and does not fail the item. Missing optional payload,
labels, or thread fields are accepted. Empty or invalid message IDs are not.

For each Gmail message:

- `canonical_id` is the Gmail message `id`;
- `title` is the normalized Subject or `(no subject)`;
- `body` is the API-provided message `snippet`;
- `remote_created_at` is the valid `internalDate`, when present;
- `urls` is empty because the API ID does not provide a stable account-neutral
  web URL for this slice; and
- `info` contains non-canonical metadata such as sender, thread ID, labels,
  and RFC `Message-ID` when present.

`sync_state` remains an empty hash. This is a bounded collection attempt, not a
mailbox snapshot. It fetches only the first requested page, and changing the
Gmail query does not remove items collected under an earlier query; retention
and deletion remain out of scope.

If the list command fails, any detail command fails, the command returns zero
with empty stdout, JSON is malformed, or required IDs are invalid, the entire
adapter attempt returns a failure result. No partial Gmail result is persisted.
This follows the existing per-adapter transaction boundary.

`FetchResult.failure` will accept optional bounded metadata. Command failures
use metadata containing only `tool`, `operation`, `command_index`,
`exit_category`, `exit_code`, and `tool_version`; no raw stderr, stdout,
credential path, token, or message body crosses into the exception, CLI JSON, or
SQLite. Success metadata records the tool name, supported version, configured
query, requested limit, and command statuses.

### 6. Dependency and authentication guidance

An unavailable dependency result will name the affected instance(s), explain
what the tool is used for, and show the Homebrew command when the declaration
provides one. For example:

```text
Unavailable connector dependencies:
  personal_gmail: gws — Google-maintained Google Workspace CLI
  Install with: brew install googleworkspace-cli
  Authenticate with: gws auth setup && gws auth login --scopes https://www.googleapis.com/auth/gmail.readonly
  Verify with: gws auth status
```

Homebrew is the preferred installation path on macOS. Other supported
installation methods are linked from the upstream project documentation. The
application will not attempt an interactive login during a fetch. An installed
but unauthenticated CLI remains a source-level failure with a static safe
diagnostic; the user can run the external setup/status commands directly.

## Runtime flow

The new run flow is:

```text
configuration
      │
      ▼
registry validates adapter names and source configuration
      │
      ▼
contexts loaded; each adapter plan decides cache versus remote fetch
      │
      ├── invalid configuration → one startup error, no threads
      │
      ▼
per-instance dependency/version preflight for remote plans
      │
      ├── unavailable → failure result for that instance, no thread
      │
      ▼
orchestrator starts ready adapter threads
      │
      ├── RSS/GitHub adapter ── HTTP client ──┐
      └── Gmail adapter ── CommandRunner/gws ─┤
                                               ▼
                                      FetchResult values
                                               │
                                               ▼
                              sequential Persistence writes
```

The existing SQLite, transaction, partial-failure, cache, and CLI JSON
contracts remain unchanged. Missing dependencies for stale or forced instances
are ordinary per-source failures; fresh cache hits do not require the external
tool. Configuration errors still use exit status `2`.

## Component boundaries

### `AdapterRegistry`

Owns explicit entries mapping adapter names to factories, dependency metadata,
and side-effect-free configuration validation. It validates configured adapter
names, aggregates configuration errors, and produces dependency requirements
for a specific adapter plan. It does not execute commands.

### `DependencyChecker`

Owns PATH resolution, regular-file/executable checks, and tested-version
validation. It returns the exact executable path and a safe unavailable reason.
It does not run authentication flows or install software.

### `CommandRunner`

Owns safe, bounded subprocess execution, timeout cleanup, and result capture.
It has no adapter-specific knowledge and is injectable in tests. Its child
environment is an allow-list rather than an implicit copy of Cybort's process
environment.

### `Adapters::Gmail`

Owns Gmail-specific command arguments, response parsing, normalization, and
configuration validation. It owns the bounded adapter deadline and maps command
errors to safe `FetchResult` metadata. It does not know SQLite schema or persist
results.

### `Orchestrator` and `CLI`

The orchestrator owns adapter-specific configuration validation, context-aware
dependency preflight, and conversion of unavailable dependencies into failure
results. It performs preflight exactly once so direct orchestrator callers and
the CLI have the same behavior. The CLI constructs and injects the checker and
runner and maps only run-wide configuration errors to exit status `2`. Both
continue to coordinate threads and sequential persistence as defined by ADR
0001.

## Testing strategy

### Dependency preflight tests

- resolve an executable in a supplied `PATH` and return its exact absolute path;
- reject directories, non-executable files, duplicate PATH entries, and handle
  empty PATH entries as the current working directory;
- report a missing executable with its purpose and Homebrew hint;
- aggregate and de-duplicate dependency requirements for remote-fetch plans;
- accept the tested `gws` range and reject missing, unparsable, or unsupported
  versions; and
- mark an unavailable stale/forced instance as failed before its thread starts
  while allowing a fresh cache and healthy adapters to proceed.

### Command runner tests

- preserve exit status and bounded stdout/stderr capture;
- pass argument vectors without shell expansion;
- terminate and reap a child after timeout, escalating from TERM to KILL;
- cap output and mark truncation without unbounded memory growth;
- construct a minimal child environment without unrelated parent secrets; and
- allow a fake runner to be injected into an adapter test.

### Gmail adapter tests

- validate required and optional configuration;
- construct list and detail command arguments for the tested `gws` contract;
- map case-insensitive headers, snippets, timestamps, IDs, labels, and
  metadata;
- enforce `num_items_to_fetch` across list/detail calls;
- accept an omitted/empty `messages` list as a successful empty fetch;
- reject blank or mismatched IDs, but tolerate missing optional fields and
  invalid timestamps;
- convert non-zero commands, zero-output commands, and malformed JSON into
  failure results;
- prove safe error metadata never contains stderr, stdout, paths, tokens,
  email addresses, control characters, or oversized output; and
- enforce the per-command and aggregate adapter deadlines.

### Integration and system tests

- a configured RSS/GitHub run remains unchanged when no command-backed adapter
  is present;
- a missing `gws` dependency on a fresh Gmail cache leaves the cache available;
- a missing `gws` dependency on a stale Gmail instance fails only that instance
  while healthy RSS continues;
- `--force-fetch` makes the unavailable Gmail instance fail without a thread;
- a fake `gws` runner produces persisted Gmail items through the normal
  orchestrator and SQLite path; and
- a Gmail command failure preserves existing data and reports a source failure.

All tests use temporary SQLite databases, fake HTTP/command clients, and local
fixtures. No production test invokes `gws`, `gh`, Gmail, GitHub, or another
external service.

The supported `gws` version must also have a separate manual contract smoke
test documented outside the offline suite. That smoke test verifies the
installed version, explicit OAuth scopes, `gws auth status`, and the exact list
and detail JSON shapes before a version-range update is accepted.

## Operational and maintenance consequences

### Positive

- Gmail authentication and token lifecycle stay outside the Ruby application.
- Missing tools fail before the affected adapter starts and are explained in
  one place without making healthy sources unavailable.
- Command-backed and HTTP-backed adapters share the same result and persistence
  contracts.
- The command boundary is small and testable without a real account.
- Existing adapters avoid unnecessary rewrites.

### Negative

- Gmail depends on the Google-maintained `googleworkspace/cli` project, whose
  upstream README explicitly says it is not an officially supported Google
  product and warns of pre-1.0 breaking changes.
- Users must install and authenticate an additional tool before Gmail works.
- The application must translate subprocess failures and malformed output into
  useful source errors.
- The first slice uses one default authenticated `gws` context; multiple Gmail
  accounts require a later credential-context design.

These costs are acceptable for a single-user application whose priority is
minimal in-process code. The adapter should document the tested `gws` version
and keep command construction isolated so a CLI upgrade changes one boundary.

## Deferred decisions

- whether to migrate the existing GitHub adapter to `gh`;
- whether to add optional authenticated readiness probes;
- how to support multiple Gmail credential contexts;
- whether Gmail should fetch full MIME text, attachments, or HTML;
- how to support Gmail history IDs and incremental synchronization; and
- whether another connector has a sufficiently stable, useful CLI to adopt.

## Related records

- [ADR 0001: Persistence Storage and Write Ownership](../../adr/0001-persistence-storage-and-write-ownership.md)
- [ADR 0002: External Command Dependencies and CLI-backed Adapters](../../adr/0002-external-command-dependencies-and-cli-adapters.md)
- [Design review](../reviews/2026-09-04-external-command-connectors-design-review.md)
