# ADR 0004: Current-Snapshot Item Replacement

**Status:** Accepted
**Date:** 2026-09-05

## Context

The original adapter contract only upserts returned items. That is appropriate
for sources whose fetch result is an incremental or last-known-good collection,
but it cannot express that a complete successful fetch represents the entire
current selected set. Items absent from a later result remain until optional
age-based retention eventually removes them, or forever when retention is
omitted.

The Reddit integration needs current unread messages and a bounded current
thread selection. A message that is read and a thread that becomes inactive,
is deleted, or leaves the bounded sample should disappear after the next
complete successful remote fetch. Letting an adapter delete rows would violate
ADR 0001's persistence ownership. Reinterpreting
`retention_ttl_minutes` as snapshot reconciliation would change ADR 0003's
explicit local-age policy and failure behavior.

## Decision

Add an optional source-neutral `replace_existing_items` boolean to
`FetchResult`, defaulting to `false` for backward compatibility. Failure and
cache results use `false`. Persistence accepts `true` only for a successful
result with `source_fetched: true`.

For an accepted replacement result, persistence uses the existing per-result
transaction and performs these operations in order:

1. validate the result, all returned items, and the snapshotted retention
   policy;
2. delete all current items for the configured adapter instance;
3. upsert the result's items;
4. apply the existing optional retention cutoff;
5. update synchronization state; and
6. append fetch history.

The delete and all later operations roll back together. An empty complete
snapshot intentionally clears the instance. Persistence implements this as
generic instance-scoped behavior; adapters neither issue SQL nor calculate a
database diff.

The Reddit adapter sets replacement only after all required remote operations,
pagination, validation, ranking, and normalization complete. Cache hits and
any failed or incomplete work do not replace.

ADR 0003 remains unchanged: configured retention is still applied only after a
successful remote fetch, using persistence's clamped clock and local
`fetched_at`; cache hits and failures do not prune. Snapshot replacement is a
statement about completeness, not a time-to-live policy.

## Alternatives considered

### Reddit-specific delete SQL

Rejected. This would move schema, transaction, and write ownership into an
adapter and create a second storage model contrary to ADR 0001.

### Upsert, then delete missing identities

Rejected. Computing a durable-row diff is more complex than replacing an
instance-scoped set and makes an empty snapshot easy to mishandle. Delete then
upsert inside one transaction has clear rollback behavior.

### Treat retention as reconciliation

Rejected. Retention uses elapsed local time and intentionally preserves data on
failures. It cannot prove that an omitted item is absent from a complete source
snapshot, and changing it would conflate two independent policies.

### Replace items for every successful result

Rejected. Existing and future adapters may return increments or bounded slices
that are not complete current snapshots. Explicit opt-in preserves their
append/upsert semantics.

## Consequences

- Complete snapshot adapters can remove inactive/deleted selected items without
  owning persistence.
- A replacement result is all-or-nothing: delete, upsert, retention, sync state,
  and history share one rollback boundary.
- Existing adapters remain behaviorally compatible because the field defaults
  to `false`.
- Persistence must strictly validate the flag and reject replacement for cache
  and failure results.
- A source must not opt in unless its result is complete under its documented
  bounded-selection contract.
- Successful replacement does not provide hard wall-clock expiry during
  outages and does not handle removed configuration or explicit user deletion.
  Those lifecycle/compliance mechanisms require separate decisions.

## References

- [ADR 0001: Persistence Storage and Write Ownership](0001-persistence-storage-and-write-ownership.md)
- [ADR 0003: Configurable Item Retention](0003-configurable-item-retention.md)
- [Reddit integration design](../superpowers/specs/2026-09-05-reddit-integration-design.md)
- [Reddit implementation plan](../superpowers/plans/2026-09-05-reddit-integration.md)
