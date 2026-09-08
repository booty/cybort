# Independent Connector Completion Design

**Status:** Approved design; implementation pending

**Date:** 2026-09-08

**Implementation:** [Task plan](../plans/2026-09-08-independent-connector-completion.md)

## Problem

Cybort starts one adapter thread per configured instance, so remote network
work already overlaps. The orchestrator then waits for every adapter thread
before it persists any result. A slow connector therefore delays the durable
commit and completion report of every faster connector, even though results
are instance-scoped and no transaction spans instances.

This barrier is unnecessary. The existing persistence contract already treats
each adapter result independently, and the shared SQLite database only needs
writes to remain serialized.

## Decision

Persist each adapter result as soon as that adapter finishes. Keep adapter
fetches concurrent and keep persistence calls sequential on the orchestrator's
calling thread.

Worker threads place exactly one `[instance_id, FetchResult]` pair on a Ruby
`Queue`. The orchestrator consumes one pair per configured instance and calls
the existing `persist_result` method immediately. This makes the queue a
completion channel, not a database writer: adapters remain unaware of SQLite,
and only the orchestrator calls `Persistence`.

No adapter interface, persistence interface, schema, or configuration changes.
The only production-code change belongs in `lib/cybort/orchestrator.rb`.

## Execution flow

The revised run flow is:

1. Validate all source configuration.
2. Apply startup hard expiry, capture planning contexts, freeze fetch plans,
   resolve dependencies, build adapters, and register instances as today.
3. Create a completion queue.
4. Add dependency-preflight failures to the queue because those instances are
   already complete.
5. Start one worker thread for every remaining instance. Each worker converts
   an adapter exception to the existing failure `FetchResult`, then pushes its
   single result to the queue.
6. On the orchestrator thread, pop one result per configured instance and call
   `persist_result` immediately. These calls remain strictly sequential.
7. Join worker threads in an `ensure` block so an unexpected persistence error
   cannot leave unobserved threads behind.
8. Assemble `RunResult.instances` in configuration order, independent of
   completion order, preserving the public JSON result contract.

Start diagnostics remain emitted when each remote worker is launched.
Completion diagnostics remain emitted by `persist_result`, after that
instance's successful result or failure record is durable. Tests must verify
completion and persistence behavior without asserting exact diagnostic prose.

## Ordering and independence

Completion order controls commit order and human diagnostic timing. It does not
control final result ordering: `RunResult.instances` remains in configuration
order so JSON consumers do not receive nondeterministic arrays.

A slow adapter cannot delay a faster adapter's commit. A slow SQLite write can
delay later commits, because SQLite remains a single-writer resource, but it
does not stop adapter threads from fetching and placing completed results on
the queue.

The run still returns only after every configured instance has produced and
persisted a status. This final aggregation is necessary to compute the overall
success/partial-failure status; it is not a pre-commit barrier.

## Failure and shutdown behavior

- Adapter exceptions keep their current per-instance conversion to a failure
  `FetchResult` and are queued exactly once.
- Dependency failures enter the same completion path as adapter results and are
  recorded without waiting for remote workers.
- `persist_result` retains its current isolation behavior: a failure for one
  source does not discard successful results from another source.
- Worker threads are joined in `ensure`. Existing connector deadlines remain
  the bound on a thread that has not completed.
- An unexpected failure that escapes `persist_result` continues to abort the
  overall run after worker cleanup; broadening persistence recovery is outside
  this change.

## Alternatives considered

### Keep the global barrier

Rejected. It is simple, but it delays durable data and completion feedback for
reasons unrelated to connector correctness.

### Dedicated writer thread

Viable but unnecessary. A second queue consumer thread would introduce writer
lifecycle and exception propagation while the orchestrator's existing calling
thread can perform the same serialized writes.

### Persist from adapter threads

Rejected. It would create concurrent SQLite callers and blur the established
boundary that adapters fetch and normalize while the orchestrator owns result
persistence.

### One SQLite connection per adapter

Rejected. Concurrent writers add locking, busy handling, and transaction
coordination without improving the network-bound part of collection.

## Scope and documentation impact

Production and behavioral test changes are limited to:

- `lib/cybort/orchestrator.rb`
- `test/orchestrator_test.rb`

Architecture documentation must also change because ADR 0001, `AGENTS.md`, and
the README explicitly describe the global barrier. Implementation will add a
replacement ADR that restates the retained one-database, orchestrator-owned,
sequential-write decisions while superseding only the wait-for-all policy.

## Verification

The regression test will use independently releasable adapters and a signaling
persistence spy. It will release the second connector first and require its
write to occur while the first connector remains blocked. It will then release
the first connector and verify both results are returned in configuration
order. Existing partial-failure, retention, hard-expiry, and result-identity
tests continue to cover their contracts.

All test execution remains offline and is delegated to a read-only Luna agent
at medium reasoning effort under `AGENTS.md`.
