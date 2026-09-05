# Cybort Agent Guide

This file is the durable entry point for agents working in this repository.
Read it before changing code or documentation, then read the project documents
relevant to the task. Keep this file short and high-signal: record stable
invariants and workflow rules here, not session-by-session narration.

## Project invariants

- Cybort is a local, single-user personal-information collector.
- The canonical datastore is one SQLite database. The default location is
  `~/.cybort/cybort.sqlite3`. JSON is a presentation/export format, not the
  primary mutable datastore.
- The default configuration is `~/.cybort/cybort.toml`. A configured source
  instance has a stable ID, display name, adapter type, TTL, and
  `num_items_to_fetch`.
- `num_items_to_fetch` limits one source fetch. It is not a retention policy.
- Adapter threads fetch, validate, and normalize source data. They do not own
  SQLite schema details, SQL, transactions, or persistence writes.
- The orchestrator starts one adapter thread per configured instance, waits for
  every thread, then sends successful results sequentially to the shared
  `Persistence` service.
- Persistence owns SQLite access, upserts, synchronization state, and fetch
  history. Each successful adapter result has its own transaction; there is no
  transaction spanning all adapter instances.
- A failed source must not discard successful results from other sources.
- Item identity is scoped by `(adapter_instance_id, canonical_id)`.
- RSS and GitHub adapters use direct HTTP APIs. Gmail has an experimental
  command-backed adapter for Google's `gws` CLI; it remains gated on a real
  authenticated smoke test because `gws` is not installed in every environment.
  Scheduling, retention policies, dashboards, and analysis/LLM workflows are
  not currently implemented or architected.
- The CLI supports `init`, a normal fetch, and `--force-fetch`; it emits JSON.
  Exit status `0` means success, `1` means source failure or partial failure,
  and `2` means configuration or usage error.
- Command-backed adapters declare executable dependencies. Startup validates all
  source configuration before persistence registration, freezes each cache vs
  remote decision once, and resolves each unique executable/version once per
  run only for instances that need remote data. Missing tools fail only the
  affected source and include safe, grouped install/auth guidance. This slice
  supports macOS/POSIX process semantics; Windows support requires a separate
  design.
- Tests use local fixtures and injected clients; they must not contact external
  services. Run them with `bundle exec rake test`.
- `docs/initial-spitballing.md` is historical exploratory material. Treat the
  current design spec and accepted ADRs as authoritative design records, and do
  not modify the spitballing document unless the user explicitly requests it.

## General

- Include units in identifier names when applicable, ie "ttl_minutes" instead of
  "ttl" or "length_km" instead of "length"

## Planning and execution boundary

- During design, specification, or implementation-plan work, inspect existing
  tests but do not run tests, linters, builds, or other project execution merely
  to establish a baseline. Run them only when the user explicitly requests it
  or when execution is necessary to investigate a known failure that materially
  affects the document.
- Validate documentation-only work with relevant read-only checks such as diff
  review, formatting checks, link checks, and consistency checks. Reserve the
  project test suite for implementation work and explicit user requests.

# Memory/Decision/Documentation system

## Documentation authority

When documents disagree, use this hierarchy to distinguish actual behavior
from intended design:

1. Code and tests describe actual behavior.
2. Accepted ADRs describe architectural decisions and their rationale.
3. The current design spec describes intended architecture and scope.
4. `README.md` describes current user-facing setup and usage.
5. `docs/initial-spitballing.md` is historical exploration only.

Do not silently resolve a contradiction by rewriting history. Update the
affected document, or create a new ADR when an accepted decision changes.

## Required reading before work

At the beginning of a task:

1. Read this file.
2. Read `README.md` for current commands and user-facing behavior.
3. Read `docs/adr/README.md`, then the ADRs relevant to the task.
4. Read `docs/LEARNINGS.md` for dated implementation discoveries and known
   gotchas.
5. Read the current design spec and implementation plan when the task changes
   architecture or follows planned work.

Use the index documents to locate relevant records; do not assume that a
filename alone communicates an ADR's status or whether it has been superseded.

## Recording new knowledge

At the end of each task, classify durable knowledge and write it down. Future
agents are expected to both read and maintain these files:

- stable invariant -> update `AGENTS.md`;
- architectural choice -> create or update an ADR in `docs/adr/`, and update
  `docs/adr/README.md`. If an existing ADR is superseded, mark its status as
  `Superseded` in the index and link that row to the replacement ADR;
- user-facing procedure -> update `README.md`;
- implementation gotcha -> add an entry to `docs/LEARNINGS.md` and a regression
  test when the behavior is testable;
- temporary task detail -> keep it in the implementation plan or issue, not in
  permanent memory.

Every learning entry should include a date, status, observation, evidence
(file, test, or command), impact, and next action if one remains. Do not add
speculation as a settled fact.

When a change makes an existing note stale, mark it superseded or resolved and
link to the replacement. For ADRs specifically, the old ADR must remain in the
index with status `Superseded` and a link to the newer ADR. Do not delete useful
history merely because the code has evolved. Keep memory updates in the same
commit as the implementation or decision they explain whenever practical.

Before handing off implementation work, verify documentation links, run the
relevant tests, and ensure that new decisions are represented in the ADR index.
Before handing off design, specification, or plan-only work, verify the changed
documents without running the project test suite unless the planning boundary
above permits it.
