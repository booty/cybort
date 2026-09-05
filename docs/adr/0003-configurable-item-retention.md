# ADR 0003: Configurable Item Retention

- Status: Accepted
- Date: 2026-09-05

## Context

Cybort currently retains normalized items indefinitely. Its existing
`ttl_minutes` setting controls whether an adapter uses cached data or performs a
remote fetch; it does not delete stored items. Some sources benefit from a
bounded local lifetime while others should keep the existing retain-forever
behavior.

Retention must preserve Cybort's established ownership boundaries. Adapters do
not own SQLite schema details or writes, and each successful adapter result is
persisted independently in one transaction. Failed sources preserve their
last-known-good data.

## Decision

Each configured adapter instance may define a positive integer
`retention_ttl_minutes`. Omission means retain forever.

For a configured instance, persistence will prune items only as part of writing
a successful remote-fetch result for that instance. It clamps the result's
completion time to its own injected clock, then subtracts the configured
duration. An item expires when its local `fetched_at` timestamp is at or before
that cutoff. Returned items are upserted before pruning, so their new local
fetch timestamps normally refresh their last-seen time. The clamp prevents a
future-skewed adapter timestamp from authorizing deletion beyond persistence's
notion of the present. The same clamped time becomes the durable
`last_successful_fetch`, preventing future skew from keeping cache freshness
valid indefinitely, while fetch history retains the raw completion timestamp.
Past skew can only delay deletion.

Validation, item upserts, instance-scoped pruning, synchronization-state update,
and successful fetch-history insertion occur in the same per-result
transaction. Cache hits and failed remote fetches do not prune. Retention
applies only to normalized items, not adapter-instance records,
synchronization state, or fetch history.

Configuration remains the owner of the current policy; the duration is not
copied into SQLite. Because `Configuration::Instance` remains mutable for
compatibility, the orchestrator snapshots each validated duration immediately
after registry configuration validation and before adapter planning. It passes
that snapshot to the persistence write operation. Persistence independently
accepts only `nil` or a positive `Integer` before performing deletion. No schema
migration is required because existing `fetched_at` timestamps provide the
last-seen boundary.

The configured instance ID is authoritative across orchestration. Before
persisting either a successful or failed result, the orchestrator rejects an
adapter result with a different `instance_id` and records the mismatch as a
failed run for the configured ID. Rescue paths likewise use the configured ID,
so an adapter-supplied ID cannot acquire rows, state, or history.

`retention_ttl_minutes` uses a positive-integer contract even though the legacy
`ttl_minutes` setting accepts any positive numeric value. Retention is a
destructive boundary, so V1 deliberately uses whole minutes without changing
the older cache-TTL contract. Retention may be shorter than or equal to the
cache TTL: the cache TTL is a freshness minimum, not a fetch schedule, and a
cache hit still does not prune.

## Alternatives considered

### Treat `ttl_minutes` as retention

Rejected. Cache freshness and data lifetime are independent concerns. Reusing
one setting would make changing remote-fetch frequency delete data and would
contradict the existing documented meaning of TTL.

### Prune before fetching or reading cached data

Rejected. This would enforce a strict wall-clock maximum but discard
last-known-good data during source or dependency outages. The selected behavior
prunes only after the source has supplied a successful current result.

### Run cleanup in a separate transaction

Rejected. Separate cleanup could commit without the corresponding upserts and
state update, or fail after those changes commit. Retention is part of applying
one successful source result and belongs in the same transaction.

### Let adapters delete or filter persisted items

Rejected. Adapter-owned cleanup would leak SQL or storage-specific behavior
into source adapters and weaken the persistence boundary established by
[ADR 0001](0001-persistence-storage-and-write-ownership.md).

### Store retention policy in SQLite

Rejected for this slice. Configuration is authoritative for runtime adapter
behavior, and no background cleanup process needs a durable copy of the policy.
Persisting it would add a schema migration without changing observable
behavior.

### Trust the adapter completion time without a clamp

Rejected. Adapter timestamps remain useful event data, but an erroneous future
timestamp must not expand a destructive cutoff beyond the persistence service's
own clock. Clamping preserves deterministic clock injection in tests and fails
safely by retaining extra data when the adapter clock is behind.

## Consequences

Positive consequences:

- existing configurations retain items forever without modification;
- instances can opt into bounded item storage independently;
- pruning is atomic with the successful result that authorizes it;
- refetched items naturally refresh their last-seen timestamp;
- failed sources retain their last-known-good data;
- adapters remain independent of SQL and retention implementation;
- mutable adapters cannot change the validated retention policy mid-run; and
- future-skewed completion timestamps cannot indefinitely extend cache
  freshness.

Negative consequences:

- items may remain beyond the configured duration while an instance is cached,
  unavailable, or failing;
- when retention is shorter than cache TTL, a cache hit may preserve old items
  and the next successful remote fetch may remove every item it does not return;
- retention advances only when Cybort runs and the source fetch succeeds;
- items omitted because of a source request limit age out like any other unseen
  item; and
- changing or removing the configured duration takes effect on the next
  successful remote fetch and has no separately persisted audit record.

Eager all-item context hydration and a composite pruning index/schema migration
remain deferred quality follow-ups. Neither changes the correctness contract
accepted here.

## Implementation notes

The accompanying
[design specification](../superpowers/specs/2026-09-05-configurable-item-retention-design.md)
defines configuration validation, the exact expiration boundary, transaction
ordering, failure behavior, and required tests.
