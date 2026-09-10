# Time-Series Storage Design

**Status:** Implemented
**Date:** 2026-09-09

## Summary

Cybort will add a generic persistence path for timestamped numeric and
categorical observations from future connectors such as Apple Health, server
metrics, and IoT sensors. The first connector is deliberately outside this
design. Version one retains all observations indefinitely and does not add
rollups, downsampling, Parquet, DuckDB, or route storage.

Time-series observations will live in a second canonical SQLite database,
`cybort-timeseries.sqlite3`, alongside the existing `cybort.sqlite3` control and
item database. A dedicated time-series writer serializes writes to the new
database while the orchestrator caller continues persisting ordinary connector
results to the existing database. A large time-series import therefore does not
hold the same SQLite writer lock needed by Gmail, RSS, Reddit, or GitHub
results. It may still compete with them for CPU and filesystem bandwidth.

Future time-series adapters will stream normalized observations into a
disposable SQLite spool. They will return a finalized spool reference rather
than materializing every observation as Ruby objects. Time-series persistence
will attach the spool and merge it into the canonical time-series database in
one transaction. WAL mode lets readers retain the previous committed view
until that transaction completes.

## Evidence and scale

The Apple Health export inspected during design is approximately 812 MB:

- `export.xml` is approximately 590 MB;
- `export_cda.xml` is approximately 204 MB;
- the primary export contains approximately 1.34 million `Record` elements;
- it contains approximately 706,000 metadata entries and 243,000 nested
  instantaneous-beat elements; and
- workouts and route files are structurally distinct from ordinary records.

This volume is routine for a narrow, indexed SQLite schema. It is not suitable
for the existing item pipeline, which materializes an array of Ruby objects,
groups it for duplicate validation, and performs one Ruby-level upsert call per
item. Streaming into a disk-backed spool bounds memory independently of export
size and makes the canonical merge set-oriented.

The inspected Apple XML records do not expose a stable HealthKit UUID. A future
Apple Health connector must therefore design deterministic source record keys
from the complete normalized record identity and explicitly define how exact
duplicate records are represented. That identity problem belongs to the
connector design, not this storage substrate.

## Goals

- Store timestamped numeric points and numeric or categorical intervals in a
  compact, queryable schema.
- Preserve adapter ownership boundaries: adapters never write canonical
  persistence files or issue canonical SQL.
- Bound adapter memory usage for arbitrarily large source snapshots.
- Prevent time-series commits from delaying writes to the existing item
  database.
- Serialize writes within each SQLite file instead of relying on lock races and
  retries.
- Support both append/upsert batches and complete per-instance snapshots.
- Make repeated imports idempotent through stable import and record keys.
- Keep future cross-source time-window queries straightforward.
- Preserve source success, synchronization state, and observation changes
  across process failures with an explicit recoverable commit protocol.

## Non-goals

- An Apple Health, server-monitoring, or IoT connector.
- Parsing Apple XML, CDA, GPX, or any specific wire format.
- Real-time ingestion or guaranteed low-latency publication.
- Automatic retention, downsampling, aggregation, or tiering. Version one
  retains observations forever.
- Parquet generation or DuckDB integration.
- Geospatial route-point storage, clinical-document storage, arbitrary blobs,
  or high-cardinality source metadata preservation.
- A dashboard, charting API, anomaly detector, or alert generator.
- Globally atomic read snapshots spanning both canonical databases. Dashboard
  and analysis reads may observe adjacent committed states.
- Concurrent writers within the time-series database.

## Storage topology

An installation contains two canonical databases:

```text
INSTALLATION_ROOT/
  cybort.sqlite3             control plane, items, fetch history
  cybort-timeseries.sqlite3  series, observations, import receipts
```

Both use foreign keys, a 5,000 ms busy timeout, and WAL journal mode. The main
database remains authoritative for configured adapter instances, scheduling
freshness, synchronization state, and user-visible fetch history. The
time-series database is authoritative for series definitions, observations,
and durable time-series import receipts.

The application never opens one canonical database per source. Per-source
files would make migrations, backup, discovery, and cross-source querying
proportional to the number of configured sources. With exactly two known
databases, an analysis connection can attach the time-series database to the
main database or query them separately without dynamic fan-out.

SQLite does not provide a globally atomic commit across multiple attached WAL
databases. Cybort will not claim that property. Instead, writes follow a
recoverable two-stage protocol described below.

## Domain model

### Series

A series describes one logical measurement channel. It has:

- an integer database ID;
- the configured adapter instance ID;
- a connector-defined stable `series_key` within that instance;
- a stable `metric_key`, such as `heart_rate`, `cpu_utilization`, or
  `temperature`;
- a `value_type` of `numeric` or `categorical`;
- an optional canonical unit for numeric values;
- a bounded JSON object of low-cardinality dimensions; and
- creation and update timestamps represented as integer UTC microseconds.

The pair `(adapter_instance_id, series_key)` is unique. A connector must use a
new `series_key` if a channel's value type or canonical unit changes. Dimensions
are descriptive; fields needed by common filters should eventually be promoted
to typed columns instead of indexed inside JSON.

`metric_key`, `value_type`, and canonical unit are immutable after a series is
created; a connector must choose a new `series_key` to change them. Dimensions
are replaceable descriptive metadata. An upsert changes `updated_at_us` only
when the normalized dimensions JSON changes, so retries do not create false
mutation history.

### Observation

One table represents points and intervals. Each observation has:

- a `series_id`;
- a connector-defined stable `source_record_key` within the series;
- `observed_at_us`, the point time or interval start in UTC microseconds;
- optional `ended_at_us`, which must not precede the start;
- exactly one of `numeric_value` or `categorical_value`, matching the series
  value type;
- `ingested_at_us`, assigned from one persistence clock reading for the import;
  and
- bounded source metadata JSON for information not used in common predicates.

The primary identity is `(series_id, source_record_key)`. An index on
`(series_id, observed_at_us, source_record_key)` supports the dominant query:
one or more known series over a time window. A second index on
`(observed_at_us, series_id, source_record_key)` supports bounded cross-series
windows. The benchmark records both query plans because every index increases
import cost and database size.

SQLite `INTEGER` UTC microseconds are used for hot timestamps rather than ISO
8601 text. This representation sorts numerically, is compact, preserves
subsecond precision, and avoids parsing strings in range predicates. Connector
normalization retains any source timezone or offset only when it has semantic
value, in bounded metadata.

Numeric values must be finite. Boolean, object, array, NaN, and infinite values
are rejected. Categorical values are nonblank UTF-8 strings of at most 1,024
bytes. `series_key`, `metric_key`, canonical unit, and `source_record_key` are
limited to 256, 128, 64, and 512 UTF-8 bytes respectively and reject C0
controls and DEL. An `import_key` is a nonblank UTF-8 string of at most 256
bytes under the same control-character rule. Dimensions are a flat object of at most 32 entries with
128-byte keys and scalar boolean, integer, finite-float, or strings of at most
512 bytes; their encoded JSON is limited to 16 KiB. Observation, import, and
receipt metadata use JSON-compatible values with at most eight container
levels, 128-byte object keys, 4 KiB strings, 256 elements per container, and a
64 KiB encoded limit. These validation bounds apply in both the spool and
canonical persistence boundary.

### Import receipt

Each canonical time-series commit records:

- a connector-supplied stable `import_key`, unique within the instance;
- the instance ID;
- import mode (`append` or `snapshot`);
- source and completion timestamps;
- imported and total stored observation and series counts;
- the next connector synchronization state;
- bounded diagnostic metadata; and
- whether the corresponding main-database acknowledgement is pending or
  complete.

The canonical database rejects reuse of an `import_key` with different
contents. Reuse with the same content returns the existing receipt without
rewriting observations. Import keys must therefore identify the acquired
source version or page, not a random attempt.

Both source start and completion timestamps are durable receipt fields so a
fresh process can reconstruct required fetch history without inventing timing
data. The time-series database also maintains one small instance-state row containing
the latest import key and total stored series and observation counts. It is
updated in the same transaction as every import, so planning and cached status
do not scan a million-row observation table. Import receipts distinguish counts
present in that import from total counts stored after it.

## Disposable spool

`TimeSeriesSpoolWriter` owns the transient SQLite schema and is supplied to a
time-series adapter. The adapter interacts with domain methods rather than SQL:

```ruby
spool = spool_factory.open(
  instance_id: instance.id,
  import_key: source_version,
  import_mode: :snapshot,
  source_started_at: started_at
)

spool.register_series(
  series_key: "heart-rate",
  metric_key: "heart_rate",
  value_type: :numeric,
  canonical_unit: "count/min",
  dimensions: {}
)

spool.add_observation(
  series_key: "heart-rate",
  source_record_key: record_key,
  observed_at: start_time,
  ended_at: end_time,
  numeric_value: value,
  metadata: {}
)

artifact = spool.finalize(
  sync_state: next_sync_state,
  source_finished_at: finished_at,
  metadata: {}
)
```

The writer uses prepared statements and bounded transactions while parsing.
The disposable spool uses rollback-journal mode because it has one writer and
no concurrent reader; this avoids WAL sidecars at handoff. Those transactions
lock only the spool. `finalize` validates the manifest stored inside the spool,
closes it, changes the file to mode `0400`, streams a content digest, and returns an
immutable `TimeSeriesSpoolArtifact`. An aborted or failed fetch closes and
deletes its spool. The orchestrator owns cleanup after an artifact is returned,
including every success, failure, and shutdown path.

The spool is created in a mode-`0700` installation temporary directory with a
reserved filename prefix and mode `0600` while writable, so a
canonical import does not depend on retaining a large Ruby object graph. It is
not canonical state and need not survive a process crash; the unchanged source
can be fetched or parsed again. Once an installation-wide process lock is held,
startup removes only regular, non-symlink files with that exact reserved prefix
before creating new spools. This reclaims sensitive artifacts left by crashes.

## Time-series result contract

Time-series adapters return `TimeSeriesFetchResult`, not an item-shaped
`FetchResult`. The result carries the instance ID, start and finish times,
source-fetched flag, synchronization state, bounded metadata, optional error,
and exactly one finalized spool artifact for a successful remote fetch.
Successful cached results and failures carry no artifact. The result and
artifact are immutable after construction.

For a remote success, result start/finish times and synchronization state must
exactly match the artifact's durable manifest. The adapter registry records
each adapter's result kind. The orchestrator rejects a result whose class,
instance ID, source-fetched flag, or artifact does not match the registered
kind and planned fetch mode. This prevents malformed adapters from advancing
main state without a canonical time-series import.

## Import modes

### Append

Append mode upserts every spooled series and observation by stable identity.
Existing observations with the same keys are updated. Observations absent from
the spool remain present. This mode fits server and IoT batches and future
incremental HealthKit relays.

### Snapshot

Snapshot mode means the spool is a complete observation set for one configured
instance. In one time-series transaction, persistence:

1. validates the finalized spool and manifest;
2. attaches it through an escaped SQLite `file:` URI with
   `mode=ro&immutable=1` on a URI-enabled connection;
3. upserts its series definitions;
4. upserts its observations;
5. removes observations for the instance that are absent from the spool;
6. removes series for the instance that are absent from the spool; and
7. records the durable import receipt.

Readers in WAL mode see the previous committed snapshot until commit, then the
new complete snapshot. A parse, validation, constraint, or storage failure rolls
back the entire canonical replacement.

Snapshot is appropriate for a future manually exported Apple Health archive.
Its expensive transaction affects only the time-series database. Other
time-series imports wait in the writer queue, which is acceptable because this
system is not real-time and Apple Health is expected to be the highest-volume
source.

A finalized empty snapshot is valid and removes all observations and series for
that instance. An empty append is also valid and records the import receipt
without deleting existing observations. An unfinalized, incomplete, or invalid
spool is always a failure and never has replacement semantics.

## Orchestration and concurrency

Adapter fetch threads remain concurrent. An adapter registry entry declares a
result kind of `items` or `time_series`; existing entries default to `items`.
The registry injects a spool factory only into time-series adapters.

At the start of a run that includes a time-series adapter or has pending
time-series recovery work, the orchestrator starts one dedicated time-series
persistence worker. Collection already holds the installation lock. The worker
constructs and exclusively owns its writable SQLite connection inside its
thread; planning and query code uses a distinct read-only class whose connection
cannot invoke write APIs, and no connection object crosses threads. Writable
persistence objects record their owner thread and reject use elsewhere. Source
completion and time-series persistence receipts are represented as tagged
events:

```text
adapter workers ── source completion ──┐
                                      ├── orchestrator event loop
time-series writer ─ persistence ─────┘
```

For an item result, the orchestrator caller persists it immediately through the
existing main `Persistence` object. For a successful remote time-series result,
the caller transfers its finalized artifact to the time-series writer and
continues consuming other completion events. The writer serially imports
artifacts and publishes a success or failure receipt. The orchestrator caller
then performs the short main-database acknowledgement and queues the advisory
receipt marker back to the writer. It reports success after the marker returns
or reports success with pending-marker metadata if only that advisory write
fails.

Cached time-series results do not create a spool or enqueue a write. They return
a cached status using counts from the planning context or stored receipt.
Time-series source failures are recorded in the main database exactly like item
source failures.

The run is complete only when every configured instance has a terminal durable
status. Cleanup closes the queue, observes the writer thread, and deletes all
remaining spool artifacts without replacing an already-active source,
persistence, or cleanup exception.

This design preserves one writer per SQLite file during collection:

- the orchestrator caller is the only main-database writer;
- the dedicated time-series worker is the only time-series-database writer;
- item and time-series commits may proceed simultaneously because they lock
  different files; and
- time-series commits are serialized rather than competing through
  `busy_timeout`.

Time-series commands and events carry a process-local command ID, instance ID,
import key, and phase so current-run imports cannot be confused with startup
reconciliation. Pending purge intents are reconciled first by instance ID;
pending import receipts follow deterministically by instance ID, source finish
time, and import key. A reconciliation failure prevents planning and source
execution only for each affected configured instance ID, regardless of its
current result kind; unrelated sources still run.

## Cross-database commit recovery

A successful time-series fetch has two durable steps:

1. the time-series transaction publishes observations and a receipt marked
   `pending_acknowledgement`;
2. the orchestrator caller transactionally updates the main adapter's
   `last_successful_fetch` and synchronization state, inserts one fetch-history
   row keyed by the import ID, and records that import ID as acknowledged;
3. the orchestrator submits an acknowledgement command to the time-series
   worker, which marks its receipt acknowledged. This final marker is
   advisory cleanup state and is idempotent.

The time-series commit must occur first. The main database must never advance a
source cursor before the observations governed by that cursor are durable.

At startup, before source planning, the orchestrator starts the time-series
writer and reconciles any pending time-series receipts. The main
acknowledgement operation is idempotent by `(instance_id, import_key)`. If a
crash occurs after step 1, reconciliation performs step 2 and queues step 3 to
the writer. If a crash occurs after step 2 but before step 3, reconciliation
observes the existing acknowledgement and queues only step 3. No distributed
rollback is attempted.

A marker failure after steps 1 and 2 does not convert the already durable fetch
into a failed source or insert a contradictory failed fetch-history row. The
terminal source status remains successful and carries bounded
`receipt_acknowledgement_pending` metadata; the receipt remains pending for the
next startup reconciliation.

The main schema therefore gains a small acknowledgement table instead of
claiming that an attached multi-database WAL transaction is atomic.

## Query model

The time-series persistence API exposes typed queries rather than raw attached
database handles:

```ruby
series_for(instance_id: nil, metric_key: nil, after_id: nil, limit:)

observations_for(
  series_ids:,
  started_at:,
  ended_at:,
  limit:,
  order: :ascending
)
```

All range queries require a bounded time interval and result limit in version
one. `series_for` requires a limit of 1 through 1,000. `observations_for`
deduplicates and accepts 1 through 500 integer series IDs and a result limit of
1 through 10,000. Queries order deterministically by observation time, series
ID, and source record key. The canonical schema carries both a series/time
index and an observation-time/series index; the benchmark records query plans
so later evidence can justify removing either write-costing index.

Future dashboards that genuinely need item/time-series joins may use a
read-only analysis connection that opens the main database and attaches the one
known time-series database. Such reads are eventually consistent across the two
files. If a feature later requires a coordinated snapshot, it must define a
shared committed import watermark rather than assuming SQLite provides one
across WAL databases.

## Retention and derived data

Version one retains all time-series observations forever, matching the current
product decision. It does not create rollup tables or background compaction.
The schema records observation and ingestion timestamps so a future ADR can add
source-specific retention and downsampling without changing source identity.

Derived alerts, summaries, or action items are ordinary Cybort items that
reference a metric and time window. Raw observations are not duplicated into
the `items` table merely to make them visible to the existing CLI.

## Backup, purge, and lifecycle

The low-level SQLite backup methods each cover one database, while the
implemented installation backup workflow covers both canonical database files
as one logical installation. The purge CLI requires collection to be stopped,
then uses SQLite backup operations for each file and records both snapshot
start/completion times plus installation backup start/completion times in a
manifest so a user cannot mistake one file for a complete backup. Backup
directories are mode `0700`; database copies and the manifest are mode `0600`.
Files and their temporary directory are fsynced before an atomic sibling rename
publishes the backup. The two backups are adjacent durable snapshots, not a
globally atomic cross-file snapshot.

Purging a time-series instance first records a durable purge intent in the main
database, then deletes that instance's observations, series, state, and import
receipts in one time-series transaction, and finally deletes the main instance
and completes the intent in one main transaction. Startup reconciliation uses
the time-series writer and finishes pending purge intents before import
receipts. Planning is blocked only for an affected instance while its purge
intent cannot be reconciled; unrelated sources continue. This ordering makes a
crash after either database commit
recoverable without allowing an old cursor to survive deleted observations.

Vacuuming and WAL checkpointing are maintenance operations, not part of every
fetch. A large import must not force main-database checkpointing. Time-series
checkpoint policy should be measured with representative fixtures before
changing SQLite defaults.

Collection, backup, purge, and reset take the same nonblocking exclusive
installation `flock` on a mode-`0600` sibling lock file. Failure to acquire it
aborts the lifecycle command instead of guessing whether collection is stopped.
Lifecycle commands are explicit operational writers and may write the
time-series database directly while holding that lock. The dedicated-writer
rule applies within a collection run, where adapter and main persistence
activity is concurrent.

## Errors and diagnostics

Errors are normalized at the responsible boundary:

- spool parsing or normalization errors are source failures;
- spool validation and canonical constraint errors are time-series persistence
  failures;
- main acknowledgement errors leave a recoverable pending receipt; and
- cleanup errors never replace an already-active source or persistence error.

Diagnostics identify the instance, phase, import mode, and bounded counts. They
must not include observation values, source metadata, Health fields, file
contents, or raw SQL. Tests assert that useful exceptions reach the user but do
not pin diagnostic prose, consistent with the accepted diagnostic-testing ADR.

## Testing strategy

Tests use small generated spools and fixtures; they do not use the personal
Apple Health export and do not contact external services.

Coverage includes:

- schema constraints and deterministic time-window ordering;
- finite numeric and categorical-value validation;
- bounded-memory spool behavior through streaming test producers;
- append idempotency and updates;
- complete snapshot replacement and rollback;
- duplicate import-key acceptance only for identical content;
- source-instance isolation;
- concurrent item persistence while a controlled time-series import is
  blocked;
- serialization of two time-series imports;
- crash-window reconciliation for both cross-database commit gaps;
- spool deletion across success, source failure, persistence failure, and
  orchestrator cleanup;
- backup manifests containing both databases; and
- complete purge recovery across both databases.

Performance tests are bounded benchmarks rather than timing-sensitive unit-test
assertions. Before enabling a high-volume connector, a local benchmark runs at
100,000 and at least 1.5 million synthetic observations and records a
high-water RSS measurement when the runtime exposes one. If only a current RSS
measurement is available, it is reported separately with its measurement kind
and never labeled as peak RSS. The benchmark also records spool size, canonical
database size, transaction duration, WAL growth, representative range-query
latency, and `EXPLAIN QUERY PLAN` output. Digests and producers remain streaming
so the measurement detects accidental whole-file or whole-result buffering. The
benchmark informs tuning but does not fail on absolute wall-clock or memory
thresholds in CI.

## Alternatives considered

### Keep all data in `cybort.sqlite3`

Rejected for version one. SQLite can store the volume, and WAL would preserve
reader concurrency, but one large time-series transaction would block ordinary
connector commits. Chunking would trade that lock for partial visibility and
more orchestration complexity.

### Accumulate all observations in RAM

Rejected. The inspected Apple export already contains more than 1.3 million
records. Ruby object overhead would make memory use several times larger than
the source, and duplicate validation would add another large allocation.

### One SQLite database per source

Rejected. It maximizes writer independence but complicates discovery,
migration, backup, attachment limits, and every cross-source query. Expected
time-series frequency does not justify that fragmentation.

### Parquet as the canonical time-series store

Deferred. Parquet and DuckDB are strong choices for immutable analytical
history, but introduce fragment manifests, compaction, correction/deletion
semantics, and additional runtime dependencies. SQLite is simpler for durable
idempotent upserts at the observed scale.

### Chunk canonical writes in the main database

Rejected as the primary solution. Smaller transactions provide writer
fairness, but need generation-based visibility and still compete with ordinary
item commits. The separate database removes that contention more directly.

## Documentation impact

The implementation changes the original invariant that one SQLite file is the
whole canonical datastore. The current implementation and project guidance
now describe the pair of canonical SQLite databases, the dedicated writer,
disposable spools, and lifecycle recovery guarantees. No user-visible
time-series configuration options exist yet, so the connector template remains
unchanged. This design remains the architectural record for the implemented
substrate; future source connectors require their own design and release gates.
