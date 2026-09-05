# Configurable Item Retention Design

**Status:** Approved for implementation planning
**Date:** 2026-09-05

## Summary

Cybort will support an optional item-retention duration on each configured
adapter instance. The common configuration key is
`retention_ttl_minutes`. When the key is omitted, items for that instance are
retained indefinitely, preserving current behavior.

When an instance has a retention duration, Cybort prunes expired items only
while persisting a successful remote fetch for that same instance. The upserts,
pruning, synchronization-state update, and successful fetch-history record all
occur in the existing per-result SQLite transaction. Cache hits and failed
remote fetches never trigger pruning, so last-known-good data remains available
through source outages even when it is older than the configured retention
duration.

## Goals

- Add an optional, backward-compatible retention setting to every adapter
  instance.
- Keep indefinite retention as the default.
- Scope deletion to the adapter instance whose remote fetch succeeded.
- Treat returned items as newly seen and age out items that have not been seen
  within the retention duration.
- Preserve the existing persistence ownership and per-result transaction
  boundary.
- Preserve last-known-good items after cache hits, source failures, dependency
  failures, and persistence failures.

## Non-goals

- scheduled or background cleanup;
- a global retention default;
- adapter-specific SQL or deletion behavior;
- retention of adapter-instance records, synchronization state, or fetch-run
  history;
- source-side deletion or reconciliation independent of item age;
- per-item or per-item-type retention settings;
- storage quotas or count-based retention; and
- the Reddit adapter itself.

## Configuration

`retention_ttl_minutes` is an optional common instance key:

```toml
[instances.personal_reddit]
name = "Personal Reddit"
adapter = "reddit"
ttl_minutes = 15
retention_ttl_minutes = 2880
num_items_to_fetch = 50
```

The value must be a positive integer when present. Zero, negative values,
strings, floats, and booleans are configuration errors. This is intentionally
stricter than the legacy `ttl_minutes` contract, which accepts any positive
numeric value: retention controls a destructive boundary, so V1 uses whole
minutes rather than introducing fractional deletion cutoffs. Changing the
existing `ttl_minutes` contract is outside this feature's scope.

An omitted key becomes `nil` in the instance value object and means retain
forever. `retention_ttl_minutes` may be less than or equal to `ttl_minutes`.
That configuration is valid because `ttl_minutes` is a cache-freshness minimum,
not a fetch schedule. It intentionally means that a cache hit can preserve
items beyond the retention duration, while the next successful remote fetch
can remove every item not returned by that fetch.

The configuration schema remains version 1 because the key is optional and
existing configuration files retain their behavior. The key is part of common
instance configuration and must not appear in the adapter-specific `options`
hash.

## Retention semantics

### Expiration timestamp

For a successful remote fetch result, persistence captures its own current
time and computes the cutoff as:

```text
reference_time = min(result.finished_at, persistence_clock_now)
cutoff = reference_time - (retention_ttl_minutes * 60)
```

The clamp prevents a future-skewed adapter timestamp from authorizing deletion
beyond persistence's own notion of the present. A past-skewed completion time
can only under-prune, which is the safe failure direction for destructive
cleanup.

An existing item expires when both conditions are true:

```text
item.instance_id == result.instance_id
item.fetched_at <= cutoff
```

The exact cutoff is expired. `remote_created_at` does not participate in
retention because the policy describes how long Cybort retains an item after it
last observes the item, not the age of the source record.

### Last-seen behavior

Adapters already assign a new local `fetched_at` value to items returned by a
remote fetch. Upserting those items refreshes their last-seen timestamp. Items
not returned by later successful fetches retain their earlier timestamp and
eventually expire.

Pruning occurs after validating and upserting the new result. A newly returned
item therefore remains stored unless its adapter supplied a `fetched_at` value
at or before the retention cutoff. Such an item is expired by the same rule as
any other item; persistence does not silently rewrite adapter timestamps.

### Trigger behavior

Pruning occurs only when all of the following are true:

1. the adapter instance defines `retention_ttl_minutes`;
2. the adapter completed a successful remote fetch; and
3. the result is being persisted successfully.

A successful empty remote fetch still triggers pruning. Cache hits do not call
the persistence write path and do not prune. Source failures, unavailable
dependencies, and other adapter failures record a failed fetch without
pruning. This intentionally permits retained data to exceed its configured age
during an outage.

## Ownership and data flow

Configuration parses and validates `retention_ttl_minutes` as part of the
common adapter-instance value object. The orchestrator keeps the association
between each fetch result and its configured instance and passes the optional
duration to `Persistence#write_fetch_result`.

Persistence remains the only owner of SQL and deletion. Its per-result
transaction becomes conceptually:

```text
BEGIN
  validate returned items
  upsert returned items
  delete expired items for this adapter instance, when configured
  update synchronization state
  record successful fetch history
COMMIT
```

Persistence uses its existing injected clock to clamp `result.finished_at` as
described above. No database migration is needed: the existing
`items.fetched_at` column supplies the last-seen timestamp, and the current
configuration supplies the policy on every run.

SQLite compares the stored cutoff and `fetched_at` values lexicographically.
That is chronologically correct only because every value on both sides is
normalized through persistence's `timestamp` helper to UTC ISO 8601 with six
fractional digits and a trailing `Z`. The pruning helper must preserve and
document this invariant.

## Failure and transaction behavior

- If item validation fails, no upsert, pruning, state update, or successful
  fetch-history record commits.
- If pruning or a later statement fails, the entire adapter-result transaction
  rolls back, including the item upserts.
- The orchestrator converts a persistence exception into the existing
  per-instance failure status and records a failed fetch independently.
- A retention policy can delete items only for the result's instance ID.
- Failure or pruning for one instance cannot roll back another instance's
  successful result.

## Presentation behavior

The CLI needs no new flag or result shape. Successfully pruned items are absent
from the items read after the persistence phase. The instance still reports the
item count returned by the current adapter result, matching existing status
semantics; the count is not redefined as the number of rows retained in SQLite.

## Testing strategy

### Configuration tests

- omission produces `nil` and preserves indefinite retention;
- a positive integer is exposed as `retention_ttl_minutes`;
- the common key is removed from adapter-specific options; and
- zero, negative, float, string, and boolean values are rejected;
- a duration shorter than `ttl_minutes` is accepted; and
- sibling instances independently retain an explicit duration or `nil`.

### Persistence tests

- omission leaves old items untouched;
- an item older than the cutoff is pruned;
- an item exactly at the cutoff is pruned;
- a newer item remains;
- a returned item's refreshed `fetched_at` keeps it retained;
- an empty successful result still prunes;
- a configured instance with no stored items succeeds;
- only the result's adapter instance is pruned; and
- a future-skewed result timestamp is clamped to the persistence clock;
- pruning leaves the adapter-instance record, synchronization state, and fetch
  history intact; and
- a failure after deletion rolls back pruning and all other result changes.

### Orchestrator and system tests

- the configured duration reaches persistence for a successful remote fetch;
- cache hits do not prune;
- an end-to-end CLI cache hit preserves an item older than the retention
  duration;
- source and dependency failures do not prune;
- an instance without a retention setting keeps existing behavior; and
- CLI output after a successful fetch excludes items pruned in that result's
  transaction.

## Documentation impact

Implementation will update the user-facing configuration example and explain
the distinction between:

- `ttl_minutes`, which controls cache freshness and remote-fetch frequency;
- `retention_ttl_minutes`, which controls item cleanup after a successful remote
  fetch; and
- `num_items_to_fetch`, which limits a single source request.

[ADR 0003](../../adr/0003-configurable-item-retention.md) records the accepted
architecture decision. It resolves the core design's deferred retention
decision without changing adapter write ownership or the one-database model.
