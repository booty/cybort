# ADR 0008: Independent Connector Completion

- Status: Accepted
- Date: 2026-09-08
- Supersedes: [ADR 0001](0001-persistence-storage-and-write-ownership.md)

## Context

Cybort already fetches configured adapter instances concurrently, but ADR 0001
required the orchestrator to wait for every adapter thread before persisting
any result. A slow network connector therefore delayed durable commits and
completion reports for unrelated faster connectors.

Adapter results are instance-scoped, each successful result already has its
own transaction, and a fetch run has no cross-instance transaction. The global
barrier provided no correctness benefit. SQLite should still have one
application-level writer, and adapters should remain unaware of persistence.

## Decision

Cybort retains one canonical SQLite database and orchestrator-owned,
sequential persistence. Adapter workers fetch and normalize without accessing
SQLite.

Each successfully started worker publishes one terminal completion event from
an `ensure` block. Dependency-preflight failures enter the same completion
channel as already-materialized results. The orchestrator caller consumes each
event and persists that instance immediately, one result at a time. It obtains
worker results through `Thread#value` so abnormal worker failures propagate
rather than being lost or leaving the completion consumer blocked.

Worker launch and completion consumption share a cleanup boundary. Every
started worker is observed before the run returns or raises, and cleanup does
not replace an already-active launch, worker, or persistence exception.

Completion order controls commit and human completion-report timing. The final
`RunResult.instances` array remains in configuration order, and the overall
status is computed only after every configured instance has produced a durable
status. Each successful result retains its own transaction; one source failure
does not discard another source's success.

This ADR supersedes ADR 0001 as the current persistence-coordination decision.
It retains ADR 0001's datastore, persistence ownership, transaction isolation,
and serialized-write choices while replacing only the global result barrier.

## Alternatives considered

### Keep the global barrier

Rejected. It is simple but delays durable data and feedback for reasons
unrelated to connector correctness.

### Use a dedicated writer thread

Rejected for now. A separate consumer thread would add lifecycle and exception
propagation paths while the orchestrator caller can serialize the same writes.

### Persist from adapter threads

Rejected. It would introduce concurrent SQLite callers and blur the boundary
between source collection and persistence coordination.

### Use one database connection per adapter

Rejected. Concurrent writers add locking, retry, and transaction complexity
without improving network-bound collection.

## Consequences

- A faster connector commits and reports completion without waiting for a
  slower connector.
- SQLite writes remain sequential and adapter contracts remain unchanged.
- Final result ordering remains deterministic even though commit order is not.
- A slow persistence write can delay later commits, but adapter network work
  continues and completed results wait safely in memory.
- The completion channel and worker cleanup add orchestration complexity that
  is covered by bounded concurrency and failure-path tests.
- The run still waits for all configured instances before returning its
  aggregate status.

## References

- [Design](../superpowers/specs/2026-09-08-independent-connector-completion-design.md)
- [Implementation plan](../superpowers/plans/2026-09-08-independent-connector-completion.md)
