# Time-Series Storage Design

**Status:** Approved for implementation planning  
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
results to the existing database. A large time-series import therefore cannot
hold the SQLite writer lock needed by Gmail, RSS, Reddit, or GitHub results.

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

The primary identity is `(series_id, source_record_key)`. A separate index on
`(series_id, observed_at_us, source_record_key)` supports the dominant query:
one or more known series over a time window. No global time-only index is added
until a demonstrated query needs it, because every index increases import cost
and database size.

SQLite `INTEGER` UTC microseconds are used for hot timestamps rather than ISO
8601 text. This representation sorts numerically, is compact, preserves
subsecond precision, and avoids parsing strings in range predicates. Connector
normalization retains any source timezone or offset only when it has semantic
value, in bounded metadata.

Numeric values must be finite. Boolean, object, array, NaN, and infinite values
are rejected. Categorical values are nonblank UTF-8 strings of at most 1,024
bytes. `series_key`, `metric_key`, canonical unit, and `source_record_key` are
limited to 256, 128, 64, and 512 UTF-8 bytes respectively and reject C0
controls and DEL. Dimensions are a flat object of at most 32 entries with
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
- observation and series counts;
- the next connector synchronization state;
- bounded diagnostic metadata; and
- whether the corresponding main-database acknowledgement is pending or
  complete.

The canonical database rejects reuse of an `import_key` with different
contents. Reuse with the same content returns the existing receipt without
rewriting observations. Import keys must therefore identify the acquired
source version or page, not a random attempt.

## Disposable spool

`TimeSeriesSpoolWriter` owns the transient SQLite schema and is supplied to a
time-series adapter. The adapter interacts with domain methods rather than SQL:

```ruby
spool = spool_factory.open(
  instance_id: instance.id,
  import_key: source_version,
  import_mode: :snapshot
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
Those transactions lock only the disposable spool. `finalize` validates the
manifest, closes the database, computes a content digest, and returns an
immutable `TimeSeriesSpoolArtifact`. An aborted or failed fetch closes and
deletes its spool. The orchestrator owns cleanup after an artifact is returned,
including every success, failure, and shutdown path.

The spool is created in the installation's temporary area when possible so a
canonical import does not depend on retaining a large Ruby object graph. It is
not canonical state and need not survive a process crash; the unchanged source
can be fetched or parsed again.

## Time-series result contract

Time-series adapters return `TimeSeriesFetchResult`, not an item-shaped
`FetchResult`. The result carries the instance ID, start and finish times,
source-fetched flag, synchronization state, bounded metadata, optional error,
and exactly one finalized spool artifact for a successful remote fetch.
Successful cached results and failures carry no artifact. The result and
artifact are immutable after construction.

The adapter registry records each adapter's result kind. The orchestrator
rejects a result whose class, instance ID, source-fetched flag, or artifact does
not match the registered kind and planned fetch mode. This prevents a malformed
adapter from advancing main state without a canonical time-series import.

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
2. attaches it read-only;
3. upserts its series definitions;
4. upserts its observations;
5. removes observations for the instance that are absent from the spool;
6. removes now-unused series for the instance; and
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

At the start of a run that includes a time-series adapter, the orchestrator
starts one dedicated time-series persistence worker. Source completion and
time-series persistence receipts are represented as tagged events:

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
then performs the short main-database acknowledgement and reports that source's
terminal status.

Cached time-series results do not create a spool or enqueue a write. They return
a cached status using counts from the planning context or stored receipt.
Time-series source failures are recorded in the main database exactly like item
source failures.

The run is complete only when every configured instance has a terminal durable
status. Cleanup closes the queue, observes the writer thread, and deletes all
remaining spool artifacts without replacing an already-active source,
persistence, or cleanup exception.

This design preserves one writer per SQLite file:

- the orchestrator caller is the only main-database writer;
- the dedicated time-series worker is the only time-series-database writer;
- item and time-series commits may proceed simultaneously because they lock
  different files; and
- time-series commits are serialized rather than competing through
  `busy_timeout`.

## Cross-database commit recovery

A successful time-series fetch has two durable steps:

1. the time-series transaction publishes observations and a receipt marked
   `pending_acknowledgement`;
2. the orchestrator caller transactionally updates the main adapter's
   `last_successful_fetch` and synchronization state, inserts one fetch-history
   row keyed by the import ID, and records that import ID as acknowledged;
3. the time-series worker marks its receipt acknowledged. This final marker is
   advisory cleanup state and is idempotent.

The time-series commit must occur first. The main database must never advance a
source cursor before the observations governed by that cursor are durable.

At startup, before source planning, the orchestrator reconciles any pending
time-series receipts. The main acknowledgement operation is idempotent by
`(instance_id, import_key)`. If a crash occurs after step 1, reconciliation
performs step 2. If a crash occurs after step 2 but before step 3,
reconciliation observes the existing acknowledgement and only completes step
3. No distributed rollback is attempted.

The main schema therefore gains a small acknowledgement table instead of
claiming that an attached multi-database WAL transaction is atomic.

## Query model

The time-series persistence API exposes typed queries rather than raw attached
database handles:

```ruby
series_for(instance_id: nil, metric_key: nil)

observations_for(
  series_ids:,
  started_at:,
  ended_at:,
  limit:,
  order: :ascending
)
```

All range queries require a bounded time interval and result limit in version
one. They order deterministically by observation time, series ID, and source
record key.

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

The existing SQLite backup command covers only the main database and is not a
complete installation backup after this feature. Before implementation is
complete, backup and reset workflows must treat the two canonical database
files as one logical installation. A consistent live backup acquires the
application's two writer gates in a fixed order, checkpoints as needed, and
uses SQLite backup operations for each file. It records a manifest so a user
cannot mistake one file for a complete backup.

Purging a time-series instance deletes its observations, unused series, import
receipts, and main acknowledgement/control rows. Because the files cannot share
a foreign key or atomic transaction, purge uses the same idempotent recovery
principle as imports and documents whether a partial purge remains pending.

Vacuuming and WAL checkpointing are maintenance operations, not part of every
fetch. A large import must not force main-database checkpointing. Time-series
checkpoint policy should be measured with representative fixtures before
changing SQLite defaults.

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
assertions. Before enabling a high-volume connector, a local benchmark imports
at least 1.5 million synthetic observations and records spool size, canonical
database size, transaction duration, WAL growth, and representative range-query
latency. The benchmark informs tuning but does not fail on absolute wall-clock
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

Implementation changes the current invariant that one SQLite file is the whole
canonical datastore. When the implementation lands, update `AGENTS.md`, the
README installation/backup documentation, and the configuration template for
any user-visible time-series options. Until then, code and the existing project
invariant continue to describe actual behavior, while this approved spec and
ADR describe the intended architecture.
