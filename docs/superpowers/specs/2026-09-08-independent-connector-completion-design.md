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

Worker threads publish exactly one terminal event from an `ensure` block to a
Ruby `Queue`. The event identifies the instance and completed `Thread`; the
orchestrator obtains the thread's value and calls the existing `persist_result`
method immediately. Calling `Thread#value` preserves abnormal worker failures
instead of silently converting or losing them. Dependency-preflight failures
enter the queue as already-materialized results. This makes the queue a
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
   an ordinary adapter `StandardError` to the existing failure `FetchResult`
   and publishes its terminal thread event from `ensure`, even when conversion
   itself fails.
6. On the orchestrator thread, pop one event per configured instance. For a
   worker event, read `Thread#value` so abnormal termination is re-raised; then
   call `persist_result` immediately. Persistence remains strictly sequential.
7. Enclose both worker launch and completion consumption in cleanup logic that
   joins every started thread. Preserve the original launch, worker, or
   persistence exception if cleanup also observes a failed worker.
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

- Ordinary adapter `StandardError` exceptions keep their current per-instance
  conversion to a failure `FetchResult`. The worker's terminal event is
  published from `ensure`, so a failure while constructing that result cannot
  leave the orchestrator blocked on an event that will never arrive.
- Dependency failures enter the same completion path as adapter results and are
  recorded without waiting for remote workers.
- `persist_result` retains its current isolation behavior: a failure for one
  source does not discard successful results from another source.
- Worker launch and completion consumption share one protected region. Cleanup
  observes every started worker, retains the first cleanup failure, and never
  masks an already-active caller-thread exception. Existing connector deadlines
  remain the production bound on a worker that has not completed.
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

Architecture documentation must also change because ADR 0001, `AGENTS.md`, the
README, and the original core design explicitly describe the global barrier.
Implementation will add a replacement ADR that restates the retained
one-database, orchestrator-owned, sequential-write decisions; mark ADR 0001
superseded in its file and index; and annotate the core design rather than
silently rewriting its historical body.

## Verification

Regression tests will use independently releasable adapters, bounded watchdogs,
and a signaling persistence spy. They will release the second connector first,
require its write on the orchestrator caller thread while the first connector
remains blocked, and then verify final configuration order. Additional bounded
cases cover a preflight failure completing beside a gated worker, a failure
during ordinary adapter-error conversion, and cleanup after an escaped
persistence-recording failure. Diagnostic timing is asserted only through
event counts/framing, never exact prose. Existing retention assertions will
compare instance-to-policy mappings because write order is intentionally no
longer deterministic.

All test execution remains offline and is delegated to a read-only Luna agent
at medium reasoning effort under `AGENTS.md`.
