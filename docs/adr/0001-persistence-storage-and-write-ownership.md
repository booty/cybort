# ADR 0001: Persistence Storage and Write Ownership

- Status: Accepted
- Date: 2026-08-16

## Context

Cybort collects items from multiple configured adapter instances, such as Gmail
accounts, Slack workspaces, RSS feeds, and GitHub accounts. Adapter instances
must be fetched concurrently, while fetched data must be persisted safely and
remain useful for cached reads and cross-source queries.

The persistence decision has two separate parts:

1. the durable storage format; and
2. which component owns the write operation.

The application is a single-user, local application. It does not require
distributed storage or a transaction spanning every adapter instance in a
fetch run. A successful adapter result should be retainable even when another
adapter fails.

## Decisions

### 1. Use one SQLite database

Cybort will use one SQLite database as its primary persistence store. The
database will contain data from all adapter instances, along with the metadata
needed to track fetches and synchronization state.

The database is the canonical store. JSON or JSONL may be supported later as an
export or inspection format, but will not be the primary mutable datastore.

Each adapter instance may be persisted independently. A fetch run does not
need a single transaction covering all adapter instances.

### 2. Adapters fetch and return results; the orchestrator persists them

Adapter threads will fetch and normalize source data, then return a structured
result to the orchestrator. The orchestrator waits for all adapter threads to
finish, then processes their results sequentially through a shared
`Persistence` service.

The `Persistence` service owns SQLite-specific behavior, including schema
access, upserts, transactions, synchronization-state updates, and fetch-history
records. The orchestrator owns run coordination and completion reporting; it
does not construct SQL directly.

Successful results and failures are handled independently. A successful result
is persisted even if another adapter instance failed. Each successful adapter
result is written in its own transaction, including its items, synchronization
state, and successful fetch record.

## Alternatives considered

### Multiple SQLite databases

Rejected as the primary design.

Separate databases per adapter or adapter instance would provide source
isolation, but that isolation is not required for this application. It would
also make common operations more complicated:

- cross-source queries would require attaching databases or merging results in
  application code;
- schema migrations would need to be applied to multiple files;
- backups, restores, integrity checks, and freshness reporting would span
  multiple databases; and
- shared metadata and future cross-source features would need another storage
  mechanism or duplicated tables.

This decision is not based on a need for cross-database atomicity. Cybort does
not require a transaction spanning all adapter databases. The issue is that
multiple databases add operational and query complexity without providing a
benefit that the application currently needs.

### JSON or JSONL files per adapter instance

Rejected as the primary datastore.

JSON and JSONL are human-readable and would make very small prototypes easy to
inspect. They are less suitable as the canonical mutable store because Cybort
would need to implement more of the behavior SQLite already provides:

- indexed lookup and ordering;
- idempotent upserts and deduplication;
- transactional updates to items and fetch metadata;
- safe handling of interrupted writes;
- retention and cleanup; and
- efficient cross-source queries.

JSONL remains a reasonable future export or append-oriented ingestion format.

### One JSON file per item

Rejected. This would make the filesystem act as an index, but would create a
large number of files for sources such as Gmail and make querying, metadata
updates, cleanup, and backup management unnecessarily cumbersome.

### Adapters write directly to persistence

Rejected as the default ownership model, though adapters may use shared
persistence methods if a future implementation has a strong reason to do so.

Having adapters return results keeps source-fetching code separate from SQLite
coordination and gives the orchestrator one consistent place to handle success,
failure, and completion. It also avoids concurrent application-level database
writes when sequential persistence is already fast enough.

This rejection is not because an adapter calling a shared method such as
`Persistence.write_item_to_storage` would duplicate storage logic. The concern
is ownership and coordination: the shared `Persistence` service should remain
the owner of storage behavior, while adapters remain responsible primarily for
fetching and normalization.

### A queue and dedicated writer thread

Rejected for the initial implementation. A queue would allow results to be
persisted as soon as each adapter finishes, but it introduces another thread,
queue lifecycle, shutdown behavior, and error-propagation path. The expected
number of adapter instances and item sizes do not justify that complexity.

If waiting for all fetches before writing becomes undesirable, a queue and
dedicated writer can be added without changing the adapter or SQLite model.

### Concurrent writes from adapter threads

Rejected for the initial implementation. Multiple SQLite connections could be
made to work with appropriate locking and retry behavior, but concurrent writes
provide no meaningful performance benefit for the expected workload. Sequential
writes are simpler to reason about and test.

### One global transaction for the entire fetch run

Rejected. Cybort does not need all adapter instances to succeed or fail as one
unit. Independent per-adapter transactions allow successful sources to remain
fresh when another source is unavailable.

## Consequences

### Positive consequences

- One database simplifies querying, migrations, backup, and integrity checks.
- Adapter fetches remain concurrent, while persistence remains straightforward.
- A single shared service centralizes SQLite behavior.
- Partial success is preserved naturally.
- Each adapter result can be committed atomically without requiring global ACID
  behavior.
- The initial implementation avoids a queue, writer thread, and application-level
  write locking.

### Negative consequences

- Successful results are held in memory until all adapter threads finish.
- A slow adapter delays persistence of faster adapters until the fetch phase
  completes.
- A process failure before the persistence phase may require successful sources
  to be fetched again.
- SQLite remains a single-writer datastore, so unusually large write batches
  could eventually require batching or a queue.

These are acceptable for the initial single-user workload. The persistence
interface should be kept batch-oriented so that a queue or streaming writer can
be introduced later without changing adapter contracts.

## Implementation outline

The initial flow is:

1. Load and validate adapter-instance configuration.
2. Start one thread per configured adapter instance.
3. Each thread fetches and normalizes data, returning either a success result or
   an error.
4. Wait for all threads to complete.
5. For each result, call the shared `Persistence` service sequentially.
6. Commit one transaction per successful adapter result; record failures
   independently.
7. Report whether the overall run succeeded or completed with partial failures.

The persistence API should prefer a batch operation such as
`write_fetch_result(instance_id:, items:, sync_state:, metadata:)` over opening a
transaction for every individual item.

