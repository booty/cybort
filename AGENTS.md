# Cybort Agent Guide

This is the durable entry point for agents working in this repository. Keep it
short and high-signal: record cross-cutting invariants and workflow rules here,
not connector-specific session history. Read the relevant project documents
before changing code or documentation.

## Stable invariants

- Cybort is a local, single-user personal-information collector.
- The canonical datastore is exactly two SQLite databases:
  `~/.cybort/cybort.sqlite3` for control/item data and
  `~/.cybort/cybort-timeseries.sqlite3` for series, observations, and durable
  import receipts. JSON is a presentation/export format.
- The default configuration is `~/.cybort/cybort.toml`. A source instance has
  a stable ID, display name, adapter type, TTL, and `num_items_to_fetch`.
- `.cybort.example.toml` is the canonical configuration template. Connector
  changes update its examples, placeholders, limits, and auth caveats in the
  same change; README guidance links to the template instead of duplicating
  TOML blocks.
- `num_items_to_fetch` limits one source fetch; it is not retention.
- `retention_ttl_minutes` is optional item retention after a successful remote
  fetch. Omission retains items forever. `hard_expiry_ttl_minutes` is a
  separate run-start expiry that applies even when a source fails. Explicit
  `purge INSTANCE_ID` removes that instance's item/time-series state and fetch
  history, optionally after a SQLite backup.
- Version-one time-series observations are retained forever. Adapters stream
  normalized values into disposable, persistence-owned SQLite spools and do
  not own canonical SQL, transactions, or persistence writes.
- Adapter threads fetch, validate, and normalize. The orchestrator owns
  planning, completion ordering, and result handoff. Item results persist one
  instance at a time as each completes; a slow source does not delay faster
  sources. A dedicated time-series writer is the only writer for the separate
  time-series database, while the orchestrator writes the item database.
- Persistence owns SQLite access, upserts, sync state, fetch history, and
  transactions. No transaction spans all instances or both databases.
- Collection, initialization/reset, backup, and purge share one nonblocking
  exclusive installation lock. The two databases are one logical installation,
  not a globally atomic snapshot.
- A failed source must not discard successful results from other sources.
- Item identity is scoped by `(adapter_instance_id, canonical_id)`.
- The installation root is mode `0700`; configuration, canonical databases,
  and reset backups are mode `0600` regardless of umask. Symlinked canonical
  files are refused.
- The collector supports `init`, normal fetch, `--force-fetch`, `--json`, and
  `purge`. Exit status `0` is success, `1` is source/partial failure, and `2`
  is configuration/usage error.
- Command-backed adapters declare dependencies. Startup validates configuration,
  freezes cache-vs-remote decisions, resolves each unique executable/version
  once per run, and reports missing tools only for affected sources. This slice
  supports macOS/POSIX process semantics.
- Tests use local fixtures and injected clients; they must not contact external
  services. Do not assert exact diagnostic/debugging prose. Test durable
  behavior: failures surface, useful typed/sanitized information is available,
  output framing is preserved, and secrets/raw response bodies are absent.
- `docs/spitballing/initial-spitballing.md` is historical. Current ADRs and
  design records are authoritative.

Connector-specific contracts, experimental status, and live release gates are
in [`docs/current-state.md`](docs/current-state.md) and the relevant ADRs. Do
not copy those details back into this file unless they become cross-cutting
invariants.

## Git workflow

- While this remains a single-developer repository, explicitly authorized
  implementation work defaults to the current `main` branch. Do not create a
  feature branch or worktree unless requested.
- That default does not authorize commits, pushes, or work outside the task.
  Follow the user's requested commit/push checkpoints.
- Never run concurrent writing agents in the shared worktree. A reviewer starts
  only after the implementation agent is idle.
- Revisit this policy before another developer contributes.

## Delegation and review roles

- Delegate test commands and exploration of noisy test/log output to a Luna
  subagent when that saves tokens. Test-only Luna jobs are read-only.
- An implementation Luna may edit source/tests/docs only when the user
  explicitly authorizes implementation; the primary agent remains responsible
  for interpretation, review, commits, and pushes.
- Require concise subagent reports containing: command, pass/fail, relevant
  failure, first actionable error, clearly labeled inference, and next step.
  Keep raw logs out of the conversation.
- Use `gpt-5.6-luna` medium for test/log work and the reasoning level requested
  for implementation. Use Astra for architectural, concurrency, security, or
  data-loss review when risk justifies it; use Sol for final code review when
  requested or warranted. Do not add reviewers to low-risk documentation or
  one-line changes.
- Review findings must be explicitly accepted, rejected, or deferred. If a
  reviewer hits a usage limit, continue with a bounded primary review and note
  the fallback rather than waiting indefinitely.

## Autonomy and planning

- “Proceed,” “go ahead,” or an explicit end-to-end authorization means continue
  through the named design, implementation, review, verification, commit, and
  push phases without repeated approval prompts. Pause only for a genuine
  blocker or a materially ambiguous choice.
- Classify work before acting. Use a short in-chat design for bounded changes;
  use the full design/spec/plan process for architectural changes. During
  planning, inspect tests but do not run the project suite merely for a
  baseline. Run tests for implementation work or when investigating a known
  failure.

## General

- Prefer `ast-grep` for supported structural searches and `rg` for text,
  comments, prose, and unsupported file types. Never use ast-grep rewrite
  without interactive mode and explicit permission.
- Include units in identifiers where applicable (`ttl_minutes`, `length_km`).
- Update inline comments when changing corresponding code.
- Use `apply_patch` for local edits. Preserve unrelated worktree changes.

## Documentation authority and required reading

When documents disagree: code/tests describe actual behavior; accepted ADRs
describe architectural decisions; current design specs describe intended
architecture; README describes user-facing setup; historical spitballing is
exploration only.

At task start:

1. Read this file fully.
2. Read only the relevant README sections; use `rg -n '^##|^###' README.md`
   to locate them. Read the whole README only when changing user-facing setup.
3. Read `docs/adr/README.md` and the ADRs relevant to the task.
4. Read relevant headings in `docs/LEARNINGS.md`; read the full file only for
   broad cross-cutting work.
5. For connector or release-gate work, read the relevant sections of
   `docs/current-state.md`. For architectural work, read the current design
   spec and implementation plan.

Use index documents to locate records; filenames alone do not establish status.

Durable knowledge belongs in the right place: stable invariant in this file,
architectural choice in an ADR and its index, user procedure in README, and
implementation gotcha in `docs/LEARNINGS.md` with date, status, evidence,
impact, and any next action. Keep task-only details in the plan or issue.

Before handoff, verify relevant tests and documentation links, and ensure new
decisions are represented in the ADR index. Do not run the project suite for
documentation-only work unless explicitly requested.
