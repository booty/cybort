# ADR 0002: External Command Dependencies and CLI-backed Adapters

- Status: Proposed
- Date: 2026-09-04

## Context

Cybort is a local, single-user application whose priority is ease of
implementation and maintenance. Some sources, especially Gmail, require
OAuth and credential lifecycle code that is disproportionate to the value of
an in-process implementation for this application.

The application may require users to install and authenticate local command-
line tools. If it does so, missing tools must be detected before adapter
threads start, and command execution must remain safe and testable.

## Decision

Cybort will support a hybrid connector model:

- direct HTTP adapters remain appropriate for simple, already-implemented
  integrations such as RSS and GitHub;
- a connector may use an external CLI when the CLI removes substantial
  authentication or protocol code;
- adapters declare their executable dependencies through the adapter registry;
- context-aware startup preflight resolves and version-checks dependencies for
  instances that need a remote fetch, then converts unavailable dependencies
  into per-instance failures before those threads start; and
- command-backed adapters invoke an injectable `CommandRunner` using argument
  vectors, never shell interpolation.

The first command-backed connector will use the Google-maintained
`googleworkspace/cli` project and its `gws` executable for Gmail. Its upstream
README explicitly says it is not an officially supported Google product and is
pre-1.0, so Cybort will support a tested version range and manually verify the
OAuth scope contract. Cybort will not own Gmail OAuth flows, token refresh, or
credential storage. The existing RSS and GitHub adapters will not be rewritten
solely to use CLIs.

## Alternatives considered

### Direct Gmail API client with OAuth owned by Cybort

Rejected for the initial implementation. It would require OAuth client
configuration, a browser or callback flow, refresh-token persistence, token
refresh, revocation handling, and additional security-sensitive tests.

### Require users to provide a Gmail access token

Rejected. Access tokens expire, so this would move recurring authentication
work onto the user and produce a fragile configuration contract.

### Use a CLI for every connector

Rejected. Wrapping a CLI for a simple HTTP integration adds process execution,
dependency checks, and command-surface coupling without reducing meaningful
implementation work. RSS and the current GitHub adapter already have small,
testable direct clients.

### Install tools automatically

Rejected. Cybort should not mutate the user's system package manager or PATH.
It will provide Homebrew guidance and fail clearly when a required executable
is absent.

### Parse CLI output with `jq`

Rejected as a default. Ruby already parses JSON, and adding a runtime `jq`
dependency would increase installation and preflight surface without reducing
connector complexity.

### Require every configured connector dependency before any cache read

Rejected. A missing tool must not make a fresh cached source unavailable or
prevent healthy adapters from running. Dependency readiness is evaluated per
instance only when that instance needs a remote fetch; `--force-fetch` makes
every configured instance require its remote dependency.

## Consequences

Positive consequences:

- Gmail OAuth complexity is delegated to a tool the user can authenticate once.
- Dependency failures are detected before the affected adapter starts and
  reported without blocking healthy sources.
- HTTP and command adapters retain one result, caching, and persistence model.
- Command execution can be fully faked in tests.

Negative consequences:

- Gmail depends on the Google-maintained `googleworkspace/cli` project and its
  evolving interface; its own README says it is not an officially supported
  Google product and warns of pre-1.0 breaking changes.
- Users must install and authenticate that command separately.
- Cybort needs a small subprocess abstraction and dependency preflight layer.
- Authentication errors occur at command execution time and are reported as
  source failures with bounded safe diagnostics.

## Implementation notes

The accompanying [design specification](../superpowers/specs/2026-09-04-external-command-connectors-design.md)
and [implementation plan](../superpowers/plans/2026-09-04-external-command-connectors.md)
define the exact registry metadata, `DependencyChecker`, `CommandRunner`,
Gmail command contract, fixtures, and CLI guidance. This ADR is the
architectural rationale; those documents may specify details without changing
this decision. The decision remains Proposed until the authenticated `gws`
contract smoke test documented in those records succeeds.
