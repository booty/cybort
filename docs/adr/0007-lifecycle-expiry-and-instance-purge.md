# ADR 0007: Lifecycle Expiry and Instance Purge

- Status: Accepted
- Date: 2026-09-08

## Context

`retention_ttl_minutes` intentionally prunes only after a successful remote
fetch, which preserves last-known-good data during outages. Some operators
instead need a wall-clock local bound, and removing an instance from
configuration currently leaves its items, synchronization state, and fetch
history in SQLite. Collection planning also hydrated every cached item before
it was known whether a remote fetch was needed.

## Decision

Keep `retention_ttl_minutes` backward-compatible and add an independent,
optional positive integer `hard_expiry_ttl_minutes`. At the start of each
orchestrator run, persistence deletes items for configured instances whose
`fetched_at` is at or before the hard-expiry cutoff calculated from
persistence's injected clock. This cleanup is instance-scoped and runs before
planning, so it is independent of source success or failure. The deletion
count is included in per-instance metadata as `items_expired`.

Add `Persistence#planning_context_for`, which returns freshness/state metadata
and canonical-ID membership without materializing item objects. The
orchestrator uses it for planning and hydrates full items only for cache plans.
Remote result accounting uses the returned ID set.

Add a composite `(instance_id, fetched_at)` index through schema version 2 to
support both hard-expiry and success-triggered retention deletes. Existing
databases receive the index idempotently during `setup!`.

Add `cybort purge INSTANCE_ID`, with an exact interactive confirmation (or
`--yes`) and optional `--backup PATH`. Persistence deletes fetch history and
items before the referenced adapter-instance row in one transaction. The
backup uses SQLite's `VACUUM INTO` and must target a new path. Purge works even
when the instance is no longer present in the current TOML configuration.

## Alternatives considered

### Change `retention_ttl_minutes` semantics

Rejected for compatibility. Existing users rely on failed and cached runs
preserving last-known-good data; the new hard bound is explicit instead.

### Delete only after a successful fetch

Rejected for hard-expiry users. Source outages would defeat the stated
wall-clock local bound.

### Hydrate all items for planning

Rejected for remote-only runs because item objects are not needed to decide
freshness or construct remote adapters.

### Rely on foreign-key cascade for purge

Rejected because the existing schema does not declare cascading deletes and an
explicit delete order documents the transaction boundary clearly.

## Consequences

- Operators can choose last-known-good retention or an explicit local hard
  bound per instance.
- Purge is reviewable, recoverable before deletion via an optional SQLite
  backup, and isolated by instance ID.
- Remote-only runs use less memory and avoid unnecessary item deserialization.
- Hard expiry is destructive at run start; configure it only when that policy
  is intended.
- A hard expiry still runs only when Cybort starts a collection run; a powered-
  off process cannot perform background deletion.
