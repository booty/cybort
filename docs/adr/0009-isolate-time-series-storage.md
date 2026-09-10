# ADR 0009: Isolate Time-Series Storage

- Status: Accepted; implementation pending
- Date: 2026-09-09
- Related: [ADR 0008](0008-independent-connector-completion.md)

## Context

Cybort's item connectors fetch concurrently but persist sequentially through
one SQLite connection. That is appropriate for bounded email, notification,
and feed results. A time-series source may produce millions of observations in
one fetch. The inspected Apple Health export contains approximately 1.34
million primary records and is approximately 812 MB including related files.

SQLite WAL mode permits readers alongside a writer but only one writer per
database file. Importing a large time-series result into the existing database
would therefore delay unrelated item commits. Materializing the same result as
Ruby objects would also impose unnecessary memory cost.

## Decision

Cybort will use two canonical SQLite databases within one installation:

- `cybort.sqlite3` for configured instances, synchronization state, fetch
  history, and ordinary items; and
- `cybort-timeseries.sqlite3` for series, observations, and durable import
  receipts.

Future time-series adapters will stream normalized data into disposable SQLite
spools through an injected, persistence-owned interface. A dedicated
time-series writer will serialize canonical time-series imports while the
orchestrator caller remains the only writer to the main database. The two
writers may operate concurrently because they lock different files.

Canonical time-series imports are set-oriented and transactional. Append mode
upserts the spool without deleting absent rows. Snapshot mode atomically
replaces one instance's observation set. Version one retains all observations
and adds no rollups, downsampling, Parquet, DuckDB, or source connector.

Because attached SQLite databases in WAL mode do not provide a globally atomic
cross-file commit, time-series persistence commits observations and a durable
receipt first. The orchestrator then acknowledges that receipt and advances
source state in the main database. Startup reconciliation idempotently repairs
either crash window. Main state must never advance before governed
observations are durable.

This ADR extends ADR 0008. Ordinary item results retain completion-ordered,
orchestrator-owned sequential persistence. Time-series results use their own
serialized writer so they cannot block the main database's writer lock.

## Consequences

- Large time-series imports do not delay ordinary connector commits.
- Ruby memory remains bounded by streaming to a disk-backed spool.
- Time-window queries remain ordinary indexed SQLite queries.
- Cross-source analysis needs to open or attach two known databases rather than
  one, and does not receive a globally atomic snapshot across them.
- Backup, purge, reset, and recovery workflows must treat both files as one
  logical installation.
- Cross-database success requires an explicit receipt and reconciliation
  protocol.
- Time-series imports are serialized with each other; this is acceptable for
  the non-real-time workload.
- A future move of cold immutable data to Parquet requires a separate measured
  decision.

## Alternatives

### One SQLite database

Rejected because a high-volume time-series transaction would hold the same
writer lock required by small item commits.

### One SQLite database per source

Rejected because it makes schema management, backup, and cross-source querying
scale with the number of sources.

### Parquet and DuckDB from the start

Deferred because immutable-file compaction and mutation semantics add
complexity that is not justified by the current volume.

### Full in-memory accumulation

Rejected because the observed Apple Health scale would create an unnecessarily
large Ruby object graph.

## Reference

- [Time-series storage design](../superpowers/specs/2026-09-09-time-series-storage-design.md)

