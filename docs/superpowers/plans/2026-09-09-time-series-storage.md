# Time-Series Storage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a bounded-memory, separately locked SQLite persistence path for generic time-series observations without implementing a source connector.

**Architecture:** Future time-series adapters stream into disposable SQLite spools and return `TimeSeriesFetchResult` objects. One dedicated writer serializes spool imports into `cybort-timeseries.sqlite3` while the orchestrator caller continues writing ordinary results to `cybort.sqlite3`; durable receipts reconcile the unavoidable cross-database commit gap.

**Tech Stack:** Ruby 4.0.1, `sqlite3`, JSON, Minitest, Ruby threads and queues

**Spec:** `docs/superpowers/specs/2026-09-09-time-series-storage-design.md`

## Global Constraints

- Do not implement or register an Apple Health, server-monitoring, or IoT connector.
- The canonical files are exactly `cybort.sqlite3` and `cybort-timeseries.sqlite3` inside one installation root.
- Both canonical databases use foreign keys, a 5,000 ms busy timeout, and WAL journal mode.
- Version one retains observations forever and adds no retention configuration, rollups, downsampling, Parquet, DuckDB, clinical-document storage, route storage, or arbitrary blobs.
- Adapter workers never write either canonical database or issue canonical SQL.
- The orchestrator caller remains the only main-database writer; one dedicated worker is the only time-series-database writer.
- Store observation times as integer UTC microseconds and reject non-finite numeric values.
- A result is either item-shaped or time-series-shaped according to its registry entry; existing adapters default to `items`.
- Tests use generated local fixtures and injected collaborators and must not read the personal Apple export or contact external services.
- Assert diagnostic facts and exception visibility, not exact diagnostic prose.
- Add no runtime gem unless a separately approved design changes this constraint.
- Run test commands through a Luna-medium read-only subagent as required by `AGENTS.md`.

---

## File map

### New production files

- `lib/cybort/time_series_json.rb` — bounded JSON-compatible value validation.
- `lib/cybort/time_series_spool_artifact.rb` — immutable finalized-spool descriptor.
- `lib/cybort/time_series_fetch_result.rb` — result contract for cached, failed, and remote time-series fetches.
- `lib/cybort/time_series_spool.rb` — disposable schema, factory, streaming writer, and cleanup.
- `lib/cybort/time_series_schema.rb` — canonical time-series schema and migration version.
- `lib/cybort/time_series_import_receipt.rb` — immutable canonical-import receipt.
- `lib/cybort/time_series_persistence.rb` — canonical import, query, receipt, and purge boundary.
- `lib/cybort/time_series_writer.rb` — one queue-backed canonical writer worker.
- `lib/cybort/time_series_reconciler.rb` — idempotent cross-database acknowledgement recovery through the writer.
- `lib/cybort/installation_backup.rb` — two-database backup directory plus manifest.
- `script/benchmark_time_series.rb` — opt-in synthetic 1.5-million-observation benchmark.

### Modified production files

- `lib/cybort.rb` — load the new components in dependency order.
- `lib/cybort/schema.rb` — add main-database time-series acknowledgements and bump the schema version.
- `lib/cybort/persistence.rb` — acknowledge imports and broaden purge support.
- `lib/cybort/adapter_registry.rb` — declare and expose adapter result kinds.
- `lib/cybort/orchestrator.rb` — route time-series results through the dedicated writer and reconciliation flow.
- `lib/cybort/installer.rb` — initialize both canonical databases.
- `lib/cybort/cli.rb` — construct both persistence services and back up/purge both stores.
- `AGENTS.md`, `README.md`, `docs/adr/README.md`, and `docs/adr/0009-isolate-time-series-storage.md` — record implemented behavior and operations.
- `docs/LEARNINGS.md` — record measured benchmark facts only after running the benchmark.

### New tests

- `test/time_series_json_test.rb`
- `test/time_series_fetch_result_test.rb`
- `test/time_series_spool_test.rb`
- `test/time_series_persistence_test.rb`
- `test/time_series_writer_test.rb`
- `test/time_series_reconciler_test.rb`
- `test/installation_backup_test.rb`
- `test/system/time_series_orchestration_system_test.rb`

### Modified tests

- `test/adapter_registry_test.rb`
- `test/persistence_test.rb`
- `test/orchestrator_test.rb`
- `test/installer_test.rb`
- `test/cli_test.rb`
- `test/cybort_boot_test.rb`

---

### Task 1: Define bounded values, artifacts, results, and registry kinds

**Files:**
- Create: `lib/cybort/time_series_json.rb`
- Create: `lib/cybort/time_series_spool_artifact.rb`
- Create: `lib/cybort/time_series_fetch_result.rb`
- Create: `test/time_series_json_test.rb`
- Create: `test/time_series_fetch_result_test.rb`
- Modify: `lib/cybort/adapter_registry.rb`
- Modify: `lib/cybort.rb`
- Modify: `test/adapter_registry_test.rb`
- Modify: `test/cybort_boot_test.rb`

**Interfaces:**
- Produces: `Cybort::TimeSeriesJSON.validate_dimensions!(value)` and `validate_metadata!(value)`.
- Produces: immutable `TimeSeriesSpoolArtifact` readers for `path`, `instance_id`, `import_key`, `import_mode`, `digest`, `series_count`, `observation_count`, `sync_state`, `source_finished_at`, and `metadata`.
- Produces: `TimeSeriesFetchResult.success`, `.cached`, and `.failure`, plus `success?` and `failure?`.
- Produces: `AdapterRegistry#result_kind_for(instance)` returning `:items` or `:time_series`.

- [ ] **Step 1: Write failing bounded-JSON and result-contract tests**

Cover finite/scalar dimensions, encoded size, depth, collection-size, control-character and byte limits. Cover these result invariants in one focused test per constructor:

```ruby
File.write(spool_path, "fixture")
File.chmod(0o600, spool_path)
artifact = Cybort::TimeSeriesSpoolArtifact.new(
  path: spool_path,
  instance_id: "sensor",
  import_key: "page-42",
  import_mode: :append,
  digest: "a" * 64,
  series_count: 1,
  observation_count: 2,
  sync_state: { cursor: "next" },
  source_finished_at: Time.utc(2026, 9, 9, 12),
  metadata: {}
)
result = Cybort::TimeSeriesFetchResult.success(
  instance_id: "sensor",
  artifact: artifact,
  sync_state: { cursor: "next" },
  started_at: Time.utc(2026, 9, 9, 11, 59),
  finished_at: Time.utc(2026, 9, 9, 12),
  metadata: {},
  source_fetched: true
)

assert result.success?
assert_same artifact, result.artifact
assert_raises(ArgumentError) do
  Cybort::TimeSeriesFetchResult.cached(
    instance_id: "sensor", artifact: artifact,
    sync_state: {}, started_at: result.started_at,
    finished_at: result.finished_at, metadata: {}, observation_count: 2
  )
end
```

Test that nested result metadata is defensively copied and frozen, a remote
success requires a matching finalized artifact, cached/failure results forbid
artifacts, import modes are exactly `:append` or `:snapshot`, counts are
nonnegative integers, digests are 64 lowercase hexadecimal characters, and all
specified byte limits from the spec are enforced.

- [ ] **Step 2: Run the focused tests and confirm the missing constants fail**

Run through Luna-medium:

```bash
bundle exec ruby -Itest test/time_series_json_test.rb
bundle exec ruby -Itest test/time_series_fetch_result_test.rb
```

Expected: both commands fail because the new constants are undefined.

- [ ] **Step 3: Implement the bounded value and result objects**

Use one recursive validator with separate profiles:

```ruby
module Cybort
  module TimeSeriesJSON
    DIMENSION_LIMITS = {
      encoded_bytes: 16 * 1024, depth: 1, entries: 32,
      key_bytes: 128, string_bytes: 512
    }.freeze
    METADATA_LIMITS = {
      encoded_bytes: 64 * 1024, depth: 8, entries: 256,
      key_bytes: 128, string_bytes: 4 * 1024
    }.freeze

    module_function

    def validate_dimensions!(value)
      validate_object!(value, limits: DIMENSION_LIMITS, flat: true)
    end

    def validate_metadata!(value)
      validate_object!(value, limits: METADATA_LIMITS, flat: false)
    end
  end
end
```

Reject symbols as stored values, non-string object keys, non-finite floats,
and encoded JSON over the relevant limit. Return a deeply copied, deeply frozen
value so callers cannot mutate validated state.

Make `TimeSeriesSpoolArtifact` accept only an absolute existing regular file
with mode no broader than `0600`; do not read its contents in the value object.
The spool writer in Task 2 is responsible for constructing it.

Implement `TimeSeriesFetchResult` as an immutable class rather than adding
optional time-series fields to `FetchResult`. Its cached constructor accepts an
`observation_count` and `series_count` but no artifact. Its failure constructor
sets both counts to zero and has no synchronization state.

- [ ] **Step 4: Add registry result kinds**

Extend `AdapterRegistry::Entry` and `register`:

```ruby
RESULT_KINDS = %i[items time_series].freeze

def register(name, adapter_factory, dependencies: [], validate_configuration: nil,
             display_name: nil, item_noun: "items", result_kind: :items)
  raise ArgumentError, "invalid adapter result kind" unless RESULT_KINDS.include?(result_kind)
  # existing registration plus result_kind
end

def result_kind_for(instance)
  @adapters.fetch(instance.adapter).result_kind
end
```

Test the default, explicit time-series registration, invalid kinds, and that all
built-in adapters remain `:items`. Load the new constants from `lib/cybort.rb`
before the registry.

- [ ] **Step 5: Run focused tests**

Run through Luna-medium:

```bash
bundle exec ruby -Itest test/time_series_json_test.rb
bundle exec ruby -Itest test/time_series_fetch_result_test.rb
bundle exec ruby -Itest test/adapter_registry_test.rb
bundle exec ruby -Itest test/cybort_boot_test.rb
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/cybort.rb lib/cybort/adapter_registry.rb \
  lib/cybort/time_series_json.rb lib/cybort/time_series_spool_artifact.rb \
  lib/cybort/time_series_fetch_result.rb test/adapter_registry_test.rb \
  test/cybort_boot_test.rb test/time_series_json_test.rb \
  test/time_series_fetch_result_test.rb
git commit -m "Add time-series result contracts"
```

---

### Task 2: Build the streaming disposable spool

**Files:**
- Create: `lib/cybort/time_series_spool.rb`
- Create: `test/time_series_spool_test.rb`
- Modify: `lib/cybort.rb`

**Interfaces:**
- Consumes: `TimeSeriesJSON` and `TimeSeriesSpoolArtifact` from Task 1.
- Produces: `TimeSeriesSpoolFactory#open(instance_id:, import_key:, import_mode:)`.
- Produces: `TimeSeriesSpoolWriter#register_series`, `#add_observation`, `#finalize`, and `#abort`.

- [ ] **Step 1: Write failing spool lifecycle and schema tests**

Use a temporary installation directory and assert:

```ruby
factory = Cybort::TimeSeriesSpoolFactory.new(directory: directory, clock: clock)
writer = factory.open(instance_id: "sensor", import_key: "batch-1", import_mode: :append)
writer.register_series(
  series_key: "office-temperature", metric_key: "temperature",
  value_type: :numeric, canonical_unit: "Cel", dimensions: { "room" => "office" }
)
writer.add_observation(
  series_key: "office-temperature", source_record_key: "reading-1",
  observed_at: Time.utc(2026, 9, 9, 12), numeric_value: 21.5, metadata: {}
)
artifact = writer.finalize(
  sync_state: { cursor: "reading-1" },
  source_finished_at: Time.utc(2026, 9, 9, 12), metadata: {}
)

assert_equal 1, artifact.series_count
assert_equal 1, artifact.observation_count
assert_equal 0o600, File.stat(artifact.path).mode & 0o777
```

Combine assertions for duplicate series identity, series-definition mismatch,
duplicate source record keys, unknown series, numeric/categorical exclusivity,
end-before-start rejection, timestamp conversion, finalized-writer rejection,
double abort, and cleanup after a block-form factory call raises.

- [ ] **Step 2: Run the spool test and confirm it fails**

Run through Luna-medium:

```bash
bundle exec ruby -Itest test/time_series_spool_test.rb
```

Expected: failure because `TimeSeriesSpoolFactory` is undefined.

- [ ] **Step 3: Implement the spool schema and writer**

Create private spool tables:

```sql
CREATE TABLE spool_series (
  series_key TEXT PRIMARY KEY,
  metric_key TEXT NOT NULL,
  value_type TEXT NOT NULL CHECK (value_type IN ('numeric', 'categorical')),
  canonical_unit TEXT,
  dimensions_json TEXT NOT NULL
);

CREATE TABLE spool_observations (
  series_key TEXT NOT NULL REFERENCES spool_series(series_key),
  source_record_key TEXT NOT NULL,
  observed_at_us INTEGER NOT NULL,
  ended_at_us INTEGER,
  numeric_value REAL,
  categorical_value TEXT,
  metadata_json TEXT NOT NULL,
  PRIMARY KEY (series_key, source_record_key),
  CHECK (ended_at_us IS NULL OR ended_at_us >= observed_at_us),
  CHECK ((numeric_value IS NOT NULL) <> (categorical_value IS NOT NULL))
);

CREATE TABLE spool_manifest (
  singleton_id INTEGER PRIMARY KEY CHECK (singleton_id = 1),
  instance_id TEXT NOT NULL,
  import_key TEXT NOT NULL,
  import_mode TEXT NOT NULL CHECK (import_mode IN ('append', 'snapshot')),
  series_count INTEGER NOT NULL,
  observation_count INTEGER NOT NULL,
  sync_state_json TEXT,
  source_finished_at_us INTEGER NOT NULL,
  metadata_json TEXT NOT NULL
);
```

Set `PRAGMA foreign_keys = ON`, `PRAGMA journal_mode = WAL`,
`PRAGMA synchronous = NORMAL`, and `busy_timeout(5_000)` on the disposable
database. Use prepared statements and commit every 10,000 writes so parser
memory stays bounded. `finalize` commits the open batch, writes the singleton
manifest in a final transaction, checkpoints and closes the database, computes
SHA-256 over the finalized file, and returns the artifact. Mirror manifest
values in the immutable artifact rather than using a mutable sidecar.

Convert `Time` using integer arithmetic:

```ruby
def utc_microseconds(time)
  (time.to_r * 1_000_000).to_i
end
```

Validate the series definition again when a duplicate `series_key` is
registered. For categorical series require `canonical_unit: nil`; for numeric
series require a nonblank unit. Ensure `abort` closes the handle and removes the
database plus `-wal` and `-shm` sidecars.

- [ ] **Step 4: Run focused tests**

Run through Luna-medium:

```bash
bundle exec ruby -Itest test/time_series_spool_test.rb
bundle exec ruby -Itest test/time_series_fetch_result_test.rb
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/cybort.rb lib/cybort/time_series_spool.rb test/time_series_spool_test.rb
git commit -m "Add disk-backed time-series spooling"
```

---

### Task 3: Implement canonical time-series persistence

**Files:**
- Create: `lib/cybort/time_series_schema.rb`
- Create: `lib/cybort/time_series_import_receipt.rb`
- Create: `lib/cybort/time_series_persistence.rb`
- Create: `test/time_series_persistence_test.rb`
- Modify: `lib/cybort.rb`

**Interfaces:**
- Consumes: finalized `TimeSeriesSpoolArtifact` objects.
- Produces: `TimeSeriesPersistence#setup!`, `#import`, `#context_for`, `#series_for`, `#observations_for`, `#pending_receipts`, `#mark_acknowledged`, `#delete_instance`, and `#backup_to`.
- Produces: immutable `TimeSeriesImportReceipt` readers for instance/import
  identity, mode, digest, source/commit/acknowledgement times, imported and
  stored counts, synchronization state, and metadata.

- [ ] **Step 1: Write failing schema and import tests**

Test exact table/index names, WAL mode, and the 5,000 ms busy timeout. Build
small artifacts through the real spool and cover:

- append insertion, repeated stable-record update, and absent-row preservation;
- snapshot replacement, including a valid empty snapshot;
- source-instance isolation;
- constraint-error rollback preserving the prior snapshot;
- identical import-key/digest idempotency;
- conflicting import-key/digest rejection;
- deterministic bounded time-window queries; and
- pending/acknowledged receipt transitions.

The range API must reject empty series IDs, inverted or unbounded ranges,
nonpositive limits, limits above 10,000, and order values other than
`:ascending` or `:descending`.

- [ ] **Step 2: Run the persistence test and confirm missing constants fail**

Run through Luna-medium:

```bash
bundle exec ruby -Itest test/time_series_persistence_test.rb
```

Expected: failure because `TimeSeriesPersistence` is undefined.

- [ ] **Step 3: Implement canonical schema and setup**

Use schema version 1 and these entities:

```sql
CREATE TABLE time_series_schema_migrations (
  version INTEGER PRIMARY KEY
);

CREATE TABLE series (
  id INTEGER PRIMARY KEY,
  adapter_instance_id TEXT NOT NULL,
  series_key TEXT NOT NULL,
  metric_key TEXT NOT NULL,
  value_type TEXT NOT NULL CHECK (value_type IN ('numeric', 'categorical')),
  canonical_unit TEXT,
  dimensions_json TEXT NOT NULL,
  created_at_us INTEGER NOT NULL,
  updated_at_us INTEGER NOT NULL,
  UNIQUE (adapter_instance_id, series_key),
  CHECK ((value_type = 'numeric' AND canonical_unit IS NOT NULL) OR
         (value_type = 'categorical' AND canonical_unit IS NULL))
);

CREATE TABLE observations (
  series_id INTEGER NOT NULL REFERENCES series(id) ON DELETE CASCADE,
  source_record_key TEXT NOT NULL,
  observed_at_us INTEGER NOT NULL,
  ended_at_us INTEGER,
  numeric_value REAL,
  categorical_value TEXT,
  ingested_at_us INTEGER NOT NULL,
  metadata_json TEXT NOT NULL,
  PRIMARY KEY (series_id, source_record_key),
  CHECK (ended_at_us IS NULL OR ended_at_us >= observed_at_us),
  CHECK ((numeric_value IS NOT NULL) <> (categorical_value IS NOT NULL))
);

CREATE INDEX idx_observations_series_time
  ON observations (series_id, observed_at_us, source_record_key);

CREATE TABLE time_series_instance_state (
  adapter_instance_id TEXT PRIMARY KEY,
  latest_import_key TEXT NOT NULL,
  stored_series_count INTEGER NOT NULL,
  stored_observation_count INTEGER NOT NULL,
  updated_at_us INTEGER NOT NULL
);

CREATE TABLE time_series_imports (
  adapter_instance_id TEXT NOT NULL,
  import_key TEXT NOT NULL,
  artifact_digest TEXT NOT NULL,
  import_mode TEXT NOT NULL CHECK (import_mode IN ('append', 'snapshot')),
  source_finished_at_us INTEGER NOT NULL,
  committed_at_us INTEGER NOT NULL,
  imported_series_count INTEGER NOT NULL,
  imported_observation_count INTEGER NOT NULL,
  stored_series_count INTEGER NOT NULL,
  stored_observation_count INTEGER NOT NULL,
  sync_state_json TEXT,
  metadata_json TEXT NOT NULL,
  acknowledged_at_us INTEGER,
  PRIMARY KEY (adapter_instance_id, import_key)
);
```

Apply foreign keys, WAL, and busy timeout exactly as the main persistence class
does. Set file permissions to `0600` after creation.

- [ ] **Step 4: Implement set-oriented import and queries**

Before attaching, independently open the artifact read-only and validate the
expected spool tables, column sets, counts, instance metadata, and digest.
Within one canonical transaction:

1. Return the existing receipt when import key and digest match.
2. Reject a conflicting digest before changing series or observations.
3. `ATTACH DATABASE ? AS incoming` using a bound path.
4. Upsert series definitions and reject definition changes for existing keys.
5. Insert/update observations with `INSERT ... SELECT` joined to canonical
   series IDs. Include `WHERE true` before SQLite's `ON CONFLICT` clause to
   avoid `SELECT` parsing ambiguity.
6. For snapshots, delete observations and then series for that instance when
   their stable identities are absent from the spool; preserve registered
   spool series even when they contain no observations.
7. Update `time_series_instance_state` with total stored counts and insert the
   pending import receipt with separate imported and stored counts.
8. Commit, detach in `ensure`, and return an immutable receipt.

Do not interpolate instance IDs, keys, or file paths into SQL. The fixed schema
alias `incoming` is safe because the writer serializes imports.

Reject value types that disagree with their spool series definition before the
canonical transaction changes any data. Return query rows as immutable structs with UTC `Time` objects at the Ruby
boundary. Always include deterministic tie breakers in SQL.

- [ ] **Step 5: Run focused tests**

Run through Luna-medium:

```bash
bundle exec ruby -Itest test/time_series_persistence_test.rb
bundle exec ruby -Itest test/time_series_spool_test.rb
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/cybort.rb lib/cybort/time_series_schema.rb \
  lib/cybort/time_series_import_receipt.rb \
  lib/cybort/time_series_persistence.rb \
  test/time_series_persistence_test.rb
git commit -m "Persist time-series observations in SQLite"
```

---

### Task 4: Add idempotent main-database acknowledgements

**Files:**
- Modify: `lib/cybort/schema.rb`
- Modify: `lib/cybort/persistence.rb`
- Modify: `lib/cybort.rb`
- Modify: `test/persistence_test.rb`

**Interfaces:**
- Consumes: `TimeSeriesImportReceipt`.
- Produces: `Persistence#acknowledge_time_series_import(receipt)` and `#time_series_import_acknowledged?`.

- [ ] **Step 1: Write failing acknowledgement tests**

Add main persistence tests proving acknowledgement atomically:

- advances `last_successful_fetch` and `sync_state_json`;
- inserts exactly one successful fetch run with the observation count;
- records `(instance_id, import_key)`;
- is a no-op when repeated; and
- rejects an unknown instance and clamps a future receipt completion time to
  the main persistence clock exactly like ordinary successful results.

- [ ] **Step 2: Run focused tests and confirm failure**

Run through Luna-medium:

```bash
bundle exec ruby -Itest test/persistence_test.rb
```

Expected: failure because acknowledgement APIs are missing.

- [ ] **Step 3: Add the main acknowledgement schema and APIs**

Bump `Cybort::Schema::VERSION` to 3 and add:

```sql
CREATE TABLE IF NOT EXISTS time_series_acknowledgements (
  instance_id TEXT NOT NULL REFERENCES adapter_instances(id) ON DELETE CASCADE,
  import_key TEXT NOT NULL,
  acknowledged_at TEXT NOT NULL,
  PRIMARY KEY (instance_id, import_key)
);
```

`acknowledge_time_series_import` starts one main transaction, checks the
acknowledgement key, clamps the successful time exactly like
`write_fetch_result`, updates adapter state, inserts a successful fetch run with
`item_count = receipt.imported_observation_count` and metadata containing
`result_kind: "time_series"`, then inserts the acknowledgement. Return `true`
for a new acknowledgement and `false` for an existing one.

Modify `delete_instance` to delete acknowledgement rows before the adapter row;
retain explicit ordering even though the foreign key cascades.

- [ ] **Step 4: Run focused tests**

Run through Luna-medium:

```bash
bundle exec ruby -Itest test/persistence_test.rb
bundle exec ruby -Itest test/time_series_persistence_test.rb
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/cybort.rb lib/cybort/schema.rb lib/cybort/persistence.rb \
  test/persistence_test.rb
git commit -m "Reconcile time-series import receipts"
```

---

### Task 5: Run time-series persistence independently of item commits

**Files:**
- Create: `lib/cybort/time_series_writer.rb`
- Create: `lib/cybort/time_series_reconciler.rb`
- Create: `test/time_series_writer_test.rb`
- Create: `test/time_series_reconciler_test.rb`
- Create: `test/system/time_series_orchestration_system_test.rb`
- Modify: `lib/cybort/orchestrator.rb`
- Modify: `lib/cybort/adapter_registry.rb`
- Modify: `lib/cybort/cli.rb`
- Modify: `lib/cybort.rb`
- Modify: `test/orchestrator_test.rb`

**Interfaces:**
- Consumes: `TimeSeriesFetchResult`, `TimeSeriesPersistence#import`, and main acknowledgement APIs.
- Produces: `TimeSeriesWriter#start`, `#submit_import`, `#submit_acknowledgement`, and `#close_and_join`.
- Produces: `TimeSeriesReconciler#run` using the writer for canonical acknowledgement markers.
- Changes: `Orchestrator.new` accepts `time_series_persistence:` and `time_series_spool_factory:`.

- [ ] **Step 1: Write failing writer lifecycle tests**

Use injected persistence and a shared `Queue`. Test FIFO serialization, receipt
events, normalized persistence failures, artifact cleanup after every terminal
path, close with no submissions, abnormal worker termination, and that cleanup
does not replace an active error.

The writer event is a frozen struct:

```ruby
TimeSeriesWriterEvent = Data.define(:kind, :instance_id, :result, :receipt, :error)
```

Use the project's supported Ruby 4.0.1 `Data` class. `kind` is `:imported`,
`:acknowledged`, or `:failed`; validate the corresponding receipt/error fields.

- [ ] **Step 2: Run the writer test and confirm failure**

Run through Luna-medium:

```bash
bundle exec ruby -Itest test/time_series_writer_test.rb
```

Expected: failure because `TimeSeriesWriter` is undefined.

- [ ] **Step 3: Implement the writer worker**

The writer accepts a `time_series_persistence_factory:` rather than a live
SQLite-backed object. Its thread calls the factory once and exclusively owns
that writable connection until shutdown; no SQLite connection object crosses a
thread boundary. The worker owns no main persistence reference. It accepts import and
acknowledgement commands. Imports call `TimeSeriesPersistence#import`, publish
one terminal event, and ensure artifact deletion. Acknowledgement commands call
`TimeSeriesPersistence#mark_acknowledged` and publish a terminal marker event.
`close_and_join` enqueues a private sentinel, observes `Thread#value`, and is
idempotent. Reject submissions before `start` or after close.

- [ ] **Step 4: Write failing reconciliation tests**

Simulate both crash windows. Start a real writer against temporary persistence,
then assert the reconciler performs the main acknowledgement before it submits
the canonical acknowledgement marker:

```ruby
receipt = time_series.import(artifact)
reconciler.run

assert main.time_series_import_acknowledged?(
  instance_id: "sensor", import_key: "batch-1"
)
assert_empty time_series.pending_receipts
assert_equal 1, main.fetch_runs_for(instance_id: "sensor").length
```

For the second window, inject one `mark_acknowledged` failure after the main
commit, construct a fresh writer/reconciler, and prove rerunning produces no
second fetch-history row. The reconciler may read pending receipts directly but
all of its canonical time-series writes must be submitted to the writer.

- [ ] **Step 5: Write failing orchestration tests**

Register test-only adapters with `result_kind: :time_series` and an injected
spool factory. Cover:

- registry injection of the spool factory only when accepted by the factory;
- startup reconciliation before adapter planning;
- cached and failed time-series results never submitted to the writer;
- malformed result-kind and mismatched-instance rejection;
- writer receipt followed by one main acknowledgement and one completion;
- writer failure recorded as an instance failure without discarding successful
  item results;
- final `RunResult.instances` remains in configuration order;
- every adapter and writer thread is observed during launch and cleanup errors;
  and
- a controlled long time-series import overlaps a successful main-database
  item commit.

The key concurrency assertion should use queues, not sleeps:

```ruby
time_series_import_started = Queue.new
release_time_series_import = Queue.new

run_thread = Thread.new { orchestrator.run(force_fetch: true) }
time_series_import_started.pop
assert_equal "rss", item_commit_events.pop
release_time_series_import << true
result = run_thread.value

assert_equal :success, result.overall_status
```

- [ ] **Step 6: Route results through one event loop**

Start a time-series writer when at least one registered instance has
`result_kind: :time_series` or pending receipts exist, then run reconciliation
before planning. Source events
are consumed as today. Item results are finalized immediately; remote
time-series successes are submitted and receive no terminal status until the
writer event returns. On an imported event, acknowledge it on the main caller
thread, submit the receipt-marker command to the writer, and create the terminal
status only after the acknowledged event returns.

Loop until every configured instance has a terminal status rather than a fixed
number of source events. In `ensure`, observe all adapter threads, then close
and observe the writer. Preserve the current active-error precedence.

For time-series planning context, merge
`time_series_persistence.context_for(instance_id:)` into the main planning
context. A cached `TimeSeriesFetchResult` reports stored observation and series
counts without loading observations.

In the CLI, initialize the schema before concurrent work, construct a read-side
`TimeSeriesPersistence` at `ROOT/cybort-timeseries.sqlite3`, and pass the writer
a factory that constructs a separate instance for the same path inside its
thread. Construct the spool factory at `ROOT/tmp`. Do not include raw
observations in normal JSON output; the instance status contains counts and
`items: []` until dashboards are designed.

- [ ] **Step 7: Run focused and system tests**

Run through Luna-medium:

```bash
bundle exec ruby -Itest test/time_series_writer_test.rb
bundle exec ruby -Itest test/time_series_reconciler_test.rb
bundle exec ruby -Itest test/orchestrator_test.rb
bundle exec ruby -Itest test/system/time_series_orchestration_system_test.rb
bundle exec ruby -Itest test/system/cli_system_test.rb
```

Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add lib/cybort.rb lib/cybort/adapter_registry.rb lib/cybort/orchestrator.rb \
  lib/cybort/cli.rb lib/cybort/time_series_writer.rb \
  lib/cybort/time_series_reconciler.rb \
  test/adapter_registry_test.rb test/orchestrator_test.rb \
  test/time_series_writer_test.rb test/time_series_reconciler_test.rb \
  test/system/time_series_orchestration_system_test.rb \
  test/system/cli_system_test.rb
git commit -m "Persist time-series results independently"
```

---

### Task 6: Make installation backup and purge cover both databases

**Files:**
- Create: `lib/cybort/installation_backup.rb`
- Create: `test/installation_backup_test.rb`
- Modify: `lib/cybort/installer.rb`
- Modify: `lib/cybort/cli.rb`
- Modify: `lib/cybort.rb`
- Modify: `test/installer_test.rb`
- Modify: `test/cli_test.rb`

**Interfaces:**
- Consumes: `Persistence#backup_to`, `TimeSeriesPersistence#backup_to`, and both `#delete_instance` methods.
- Produces: `InstallationBackup#create(destination:)` returning the destination directory.

- [ ] **Step 1: Write failing installation lifecycle tests**

Update the new-installation test to require both canonical database files.
Create an installation backup test that expects:

```text
DESTINATION/
  cybort.sqlite3
  cybort-timeseries.sqlite3
  manifest.json
```

The manifest contains format version 1, UTC creation time, both filenames, and
their SHA-256 digests. Test refusal when the destination exists, cleanup of a
partially created temporary directory, and successful reopening of both backup
databases.

Change purge CLI tests so `--backup PATH` treats `PATH` as this backup directory.
Cover an item-only instance, a time-series instance, a time-series deletion
failure that preserves main control state, and an idempotent rerun after the
time-series delete committed but main deletion did not.

- [ ] **Step 2: Run lifecycle tests and confirm failure**

Run through Luna-medium:

```bash
bundle exec ruby -Itest test/installation_backup_test.rb
bundle exec ruby -Itest test/installer_test.rb
bundle exec ruby -Itest test/cli_test.rb
```

Expected: failures for the missing second database and backup service.

- [ ] **Step 3: Initialize both databases**

In both `Installer#create_new` and `Installer#reset`, call:

```ruby
Persistence.new(File.join(location, "cybort.sqlite3"), clock: @clock).setup!
TimeSeriesPersistence.new(
  File.join(location, "cybort-timeseries.sqlite3"), clock: @clock
).setup!
```

The existing tar archive used before installation reset already captures the
whole installation directory and needs no format change.

- [ ] **Step 4: Implement two-file backup creation**

Build the backup in a uniquely named sibling temporary directory, call each
persistence object's SQLite-native `backup_to`, write the manifest with mode
`0600`, then rename the completed directory to the requested destination.
Never publish a partial destination. Do not copy live SQLite files with
`FileUtils.cp`.

- [ ] **Step 5: Implement recoverable purge ordering**

When the time-series database exists, delete that instance's observations,
series, and receipts first. Delete the main instance second. Both operations
are individually transactional and idempotent. A time-series failure prevents
main deletion; a crash after time-series deletion is repaired by rerunning the
same purge. Update confirmation text to mention observations without pinning
the entire sentence in tests.

- [ ] **Step 6: Run focused tests**

Run through Luna-medium:

```bash
bundle exec ruby -Itest test/installation_backup_test.rb
bundle exec ruby -Itest test/installer_test.rb
bundle exec ruby -Itest test/cli_test.rb
```

Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add lib/cybort.rb lib/cybort/installation_backup.rb lib/cybort/installer.rb \
  lib/cybort/cli.rb test/installation_backup_test.rb test/installer_test.rb \
  test/cli_test.rb
git commit -m "Cover time-series data in installation lifecycle"
```

---

### Task 7: Document and benchmark the implemented substrate

**Files:**
- Create: `script/benchmark_time_series.rb`
- Modify: `AGENTS.md`
- Modify: `README.md`
- Modify: `docs/adr/0009-isolate-time-series-storage.md`
- Modify: `docs/adr/README.md`
- Modify: `docs/LEARNINGS.md`

**Interfaces:**
- Consumes: public spool and persistence APIs from Tasks 2 and 3.
- Produces: a manual synthetic benchmark with bounded summary output.

- [ ] **Step 1: Add the opt-in synthetic benchmark**

The script accepts `--observations COUNT` with default `1_500_000` and a
required `--output DIRECTORY`. It generates deterministic numeric observations
without retaining them in an array, measures spool construction, canonical
import, file/WAL sizes, and two representative bounded range queries, and emits
one JSON summary. It contains no personal paths or source data.

Use monotonic time for durations and UTC wall time for observation timestamps:

```ruby
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
# operation
duration_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
```

The script is evidence gathering, not a CI performance gate. It exits nonzero
for validation or persistence failures but has no maximum-duration assertion.

- [ ] **Step 2: Run the benchmark once outside the test suite**

Run through Luna-medium in a disposable directory:

```bash
bundle exec ruby script/benchmark_time_series.rb \
  --observations 1500000 --output /tmp/cybort-time-series-benchmark
```

Expected: exit 0 and one bounded JSON summary. Record only counts, durations,
sizes, SQLite/Ruby versions, and query row counts in `docs/LEARNINGS.md`; do not
commit generated databases.

- [ ] **Step 3: Update durable documentation**

Update `AGENTS.md` only after code implements the new truth:

- the canonical datastore is a pair of SQLite databases;
- time-series spools are disposable and adapters remain canonical-SQL-free;
- the dedicated time-series writer may write concurrently with the
  orchestrator caller's main-database writes; and
- observations are retained forever in version one.

Update README initialization, backup/purge, file layout, and the statement that
no connector currently emits time-series results. Do not add an Apple Health
configuration example.

Change ADR 0009 status to `Accepted; implemented` in both the ADR and index.
Add a dated learning containing the benchmark command, summarized evidence,
impact, and next action. Do not generalize one-machine timings into a contract.

- [ ] **Step 4: Run complete verification**

Delegate all commands and output analysis to Luna-medium:

```bash
bundle exec rake test
bundle exec rake quality
git diff --check
ruby -c lib/cybort/time_series_spool.rb
ruby -c lib/cybort/time_series_persistence.rb
ruby -c lib/cybort/time_series_writer.rb
```

Expected: all tests, quality gates, whitespace checks, and syntax checks pass.
Also run the local Markdown-link check used during design and confirm every new
relative link resolves.

- [ ] **Step 5: Perform final code review**

Inspect performance, maintainability, correctness, and cleanup paths. In
particular verify:

- no canonical write occurs from an adapter thread;
- no observation array is constructed by the spool or import path;
- all SQL data is bound rather than interpolated;
- exactly one time-series writer exists per run;
- all threads and spool files are observed or cleaned under exceptions;
- main source state never advances before its time-series receipt commits;
- duplicate import acknowledgement cannot create duplicate fetch history; and
- existing item-only runs do not open unnecessary worker threads.

Apply accepted findings and rerun affected focused tests plus the full suite
through Luna-medium.

- [ ] **Step 6: Commit**

```bash
git add AGENTS.md README.md docs/LEARNINGS.md docs/adr/README.md \
  docs/adr/0009-isolate-time-series-storage.md script/benchmark_time_series.rb
git commit -m "Document time-series storage operations"
```

---

## Completion criteria

- Existing item adapters behave unchanged and retain completion-ordered main
  persistence.
- Generated time-series adapters can return cached, failed, append, and
  snapshot results without using canonical SQL.
- A synthetic 1.5-million-observation producer has bounded Ruby memory because
  it streams to disk.
- A blocked canonical time-series import does not prevent an ordinary item
  result from committing to the main database.
- Cross-database crash windows reconcile without data loss, premature cursor
  advancement, or duplicate fetch history.
- Backup, reset, and purge workflows cover both canonical databases.
- No Apple Health or other source connector is implemented or registered.
- The full test and quality suites pass.
