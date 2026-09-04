# External Command Connectors and Dependency Preflight Design

**Status:** Proposed for adversarial review  
**Date:** 2026-09-04

## Summary

Cybort will support both direct HTTP adapters and adapters backed by local
command-line tools. The choice is made per connector: use direct HTTP when it
is already small and stable, and use an existing CLI when it removes
substantial authentication or protocol code.

Command-backed adapters will declare their executable dependencies. Before a
run starts any adapter work, Cybort will scan the dependencies required by all
configured adapter instances. If one or more executables are missing, the run
will fail with one actionable error containing every missing tool and a
Homebrew installation hint where available. No adapter thread or source fetch
will start in that case.

The first command-backed adapter will be Gmail through the `gws` Google
Workspace CLI. `gws` owns Google OAuth setup and credential storage. Cybort will
invoke it, parse its structured JSON output, and normalize the returned Gmail
messages into the existing `FetchResult` and `Item` contracts. Cybort will not
implement a Gmail OAuth browser flow, token refresh, or credential store.

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
- Detect every missing executable required by configured adapters before a run
  starts and report actionable installation guidance.
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

### 2. Declared executable dependencies and strict preflight

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

1. load and validate configuration;
2. validate that every configured adapter is registered;
3. collect and de-duplicate dependencies for all configured instances;
4. check that each executable is present on `PATH`;
5. if any are missing, raise one startup error listing every missing tool,
   purpose, and installation hint; and
6. only then initialize run state and start adapter threads.

Preflight applies to configured adapters even when their cache might be fresh.
This keeps startup behavior deterministic and ensures a run never appears
healthy while a configured connector cannot be executed when it becomes
stale. Missing dependency errors are configuration/startup errors and use the
CLI's existing exit status `2`, rather than being reported as per-source
partial failures.

The checker will search the current process `PATH` directly rather than invoke
the shell's `which` command. It will not install, modify, or authenticate a
tool. Authentication readiness remains the external CLI's responsibility; a
command that is installed but not authenticated produces an adapter failure
with the CLI's actionable error output.

### 3. Safe, injectable command execution

`CommandRunner` will expose one narrow operation conceptually equivalent to:

```ruby
CommandResult = Struct.new(:argv, :stdout, :stderr, :status, keyword_init: true)

CommandRunner#run(argv, env: {}) # => CommandResult
```

The implementation will call `Open3.capture3(env, *argv)` without a shell. It
will reject an empty argument vector, preserve the subprocess exit status, and
capture stdout and stderr separately. It will not log environment values or
command output by default.

Adapters will inspect the result and raise a source error containing a safe
summary when the command exits unsuccessfully or emits invalid JSON. Tests will
inject a fake runner that returns fixture output; no test will invoke `gws` or
contact Gmail.

### 4. Gmail uses `gws` for authentication and API access

The Gmail adapter will require the user to install and authenticate `gws`
outside Cybort. The expected local setup is:

```bash
brew install googleworkspace-cli
gws auth setup
gws auth login -s gmail
```

The CLI stores credentials using its own supported mechanism. Cybort stores no
OAuth client secret, access token, or refresh token. An optional
`credentials_file` instance option may be passed to the subprocess through
`GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE` for users who maintain separate
credential exports; otherwise `gws` uses its normal local credential context.

The first Gmail configuration supports:

```toml
[instances.personal_gmail]
name = "Personal Gmail"
adapter = "gmail"
ttl_minutes = 60
num_items_to_fetch = 25
user_id = "me"
query = "in:anywhere"
# credentials_file = "/path/to/exported-gws-credentials.json"
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

For each Gmail message:

- `canonical_id` is the Gmail message `id`;
- `title` is the `Subject` header, with `(no subject)` as the fallback;
- `body` is the API-provided message `snippet`;
- `remote_created_at` is the API `internalDate` converted from milliseconds to
  UTC when present;
- `urls` is empty unless a stable message URL can be derived without making
  account assumptions;
- `info` contains non-canonical metadata such as sender, thread ID, labels,
  and the RFC `Message-ID` when present; and
- `sync_state` remains an empty hash in this initial slice.

If the list command fails, any detail command fails, or required JSON fields
cannot be parsed, the entire adapter attempt returns a failure result. No
partial Gmail result is persisted. This follows the existing per-adapter
transaction boundary and avoids silently presenting an incomplete mailbox
snapshot.

The fetch metadata records the tool name, configured query, requested limit,
and command-level status without recording credentials or raw message bodies.

### 6. Dependency and authentication guidance

The CLI error for a missing executable will name the adapter(s) that require
it, explain what the tool is used for, and show the Homebrew command when the
declaration provides one. For example:

```text
Missing external dependencies:
  gws — required by gmail (Google Workspace CLI)
  Install with: brew install googleworkspace-cli
After installation, authenticate with: gws auth setup && gws auth login -s gmail
```

Authentication failures from an installed CLI will remain source-level
failures and will include the CLI's stderr in the per-instance error summary.
The application will not attempt an interactive login during a fetch.

## Runtime flow

The new run flow is:

```text
configuration
      │
      ▼
registry validates adapters and declares dependencies
      │
      ▼
dependency preflight checks all configured executables
      │
      ├── missing → one startup error, no threads
      │
      ▼
orchestrator loads contexts and starts adapter threads
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
contracts remain unchanged after preflight succeeds.

## Component boundaries

### `AdapterRegistry`

Owns the mapping from adapter name to factory and declared dependency metadata.
It validates configured adapter names and produces the de-duplicated dependency
set for a run. It does not execute commands.

### `DependencyChecker`

Owns executable presence checks and aggregated actionable errors. It does not
run authentication flows or install software.

### `CommandRunner`

Owns safe subprocess execution and result capture. It has no adapter-specific
knowledge and is injectable in tests.

### `Adapters::Gmail`

Owns Gmail-specific command arguments, response parsing, normalization, and
configuration validation. It does not know SQLite schema or persist results.

### `Orchestrator` and `CLI`

Own run-level dependency preflight and map startup errors to exit status `2`.
They continue to coordinate threads and sequential persistence as defined by
ADR 0001.

## Testing strategy

### Dependency preflight tests

- find an executable in a supplied `PATH`;
- report a missing executable with its purpose and Homebrew hint;
- aggregate multiple missing dependencies into one error;
- de-duplicate a dependency required by multiple instances; and
- fail before adapter threads are started.

### Command runner tests

- preserve stdout, stderr, and exit status;
- pass argument vectors without shell expansion; and
- allow a fake runner to be injected into an adapter test.

### Gmail adapter tests

- validate required and optional configuration;
- construct list and detail command arguments;
- map headers, snippets, timestamps, IDs, and metadata;
- enforce `num_items_to_fetch` across list/detail calls;
- convert non-zero commands and malformed JSON into failure results; and
- pass a configured credentials-file environment variable without exposing its
  contents.

### Integration and system tests

- a configured RSS/GitHub run remains unchanged when no command-backed adapter
  is present;
- a missing `gws` dependency returns exit status `2` before any adapter thread
  starts;
- a fake `gws` runner produces persisted Gmail items through the normal
  orchestrator and SQLite path; and
- a Gmail command failure preserves existing data and reports a source failure.

All tests use temporary SQLite databases, fake HTTP/command clients, and local
fixtures. No production test invokes `gws`, `gh`, Gmail, GitHub, or another
external service.

## Operational and maintenance consequences

### Positive

- Gmail authentication and token lifecycle stay outside the Ruby application.
- Missing tools fail before concurrent work and are explained in one place.
- Command-backed and HTTP-backed adapters share the same result and persistence
  contracts.
- The command boundary is small and testable without a real account.
- Existing adapters avoid unnecessary rewrites.

### Negative

- Gmail depends on a third-party CLI that is not an officially supported Google
  product and may change its command surface.
- Users must install and authenticate an additional tool before Gmail works.
- The application must translate subprocess failures and malformed output into
  useful source errors.
- Separate Gmail accounts may require separate exported credential files.

These costs are acceptable for a single-user application whose priority is
minimal in-process code. The adapter should document the tested `gws` version
and keep command construction isolated so a CLI upgrade changes one boundary.

## Deferred decisions

- whether to migrate the existing GitHub adapter to `gh`;
- whether dependency declarations should include minimum versions;
- whether to add optional authenticated readiness probes;
- whether Gmail should fetch full MIME text, attachments, or HTML;
- how to support Gmail history IDs and incremental synchronization; and
- whether another connector has a sufficiently stable, useful CLI to adopt.

## Related records

- [ADR 0001: Persistence Storage and Write Ownership](../../adr/0001-persistence-storage-and-write-ownership.md)
- [ADR 0002: External Command Dependencies and CLI-backed Adapters](../../adr/0002-external-command-dependencies-and-cli-adapters.md)
