# Apple Health Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an experimental, bounded-memory `apple_health` connector that safely imports ordinary quantity and category records from local Apple Health ZIP exports as append-only time-series observations.

**Architecture:** The adapter snapshots and validates one dedicated local source directory, uses a killable internal helper process to acquire private stable copies, inventories every ZIP candidate, and selects at most one unseen export per run by `ExportDate`. Rubyzip entry IO feeds a strict Nokogiri SAX parser that normalizes directly into the existing persistence-owned SQLite spool; the dedicated time-series writer performs a no-op-aware append transaction, commits a durable receipt, and exposes only a sanitized count projection before the orchestrator acknowledges main-database freshness.

**Tech Stack:** Ruby 4.0.1, SQLite 3 through `sqlite3`, Rubyzip 3.6.0, Nokogiri 1.19.4 with vendored libxml2, SHA-256, `BigDecimal`, Minitest, Ruby processes/threads/queues

**Spec:** `docs/superpowers/specs/2026-09-11-apple-health-import-design.md`

## Global Constraints

- Apple Health is an append-only import source: every new archive uses `:append`; absent, corrected, reordered, and older records never trigger synchronization deletion. Only the explicit instance purge may delete Apple Health observations.
- Version one imports only top-level `Record` elements whose type starts with `HKQuantityTypeIdentifier` or `HKCategoryTypeIdentifier`; it inventories but does not import workouts, activity summaries, correlations, nested beat series, ECGs, routes, clinical documents, audiograms, profile data, or unknown families.
- The canonical datastore remains exactly `cybort.sqlite3` plus `cybort-timeseries.sqlite3`; archive copies, decompression buffers, and SQLite spools live only under the installation's mode-`0700` `tmp/` directory.
- Adapter and acquisition-helper code never receives a canonical SQLite connection, issues canonical SQL, executes a user-provided command, follows a source/ZIP symlink, writes beneath the configured source directory, or performs a network request.
- Pin `rubyzip` exactly to `3.6.0` and `nokogiri` exactly to `1.19.4`; use Rubyzip central-directory/entry IO and Nokogiri XML SAX, with recovery, network access, entity replacement, external resources, and custom entities disabled.
- A stale or forced check examines every immediate-child filename with a case-insensitive `.zip` suffix; hidden ZIPs count, child directories are not traversed, no valid candidate means failure, and a broken candidate never falls back to another archive in that run.
- Support exactly one configured `apple_health` instance, require `num_items_to_fetch = 1`, and reject `retention_ttl_minutes` and `hard_expiry_ttl_minutes`; `ttl_minutes` retains its normal freshness meaning.
- The configured `directory` is a nonblank absolute or `~/` path. Reject relative paths, environment/shell expansion, glob syntax, source-directory symlinks, wrong ownership, and group/other write bits. Broader read bits produce a bounded warning only.
- Acquisition has a 600-second monotonic deadline from helper open through final stability validation. Timeout sends `SIGKILL`, reaps the helper, removes its partial copy, and reports `archive_acquisition_timeout` without a source path or filename.
- Enforce at most 128 candidates, 4 GiB compressed bytes per archive, 100,000 ZIP entries, 1,024 UTF-8 bytes per entry name, 16 GiB declared/streamed total uncompressed bytes, 12 GiB declared/streamed `export.xml` bytes, a 200:1 declared expansion ratio, and 100,000 distinct series.
- Enforce at most 64 record attributes, 128 direct metadata entries, 4 KiB per attribute/metadata value, and 64 KiB total in-flight record bytes. Also enforce parser depth 64, XML/attribute names 256 bytes, DTD declarations 10,000, DTD bytes 1 MiB, non-record text 1 MiB, and bytes before the unique `ExportDate` 8 MiB; these fail-closed limits replace no archive-wide DOM/list and do not impose an arbitrary 256-MiB process cap.
- Observation identity excludes archive bytes, filename, document order, and attribute/metadata order. Source/device values may participate in the one-way content digest but must not be stored in readable series, observation, receipt-public, fetch-history-public, or diagnostic fields.
- Archive idempotency uses `apple-health-import-v1:<archive-sha256>`; record and series identity use the `apple-health-record-v1:` namespace. Repackaging identical XML may create a second receipt but must not create or rewrite duplicate observations.
- An unchanged fingerprint is a successful remote check with no XML body parse, spool, time-series writer command, receipt, or time-series database write. A TTL cache hit does not open the source directory.
- Canonical conflicts update only when the complete normalized payload differs; unchanged rows retain `ingested_at_us`. Writer events expose an immutable `imported/inserted/duplicate/unchanged/changed/deleted/stored` projection, and `deleted` is zero for every Apple Health import.
- Main state never advances before the append receipt commits. Startup reconciliation acknowledges a pending receipt without requiring the source archive and never creates duplicate fetch history.
- Automated tests use synthetic local fixtures, injected clocks/process collaborators, and no personal export, Apple/iCloud access, network request, or sleep-based synchronization. Assert stable categories, phases, durable outcomes, and secret absence rather than exact prose.
- All test, benchmark-output analysis, build, lint, and noisy-log work must be delegated to a read-only `gpt-5.6-luna` subagent with medium reasoning as required by `AGENTS.md`.
- Do not edit `docs/spitballing/apple-health.md` or the approved design spec.

---

## File map

### New production files

- `lib/cybort/time_series_import_projection.rb` — immutable sanitized writer-event count projection.
- `lib/cybort/apple_health_error.rb` — closed error taxonomy and bounded safe metadata.
- `lib/cybort/apple_health_canonical.rb` — UTF-8/NFC, decimal, timestamp, series-key, and record-key normalization.
- `lib/cybort/apple_health_archive_acquirer.rb` — source permission checks, helper supervision, stable-copy lifecycle, and orphan cleanup.
- `script/apple_health_archive_copy_helper.rb` — fixed copy-only child process that hashes bytes and verifies the open/path identity.
- `lib/cybort/apple_health_zip.rb` — strict ZIP inventory, local-header checks, export-entry selection, limits, and checksum-counting streams.
- `lib/cybort/apple_health_export_parser.rb` — guarded Nokogiri SAX probe/full-parser state machine and bounded artifact counters.
- `lib/cybort/adapters/apple_health.rb` — cache, discovery, candidate selection, unchanged, spool, and result orchestration.
- `script/benchmark_apple_health.rb` — opt-in streaming synthetic ZIP generator, first import, 99%-overlap append, and range-query benchmark.
- `docs/adr/0010-append-only-time-series-import-results.md` — amendment recording append-only source semantics, unchanged success, no-op writes, and public projections.

### Modified production and documentation files

- `Gemfile`, `Gemfile.lock` — exact Rubyzip and Nokogiri runtime pins and platform lock data.
- `lib/cybort.rb` — load new contracts before the adapter/registry.
- `lib/cybort/adapter_registry.rb` — support per-adapter instance maxima, then register `apple_health` in the same final change as its template/README documentation.
- `lib/cybort/time_series_spool_artifact.rb`, `lib/cybort/time_series_spool.rb` — expose the local temp directory and collapse exact duplicate observations on disk.
- `lib/cybort/time_series_schema.rb`, `lib/cybort/time_series_import_receipt.rb`, `lib/cybort/time_series_persistence.rb` — migrate receipt counters and make observation upserts no-op-aware.
- `lib/cybort/time_series_reader.rb` — include durable import keys in immutable planning context.
- `lib/cybort/time_series_fetch_result.rb` — distinguish imported, unchanged, cached, and failed results.
- `lib/cybort/time_series_writer.rb` — attach only the sanitized import projection to import events.
- `lib/cybort/persistence.rb`, `lib/cybort/orchestrator.rb` — persist unchanged checks in the main database and publish writer counts without private receipt metadata.
- `Rakefile` — include the Apple Health files in the staged correctness/security/performance quality gate.
- `.cybort.example.toml`, `README.md` — document the registered connector, dedicated directory, privacy, append-only behavior, and experimental gates.
- `AGENTS.md`, `docs/LEARNINGS.md`, `docs/adr/README.md`, `docs/adr/0009-isolate-time-series-storage.md` — record the implemented invariant, measured scale evidence, and ADR amendment.

### New test support, fixtures, and tests

- `test/support/apple_health_fixture.rb` — deterministic XML/ZIP builders, central/local header patchers, and overlap generators.
- `test/fixtures/apple_health/export_basic.xml` — numeric/category points and intervals, offsets, metadata, unsupported top-level families, and discarded `<Me>` sentinels.
- `test/fixtures/apple_health/export_overlap_one.xml` — initial records used by append/idempotency tests.
- `test/fixtures/apple_health/export_overlap_two.xml` — unchanged, inserted, corrected, omitted, and exact-duplicate records.
- `test/fixtures/apple_health/export_empty.xml` — valid zero-record document.
- `test/fixtures/apple_health/export_unsupported_only.xml` — nonempty document with no supported ordinary record.
- `test/fixtures/apple_health/export_schema_drift.xml` — unknown child inside a governed `Record`.
- `test/fixtures/apple_health/export_entities.xml` — internal/external/custom entity attempts with privacy sentinels.
- `test/fixtures/apple_health/export_malformed.xml` — truncated root and malformed UTF-8 cases generated from explicit byte sequences.
- `test/time_series_import_projection_test.rb`
- `test/apple_health_error_test.rb`
- `test/apple_health_canonical_test.rb`
- `test/apple_health_archive_acquirer_test.rb`
- `test/apple_health_zip_test.rb`
- `test/apple_health_export_parser_test.rb`
- `test/adapters/apple_health_test.rb`
- `test/system/apple_health_system_test.rb`

### Modified tests

- `test/cybort_boot_test.rb`, `test/adapter_registry_test.rb`, `test/configuration_test.rb`
- `test/time_series_fetch_result_test.rb`, `test/time_series_spool_test.rb`, `test/time_series_persistence_test.rb`, `test/time_series_reader_test.rb`, `test/time_series_writer_test.rb`, `test/time_series_reconciler_test.rb`
- `test/persistence_test.rb`, `test/orchestrator_test.rb`
- `test/system/time_series_orchestration_system_test.rb`, `test/system/cli_system_test.rb`

---

### Task 1: Lock parser dependencies and record the ADR amendment

**Files:**
- Modify: `Gemfile`
- Modify: `Gemfile.lock`
- Modify: `lib/cybort.rb`
- Modify: `test/cybort_boot_test.rb`
- Create: `docs/adr/0010-append-only-time-series-import-results.md`
- Modify: `docs/adr/README.md`
- Modify: `docs/adr/0009-isolate-time-series-storage.md`

**Interfaces:**
- Produces: runtime availability of `Zip::VERSION` from Rubyzip `3.6.0` and `Nokogiri::VERSION` from Nokogiri `1.19.4`.
- Produces: accepted ADR 0010 amending, not superseding, ADR 0009.
- Records: `TimeSeriesFetchResult.unchanged`, idempotent spool insertion, no-op-aware append counters, and sanitized writer projection as required substrate extensions.

- [ ] **Step 1: Write the failing dependency boot test**

Add a focused assertion without loading or parsing any archive:

```ruby
def test_pins_apple_health_parser_dependencies
  assert_equal "3.6.0", Gem.loaded_specs.fetch("rubyzip").version.to_s
  assert_equal "1.19.4", Gem.loaded_specs.fetch("nokogiri").version.to_s
  assert defined?(Zip::File)
  assert defined?(Nokogiri::XML::SAX::Parser)
end
```

- [ ] **Step 2: Run the boot test and verify the dependency failure**

Delegate to Luna-medium:

```bash
bundle exec ruby -Itest test/cybort_boot_test.rb
```

Expected: FAIL because `rubyzip` and `nokogiri` are absent from `Gemfile.lock` and `lib/cybort.rb` does not load them.

- [ ] **Step 3: Pin and lock the two runtime gems**

Add exact constraints, then resolve only these dependencies:

```ruby
gem "rubyzip", "= 3.6.0", require: "zip"
gem "nokogiri", "= 1.19.4"
```

```bash
bundle lock --update rubyzip nokogiri
```

Require `zip` and `nokogiri` near the top of `lib/cybort.rb`, before any Apple Health constants. Preserve the existing `arm64-darwin` platform and Bundler version in the lockfile; do not widen unrelated dependency constraints.

- [ ] **Step 4: Write ADR 0010 and index the amendment**

Use status `Accepted`, date `2026-09-13`, and these explicit decisions:

```markdown
# ADR 0010: Append-Only Time-Series Import Results

- Status: Accepted
- Date: 2026-09-13
- Amends: [ADR 0009](0009-isolate-time-series-storage.md)

## Decision

Append-only local imports may return an explicit successful-unchanged result
that advances only main-database freshness. Spool insertion collapses exact
duplicate key/payload pairs on disk, canonical observation conflicts skip
materially identical updates, and writer import events carry a sanitized count
projection separate from the durable receipt. Apple Health never invokes
snapshot replacement; source omissions and corrected payloads do not delete or
overwrite older content-derived identities.
```

Complete the ADR with context, consequences, alternatives (`snapshot`, archive-keyed observations, unconditional conflict updates), and links to the design and this plan. Add index row 0010 as `Accepted`; change ADR 0009's status/reference only to `Accepted; amended by 0010` while leaving its historical decision text intact.

- [ ] **Step 5: Verify versions, licenses, and applicable advisories**

Delegate command execution/output review to Luna-medium:

```bash
bundle exec ruby -e 'require "zip"; require "nokogiri"; %w[rubyzip nokogiri].each { |n| s = Gem.loaded_specs.fetch(n); puts [n, s.version, s.licenses.sort.join(",")].join(" ") }'
gem install bundler-audit --version 0.9.3 --no-document
bundle-audit check --update
```

Expected: exact versions `3.6.0` and `1.19.4`, both gemspecs report an acceptable MIT license, and the advisory scan exits 0 with no unpatched advisory affecting the locked graph. If the scan reports an applicable advisory, stop before registration and revise the exact pin through ADR/design review.

- [ ] **Step 6: Run the focused test and documentation checks**

Delegate the test to Luna-medium; run the read-only link/diff checks locally or through Luna:

```bash
bundle exec ruby -Itest test/cybort_boot_test.rb
git diff --check
ruby -e 'ARGV.each { |p| abort("missing: #{p}") unless File.file?(p) }' docs/adr/0009-isolate-time-series-storage.md docs/adr/0010-append-only-time-series-import-results.md docs/superpowers/specs/2026-09-11-apple-health-import-design.md
```

Expected: PASS, clean whitespace, and all three linked records exist.

- [ ] **Step 7: Commit the dependency and decision checkpoint**

```bash
git add Gemfile Gemfile.lock lib/cybort.rb test/cybort_boot_test.rb \
  docs/adr/0009-isolate-time-series-storage.md docs/adr/0010-append-only-time-series-import-results.md \
  docs/adr/README.md
git commit -m "Record Apple Health import contracts"
```

---

### Task 2: Extend the spool and canonical append path with exact count semantics

**Files:**
- Create: `lib/cybort/time_series_import_projection.rb`
- Create: `test/time_series_import_projection_test.rb`
- Modify: `lib/cybort/time_series_spool_artifact.rb`
- Modify: `lib/cybort/time_series_spool.rb`
- Modify: `lib/cybort/time_series_schema.rb`
- Modify: `lib/cybort/time_series_import_receipt.rb`
- Modify: `lib/cybort/time_series_persistence.rb`
- Modify: `lib/cybort/time_series_writer.rb`
- Modify: `lib/cybort.rb`
- Modify: `test/time_series_fetch_result_test.rb`
- Modify: `test/time_series_spool_test.rb`
- Modify: `test/time_series_persistence_test.rb`
- Modify: `test/time_series_writer_test.rb`

**Interfaces:**
- Changes: `TimeSeriesSpoolFactory#directory -> String` exposes only the private local spool root.
- Changes: `TimeSeriesSpoolWriter#add_observation(...) -> :inserted | :duplicate`; identical duplicates are no-ops and same-key/different-payload pairs raise `ArgumentError`.
- Changes: `TimeSeriesSpoolWriter#finalize(sync_state:, source_finished_at:, metadata:) -> TimeSeriesSpoolArtifact` records `duplicate_observation_count` in the manifest/artifact.
- Changes: `TimeSeriesPersistence#import(artifact) -> TimeSeriesImportReceipt` records imported, inserted, duplicate, unchanged, changed, deleted, and stored counts.
- Produces: `TimeSeriesImportProjection.from_receipt(receipt) -> TimeSeriesImportProjection` with readers `imported`, `inserted`, `duplicate`, `unchanged`, `changed`, `deleted`, `stored_series`, and `stored_observations`.
- Changes: successful `TimeSeriesWriterEvent` for phase `:import` requires `projection`; acknowledgement/purge/failure events require `projection: nil`.

- [ ] **Step 1: Write failing spool duplicate-collapse tests**

Replace the old “all duplicate keys fail” expectation with both branches:

```ruby
first = writer.add_observation(
  series_key: "temperature", source_record_key: "record-v1:abc",
  observed_at: @finished, numeric_value: 21.5,
  metadata: { "start_offset_minutes" => -240 }
)
duplicate = writer.add_observation(
  series_key: "temperature", source_record_key: "record-v1:abc",
  observed_at: @finished, numeric_value: 21.5,
  metadata: { "start_offset_minutes" => -240 }
)

assert_equal :inserted, first
assert_equal :duplicate, duplicate
artifact = writer.finalize(sync_state: {}, source_finished_at: @finished, metadata: {})
assert_equal 1, artifact.observation_count
assert_equal 1, artifact.duplicate_observation_count
```

Add a second assertion where the same `(series_key, source_record_key)` changes `numeric_value`, `ended_at`, or normalized metadata and must raise `ArgumentError` without incrementing either count. Reopen the spool SQLite file and assert the manifest/database each contain one unique observation and one duplicate count.

- [ ] **Step 2: Write failing no-op persistence and projection tests**

Import an append artifact, save `ingested_at`, advance the injected clock, then import a differently keyed artifact containing the same observation identity:

```ruby
first = @persistence.import(artifact(import_key: "archive-a"))
before = observations.first.ingested_at
@finished += 60
second = @persistence.import(artifact(import_key: "archive-b"))

assert_equal [1, 0, 0, 0], [first.inserted_observation_count,
  first.unchanged_observation_count, first.changed_observation_count,
  first.deleted_observation_count]
assert_equal [0, 1, 0, 0], [second.inserted_observation_count,
  second.unchanged_observation_count, second.changed_observation_count,
  second.deleted_observation_count]
assert_equal before, observations.first.ingested_at
assert_equal({ imported: 1, inserted: 0, duplicate: 0, unchanged: 1,
  changed: 0, deleted: 0, stored_series: 1, stored_observations: 1 },
  Cybort::TimeSeriesImportProjection.from_receipt(second).to_h)
```

Also test a genuinely changed payload under a stable generic key (`changed = 1`, `ingested_at_us` advances), snapshot deletion counting, artifact duplicate propagation, old schema-version-1 database migration defaults, receipt round-trip, event projection validation, and import-event privacy by putting `"archive_sha256" => "f" * 64` in receipt metadata and refuting it from `event.projection.to_h`.

- [ ] **Step 3: Run focused tests and verify the old contracts fail**

Delegate to Luna-medium:

```bash
bundle exec ruby -Itest test/time_series_spool_test.rb
bundle exec ruby -Itest test/time_series_persistence_test.rb
bundle exec ruby -Itest test/time_series_import_projection_test.rb
bundle exec ruby -Itest test/time_series_writer_test.rb
```

Expected: FAIL because duplicate spool keys raise, canonical conflicts always update, schema/receipt counter columns do not exist, and writer events have no projection.

- [ ] **Step 4: Implement idempotent disk-backed spool insertion**

Expose a frozen factory directory and change the prepared insert to `ON CONFLICT DO NOTHING`. On conflict, fetch and compare the complete normalized payload from SQLite rather than retaining an archive-wide Ruby set:

```ruby
attr_reader :directory

@insert_observation = prepare(<<~SQL)
  INSERT INTO spool_observations (
    series_key, source_record_key, observed_at_us, ended_at_us,
    numeric_value, categorical_value, metadata_json
  ) VALUES (?, ?, ?, ?, ?, ?, ?)
  ON CONFLICT (series_key, source_record_key) DO NOTHING
SQL

def add_observation(**attributes)
  normalized = normalize_observation(**attributes)
  execute_statement(@insert_observation, normalized.values_at(*OBSERVATION_COLUMNS))
  if @database.changes == 1
    @observation_count += 1
    :inserted
  elsif stored_observation(normalized.values_at(:series_key, :source_record_key)) == normalized
    @duplicate_observation_count += 1
    :duplicate
  else
    raise ArgumentError, "source record key maps to different normalized content"
  end
end
```

Initialize duplicate count to zero, include it in `spool_manifest` and `TimeSeriesSpoolArtifact`, independently validate it in canonical persistence, and keep transaction rollback counters correct. Do not include duplicate identities in `@series_definitions` or a new Ruby collection.

- [ ] **Step 5: Migrate receipts and make canonical conflicts no-op-aware**

Set `TimeSeriesSchema::VERSION = 2`. After applying v1 DDL, migrate version 1 exactly once with five nonnegative integer columns defaulted to zero:

```sql
ALTER TABLE time_series_imports ADD COLUMN inserted_observation_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE time_series_imports ADD COLUMN duplicate_observation_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE time_series_imports ADD COLUMN unchanged_observation_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE time_series_imports ADD COLUMN changed_observation_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE time_series_imports ADD COLUMN deleted_observation_count INTEGER NOT NULL DEFAULT 0;
```

Before the upsert, count incoming rows by left-joining canonical series/observations. “Same” is null-safe equality across `observed_at_us`, `ended_at_us`, `numeric_value`, `categorical_value`, and byte-identical normalized `metadata_json`; series identity is already validated separately. Use the same predicate in the write:

```sql
ON CONFLICT (series_id, source_record_key) DO UPDATE SET
  observed_at_us = excluded.observed_at_us,
  ended_at_us = excluded.ended_at_us,
  numeric_value = excluded.numeric_value,
  categorical_value = excluded.categorical_value,
  ingested_at_us = excluded.ingested_at_us,
  metadata_json = excluded.metadata_json
WHERE observations.observed_at_us IS NOT excluded.observed_at_us
   OR observations.ended_at_us IS NOT excluded.ended_at_us
   OR observations.numeric_value IS NOT excluded.numeric_value
   OR observations.categorical_value IS NOT excluded.categorical_value
   OR observations.metadata_json IS NOT excluded.metadata_json
```

For append imports set deleted to zero without running replacement SQL. For snapshots count rows absent from the spool before deletion. Persist all counters in the receipt transaction; `imported_observation_count` remains the unique spool row count and `duplicate_observation_count` is the in-spool collapse count.

- [ ] **Step 6: Implement and attach the sanitized projection**

Define a `Data` value that accepts only nonnegative integers and satisfies `imported == inserted + unchanged + changed`:

```ruby
TimeSeriesImportProjection = Data.define(
  :imported, :inserted, :duplicate, :unchanged, :changed, :deleted,
  :stored_series, :stored_observations
) do
  def self.from_receipt(receipt)
    new(
      imported: receipt.imported_observation_count,
      inserted: receipt.inserted_observation_count,
      duplicate: receipt.duplicate_observation_count,
      unchanged: receipt.unchanged_observation_count,
      changed: receipt.changed_observation_count,
      deleted: receipt.deleted_observation_count,
      stored_series: receipt.stored_series_count,
      stored_observations: receipt.stored_observation_count
    )
  end
end
```

Extend `TimeSeriesWriterEvent` with `:projection`. `process_import` constructs it from the receipt; acknowledgement, purge, and every failure pass `projection: nil`. The projection must contain no metadata/digest/path accessor.

- [ ] **Step 7: Run focused substrate tests**

Delegate to Luna-medium:

```bash
bundle exec ruby -Itest test/time_series_spool_test.rb
bundle exec ruby -Itest test/time_series_persistence_test.rb
bundle exec ruby -Itest test/time_series_import_projection_test.rb
bundle exec ruby -Itest test/time_series_fetch_result_test.rb
bundle exec ruby -Itest test/time_series_writer_test.rb
bundle exec ruby -Itest test/time_series_reconciler_test.rb
```

Expected: PASS; unchanged conflicts do not update ingestion times, snapshot behavior still works for non-Apple sources, and all writer events satisfy the new shape.

- [ ] **Step 8: Commit the append substrate checkpoint**

```bash
git add lib/cybort.rb lib/cybort/time_series_import_projection.rb \
  lib/cybort/time_series_spool_artifact.rb lib/cybort/time_series_spool.rb \
  lib/cybort/time_series_schema.rb lib/cybort/time_series_import_receipt.rb \
  lib/cybort/time_series_persistence.rb lib/cybort/time_series_writer.rb \
  test/time_series_import_projection_test.rb test/time_series_fetch_result_test.rb \
  test/time_series_spool_test.rb test/time_series_persistence_test.rb \
  test/time_series_writer_test.rb test/time_series_reconciler_test.rb
git commit -m "Make time-series appends no-op aware"
```

---

### Task 3: Define Apple Health configuration and safe errors

**Files:**
- Create: `lib/cybort/apple_health_error.rb`
- Create: `test/apple_health_error_test.rb`
- Create: `lib/cybort/adapters/apple_health.rb`
- Create: `test/adapters/apple_health_test.rb`
- Modify: `lib/cybort/adapter_registry.rb`
- Modify: `lib/cybort.rb`
- Modify: `test/adapter_registry_test.rb`
- Modify: `test/configuration_test.rb`
- Modify: `test/cybort_boot_test.rb`

**Interfaces:**
- Produces: `Cybort::AppleHealthError.new(phase:, category:, candidate_ordinal: nil, limit_name: nil, counts: {})` with `#safe_metadata`.
- Produces: `Adapters::AppleHealth.validate_configuration!(instance) -> nil` without filesystem access.
- Changes: `AdapterRegistry#register(..., max_instances: nil)` and collection validation enforce the registered maximum.
- Defers: default-registry enablement until Task 10, where registration and canonical template/README updates land in the same checkpoint.

- [ ] **Step 1: Write failing configuration and taxonomy tests**

Construct `Configuration::Instance` values directly and assert:

```ruby
valid = Cybort::Configuration::Instance.new(
  id: "health", name: "Apple Health", adapter: "apple_health",
  ttl_minutes: 1_440, num_items_to_fetch: 1,
  retention_ttl_minutes: nil, hard_expiry_ttl_minutes: nil,
  options: { directory: "~/Library/Mobile Documents/com~apple~CloudDocs/Health Exports" }
)
registry.register(
  "apple_health", Cybort::Adapters::AppleHealth,
  result_kind: :time_series, max_instances: 1
)
registry.validate_configuration!(valid)
assert_equal :time_series, registry.result_kind_for(valid)
assert_empty registry.dependencies_for(valid)
```

Reject missing/blank/non-string/relative/environment/glob/control-character/over-4,096-byte `directory`, unknown adapter options, fetch limit other than 1, either retention option, and two Apple instances in either hash order. Put `PATH_SENTINEL`, `FILE_SENTINEL.zip`, an XML fragment, and a raw exception message into an `AppleHealthError` input and assert only `source`, `phase`, `category`, bounded ordinal, approved limit name, and nonnegative aggregate counts survive.

- [ ] **Step 2: Run focused tests and verify registration is missing**

Delegate to Luna-medium:

```bash
bundle exec ruby -Itest test/apple_health_error_test.rb
bundle exec ruby -Itest test/adapters/apple_health_test.rb
bundle exec ruby -Itest test/adapter_registry_test.rb
bundle exec ruby -Itest test/configuration_test.rb
```

Expected: FAIL because the error/adapter constants and registry instance-maxima contract are undefined.

- [ ] **Step 3: Implement the closed safe-error contract**

Use only these public values:

```ruby
PHASES = %i[directory acquisition zip probe parse normalize spool persistence acknowledgement].freeze
CATEGORIES = %i[
  directory_unavailable directory_unsafe too_many_archives archive_size_limit
  archive_changed_during_acquisition archive_acquisition_timeout invalid_zip
  encrypted_zip unsupported_compression zip_resource_limit missing_export_xml
  duplicate_export_xml invalid_export_root unsafe_xml malformed_xml
  unsupported_export_schema invalid_record record_resource_limit
  invalid_timestamp spool_failure time_series_persistence_failure
  receipt_acknowledgement_pending normalizer_migration_required
].freeze
LIMIT_NAMES = %i[
  archive_count compressed_bytes entry_count entry_name_bytes
  total_uncompressed_bytes export_xml_bytes expansion_ratio distinct_series
  record_attributes metadata_entries field_bytes record_bytes parser_depth
  dtd_declarations dtd_bytes non_record_text_bytes pre_export_date_bytes
].freeze
```

Normalize counts to at most 32 allowlisted keys with nonnegative integer values. Never incorporate a rescued library/system exception's message into `safe_metadata` or the user-visible error string.

- [ ] **Step 4: Implement static validation and global cardinality**

In `Adapters::AppleHealth.validate_configuration!`, require exactly `{ directory: path }`, enforce common-field rules, and accept only `path.start_with?("/", "~/")` with no `$`, backtick, `*`, `?`, `[`, `]`, `{`, `}`, NUL/C0/DEL, or blank value. `~/` is the only tilde form. Do not call `File`, `Dir`, `Pathname#realpath`, or the acquisition class here.

Extend registry entries:

```ruby
Entry = Struct.new(
  :factory, :dependencies, :validator, :display_name, :item_noun,
  :result_kind, :max_instances, keyword_init: true
)

def register(name, adapter_factory, dependencies: [], validate_configuration: nil,
             display_name: nil, item_noun: "items", result_kind: :items,
             max_instances: nil)
  raise ArgumentError unless max_instances.nil? || (max_instances.is_a?(Integer) && max_instances.positive?)
  # preserve the existing result-kind and keyword checks
end
```

After per-instance validators run, group the configured instances by adapter and raise one deterministic `ConfigurationError` when a registered `max_instances` is exceeded. In tests, register `Adapters::AppleHealth` on a fresh registry with `result_kind: :time_series, max_instances: 1`; do not add it to `AdapterRegistry.default` until Task 10 publishes the configuration template and README in the same change.

- [ ] **Step 5: Add the adapter constructor boundary**

Create a nonfunctional constructor now so registration and keyword injection are reviewable before source access:

```ruby
def initialize(instance:, context:, clock:, monotonic_clock:, spool_factory:,
               archive_acquirer: nil, zip_inspector: nil, parser_factory: nil,
               **_unused)
  @instance = instance
  @context = context
  @clock = clock
  @monotonic_clock = monotonic_clock
  @spool_factory = spool_factory
  @archive_acquirer = archive_acquirer
  @zip_inspector = zip_inspector
  @parser_factory = parser_factory
end
```

Its temporary `fetch` raises `NotImplementedError`; no default collaborator opens the configured directory until Task 7.

- [ ] **Step 6: Run focused tests**

Delegate to Luna-medium:

```bash
bundle exec ruby -Itest test/apple_health_error_test.rb
bundle exec ruby -Itest test/adapters/apple_health_test.rb
bundle exec ruby -Itest test/adapter_registry_test.rb
bundle exec ruby -Itest test/configuration_test.rb
bundle exec ruby -Itest test/cybort_boot_test.rb
```

Expected: PASS for validation, safe metadata, custom-registry construction, one-instance enforcement, and boot loading; no filesystem/network collaborator is invoked, and the default registry still does not enable the unfinished connector.

- [ ] **Step 7: Commit the registration checkpoint**

```bash
git add lib/cybort.rb lib/cybort/apple_health_error.rb \
  lib/cybort/adapters/apple_health.rb lib/cybort/adapter_registry.rb \
  test/apple_health_error_test.rb test/adapters/apple_health_test.rb \
  test/adapter_registry_test.rb test/configuration_test.rb test/cybort_boot_test.rb
git commit -m "Define the Apple Health adapter contract"
```

---

### Task 4: Acquire stable private archive copies behind a killable helper

**Files:**
- Create: `script/apple_health_archive_copy_helper.rb`
- Create: `lib/cybort/apple_health_archive_acquirer.rb`
- Create: `test/apple_health_archive_acquirer_test.rb`
- Modify: `lib/cybort.rb`

**Interfaces:**
- Produces: `AppleHealthAcquiredArchive = Data.define(:path, :archive_sha256, :compressed_bytes, :source_started_at)`; `#path` is private internal state and is never serialized.
- Produces: `AppleHealthArchiveAcquirer.new(temp_directory:, wall_clock:, monotonic_clock:, timeout_seconds: 600, process_supervisor: nil)`.
- Produces: `AppleHealthArchiveAcquirer#validate_directory(path) -> { path:, warnings: [] }` and `#candidate_paths(directory:) -> Array<String>`.
- Produces: `AppleHealthArchiveAcquirer#acquire(source_path:, candidate_ordinal:) -> AppleHealthAcquiredArchive`, `#release(archive) -> nil`, and `#cleanup_orphans! -> self`.
- Produces: fixed helper protocol on stdin/stdout: one length-prefixed JSON request `{source_path,target_path,captured_stat}` and one bounded JSON response `{status,sha256,bytes,opened_stat,finished_stat}`.

- [ ] **Step 1: Write failing runtime-directory and candidate-enumeration tests**

Use a temporary source and a separate installation `tmp/`. Cover absolute and expanded `~/` paths, unavailable paths, directory symlinks, wrong owner through an injected stat provider, group/other write bits, broader read-bit warnings, hidden/mixed-case ZIPs, byte-order sorting, nonrecursive discovery, zero candidates, 129 candidates, and ZIP-named symlink/directory/special/wrong-owner/writable children.

```ruby
result = acquirer.validate_directory(source)
assert_equal File.expand_path(source), result.fetch(:path)

File.write(File.join(source, "b.ZIP"), "b")
File.write(File.join(source, ".a.zip"), "a")
Dir.mkdir(File.join(source, "child"))
File.write(File.join(source, "child", "ignored.zip"), "ignored")
assert_equal [".a.zip", "b.ZIP"],
  acquirer.candidate_paths(directory: source).map { |path| File.basename(path) }
```

Errors must carry only category/phase/ordinal/limit metadata; assert no absolute source or child name appears.

- [ ] **Step 2: Write failing stable-copy, change, timeout, and cleanup tests**

Use a queue-controlled injected supervisor for unit tests and the real fixed helper for one small-file contract test. Assert the destination is beneath installation `tmp/`, mode `0600`, SHA-256 covers all compressed bytes, the source is unchanged, and the helper protocol result has no path in safe metadata.

Coordinate these cases without sleeps:

```ruby
copy_started.pop
File.rename(replacement_path, source_path)
release_copy << true
error = worker.value
assert_equal :archive_changed_during_acquisition, error.safe_metadata.fetch(:category)
refute File.exist?(captured_private_copy)
```

Cover replacement, inode/device change, size/mtime-nanosecond/ctime-nanosecond change, short read, growth, disappearance, unreadable source, final-source symlink, helper abnormal exit, timeout, and `Interrupt`. For timeout, assert `SIGKILL` is sent exactly once, `waitpid` reaps the PID, the response pipe closes, and the partial copy is absent. Create two matching orphan-prefix regular files plus a symlink/directory and assert startup deletes only the regular files.

- [ ] **Step 3: Run acquisition tests and verify missing constants fail**

Delegate to Luna-medium:

```bash
bundle exec ruby -Itest test/apple_health_archive_acquirer_test.rb
```

Expected: FAIL because the acquirer/helper protocol does not exist.

- [ ] **Step 4: Implement the fixed copy-only helper**

The helper accepts no source path in `ARGV`, closes unrelated descriptors, and performs only this sequence:

```ruby
request = read_length_prefixed_json($stdin, maximum_bytes: 16_384)
source = File.open(request.fetch("source_path"), File::RDONLY | File::NOFOLLOW)
opened = stat_projection(source.stat)
target = File.open(request.fetch("target_path"), File::WRONLY | File::CREAT | File::EXCL, 0o600)
digest = Digest::SHA256.new
bytes = 0
while (chunk = source.read(1024 * 1024))
  target.write(chunk)
  digest.update(chunk)
  bytes += chunk.bytesize
end
target.flush
target.fsync
finished = stat_projection(source.stat)
path_stat = stat_projection(File.lstat(request.fetch("source_path")))
write_length_prefixed_json($stdout, status: "ok", sha256: digest.hexdigest,
  bytes: bytes, opened_stat: opened, finished_stat: finished, path_stat: path_stat)
```

`stat_projection` contains device, inode, size, `mtime.nsec`, and `ctime.nsec`. Compare parent-captured, opened, finished, and path projections plus copied byte count. The child returns only closed status codes (`changed`, `unreadable`, `unsafe`) and never writes exception text. It never loads `cybort.rb`, SQLite, ZIP/XML libraries, configuration, or adapter code.

- [ ] **Step 5: Implement parent supervision and private-copy lifecycle**

Use `Process.spawn(RbConfig.ruby, HELPER_PATH, in: request_reader, out: response_writer, err: File::NULL, close_others: true)` with source/target paths sent through the bounded pipe protocol. Choose a cryptographically random target pathname under `temp_directory` with prefix `cybort-apple-health-archive-`; never derive it from a source filename. The child alone creates that path with `O_EXCL`, and a collision returns a closed failure that removes no pre-existing object.

```ruby
deadline = @monotonic_clock.call + @timeout_seconds
loop do
  remaining = deadline - @monotonic_clock.call
  timeout! if remaining <= 0
  break if IO.select([response_reader], nil, nil, remaining)
end
response = read_length_prefixed_json(response_reader, maximum_bytes: 16_384)
_, status = Process.wait2(pid)
```

On timeout call `Process.kill("KILL", pid)` (ignore only `Errno::ESRCH`), then `Process.waitpid(pid)` (ignore only `Errno::ECHILD`) in `ensure`. All success/error/interrupt paths close pipes and remove partial files. `release` lstat-checks the exact acquired object path, removes only a regular non-symlink with the reserved prefix, and is idempotent.

- [ ] **Step 6: Run acquisition and boot tests**

Delegate to Luna-medium:

```bash
bundle exec ruby -Itest test/apple_health_archive_acquirer_test.rb
bundle exec ruby -Itest test/cybort_boot_test.rb
```

Expected: PASS; real helper copying remains bounded, timeout/replacement paths are reaped and clean, and no test touches iCloud.

- [ ] **Step 7: Commit the acquisition checkpoint**

```bash
git add lib/cybort.rb lib/cybort/apple_health_archive_acquirer.rb \
  script/apple_health_archive_copy_helper.rb test/apple_health_archive_acquirer_test.rb
git commit -m "Acquire stable Apple Health archives"
```

---

### Task 5: Inventory ZIPs strictly and expose a bounded export stream

**Files:**
- Create: `lib/cybort/apple_health_zip.rb`
- Create: `test/support/apple_health_fixture.rb`
- Create: `test/apple_health_zip_test.rb`
- Create: `test/fixtures/apple_health/export_basic.xml`
- Modify: `lib/cybort.rb`

**Interfaces:**
- Produces: `AppleHealthArchiveCandidate = Data.define(:acquired_archive, :export_entry_name, :exported_at, :inventory)`.
- Produces: `AppleHealthZipInspector.new(parser_factory:, limits: AppleHealthZipInspector::LIMITS)`.
- Produces: `AppleHealthZipInspector#inspect(acquired_archive) -> AppleHealthArchiveCandidate` after complete inventory and `ExportDate` probe.
- Produces: `AppleHealthExportStreamResult = Data.define(:payload, :export_xml_sha256, :export_xml_bytes)` and `AppleHealthZipInspector#with_export_stream(candidate) { |io| payload } -> AppleHealthExportStreamResult`; checksum/truncation and actual-byte validation finish before return.
- Produces: `AppleHealthFixture.write_zip(path:, entries:, wrapper: nil, export_xml:, mutation: nil)` for synthetic tests only.

- [ ] **Step 1: Build the deterministic fixture helper and failing happy-path tests**

Generate ZIPs in temporary directories with fixed timestamps and explicit STORE/DEFLATE methods. The initial XML fixture must contain one `HealthData` root and one offset-bearing `ExportDate`, but ZIP tests stop after the injected probe:

```ruby
archive = fixture_archive(
  export_xml: File.binread(fixture("apple_health/export_basic.xml")),
  wrapper: "apple_health_export",
  entries: { "electrocardiograms/ecg.csv" => "CRC_SENTINEL" }
)
candidate = inspector.inspect(acquired(archive))
assert_equal "apple_health_export/export.xml", candidate.export_entry_name
assert_equal Time.iso8601("2026-09-11T12:00:00-04:00"), candidate.exported_at

result = inspector.with_export_stream(candidate) { |io| io.read }
assert_equal Digest::SHA256.hexdigest(File.binread(fixture("apple_health/export_basic.xml"))),
  result.fetch(:export_xml_sha256)
```

Assert the ECG body is never opened by placing a test double on `Zip::Entry#get_input_stream` that raises if called for any non-export entry.

- [ ] **Step 2: Write failing ZIP-security and resource-ceiling tests**

Use named builder/mutator methods in `AppleHealthFixture`: `patch_local_name`, `patch_central_size`, `patch_flags`, `patch_method`, `truncate_bytes`, and `corrupt_entry_crc`. Cover exactly:

- root and one-wrapper `export.xml`, alternate wrapper names, missing and duplicate export entries;
- absolute POSIX paths, drive-letter paths, backslashes, NUL, invalid UTF-8, `.`/`..`/empty segments, names over 1,024 bytes, and duplicate NFC-normalized names;
- symlink/device/FIFO-like Unix external attributes, encrypted flags, unsupported method 12, local/central name/method/flag mismatch, invalid EOCD/ZIP64/local offsets, truncated central/local headers, and data-descriptor inconsistency;
- 4-GiB compressed, 100,000-entry, 16-GiB declared total, 12-GiB declared/actual export, and 200:1 ratio boundaries, including exact-limit acceptance and one-over rejection;
- selected-entry CRC corruption, selected-entry truncation, lying uncompressed size, and an `export.xml` body beginning with ZIP magic;
- an unsupported clinical/ECG/GPX entry with a bad body CRC that is inventoried by declared size/type without opening or decompressing its body.

For each failure assert its exact category (`invalid_zip`, `encrypted_zip`, `unsupported_compression`, `zip_resource_limit`, `missing_export_xml`, or `duplicate_export_xml`), phase, optional limit name, and absence of source/entry names, raw bytes, Rubyzip messages, and sentinel content.

- [ ] **Step 3: Run the ZIP test and verify the implementation is absent**

Delegate to Luna-medium:

```bash
bundle exec ruby -Itest test/apple_health_zip_test.rb
```

Expected: FAIL because `AppleHealthZipInspector` and the fixture helpers are undefined.

- [ ] **Step 4: Implement inventory and local-header validation**

Open the private copy with `Zip::File.open(path)` and enforce the central-directory limits before probing. Accept only STORE (`0`) and DEFLATE (`8`); reject general-purpose encryption bits and unsupported compression before any body stream is requested.

Normalize each entry name as valid NFC UTF-8 with `/` separators; reject absolute/drive-letter/backslash/NUL and any empty, `.`, or `..` segment. Keep only the bounded central-directory entry array already permitted by the 100,000-entry ceiling plus a set of normalized names. Inspect Unix mode bits and accept only regular files/directories.

For every entry, seek to its `local_header_offset` in a separate read-only `File`, parse the fixed 30-byte little-endian local header, then read bounded name/extra fields. Compare signature, flags, method, normalized name, and—when data-descriptor bit 3 is clear—CRC/compressed/uncompressed sizes with the central entry. When bit 3 is set, validate the descriptor at `local_header_offset + header_bytes + compressed_size`, accepting only the standard signed/unsigned 32-bit or ZIP64 shape that matches the central values. Reject offsets/ranges outside the acquired file before seeking.

Compute declared totals with overflow-safe integer addition and:

```ruby
ratio = total_uncompressed.fdiv([total_compressed, 1].max)
raise_limit(:expansion_ratio) if ratio > 200.0
```

Require exactly one regular normalized entry with one or two path segments and basename `export.xml`. Inventory all other entries into bounded family counters and declared byte totals only.

- [ ] **Step 5: Implement probe and full-stream boundaries**

`inspect` opens only the selected entry and passes a byte-counting stream to `parser_factory.call.probe(io)`. It stops immediately after the root and unique `ExportDate` are validated; this probe does not claim full CRC validation.

`with_export_stream` reopens the entry, wraps it in an IO that updates SHA-256 and both 12-GiB export/16-GiB total actual counters on every `read`, and yields it to the full parser. After the block, drain to EOF only if the parser completed normally, then require actual size to equal the central value and let Rubyzip finish CRC/data-descriptor validation. Map every Rubyzip/Zlib/EOF error to a closed `AppleHealthError` without its raw message. The wrapper exposes `#read(length = nil, outbuf = nil)` only and never creates an extracted XML file.

- [ ] **Step 6: Run ZIP and acquisition tests**

Delegate to Luna-medium:

```bash
bundle exec ruby -Itest test/apple_health_zip_test.rb
bundle exec ruby -Itest test/apple_health_archive_acquirer_test.rb
```

Expected: PASS; unsupported bodies remain unopened, the selected body is checksum-validated, and every decompression read comes from installation `tmp/`.

- [ ] **Step 7: Commit the ZIP checkpoint**

```bash
git add lib/cybort.rb lib/cybort/apple_health_zip.rb \
  test/support/apple_health_fixture.rb test/apple_health_zip_test.rb \
  test/fixtures/apple_health/export_basic.xml
git commit -m "Validate Apple Health ZIP archives"
```

---

### Task 6: Stream and normalize supported XML records into the spool

**Files:**
- Create: `lib/cybort/apple_health_canonical.rb`
- Create: `lib/cybort/apple_health_export_parser.rb`
- Create: `test/apple_health_canonical_test.rb`
- Create: `test/apple_health_export_parser_test.rb`
- Create: `test/fixtures/apple_health/export_overlap_one.xml`
- Create: `test/fixtures/apple_health/export_overlap_two.xml`
- Create: `test/fixtures/apple_health/export_empty.xml`
- Create: `test/fixtures/apple_health/export_unsupported_only.xml`
- Create: `test/fixtures/apple_health/export_schema_drift.xml`
- Create: `test/fixtures/apple_health/export_entities.xml`
- Create: `test/fixtures/apple_health/export_malformed.xml`
- Modify: `lib/cybort.rb`

**Interfaces:**
- Produces: `AppleHealthTimestamp = Data.define(:time, :utc_microseconds, :offset_minutes)` and `AppleHealthDecimal = Data.define(:numeric_value, :identity)`.
- Produces: `AppleHealthCanonical.parse_timestamp(value, field:)`, `.parse_decimal(value)`, `.series_definition(attributes)`, and `.normalize_record(attributes:, metadata_entries:) -> AppleHealthNormalizedRecord`.
- Produces: `AppleHealthNormalizedRecord = Data.define(:series_key, :metric_key, :value_type, :canonical_unit, :dimensions, :source_record_key, :observed_at, :ended_at, :numeric_value, :categorical_value, :metadata)`.
- Produces: `AppleHealthExportParser#probe(io) -> { exported_at: Time }` and `#parse(io, spool_writer:) -> AppleHealthParseSummary`.
- Produces: `AppleHealthParseSummary` readers for `exported_at`, `export_xml_bytes`, `top_level_record_count`, `imported_record_count`, `duplicate_record_count`, `distinct_series_count`, and frozen bounded `family_counts`.

- [ ] **Step 1: Write failing canonical timestamp/decimal/key tests**

Test `Z`, positive, and negative offsets, 0–9 fractional digits, UTC-microsecond flooring, preserved offset minutes, missing offsets, invalid calendar values, end-before-start, and SQLite integer overflow. Decimal cases include `1`, `1.0`, `01e0`, `-0`, finite extremes, NaN/Infinity, locale commas, booleans/trailing text, over-4,096-byte coefficient, and exponent magnitude over 100,000.

```ruby
a = Cybort::AppleHealthCanonical.parse_decimal("1.0")
b = Cybort::AppleHealthCanonical.parse_decimal("01e0")
assert_equal a.identity, b.identity
assert_equal 1.0, a.numeric_value

timestamp = Cybort::AppleHealthCanonical.parse_timestamp(
  "2026-03-08 01:59:59.123456789 -0500", field: :start_date
)
assert_equal(-300, timestamp.offset_minutes)
assert_equal 123_456, timestamp.utc_microseconds % 1_000_000
```

Build reordered attribute/metadata inputs and assert identical series/record keys; vary type, source/device, any timestamp/offset, numeric/category value, unit, or metadata pair and assert a different record key. Assert archive digest, filename, XML/document order, and metadata order never enter the key. Assert source/device/free metadata occur in neither dimensions nor stored metadata.

- [ ] **Step 2: Write failing SAX structure, security, and resource tests**

Use the exact fixture set above plus generated one-record variants. Cover:

- one UTF-8 XML declaration, one `HealthData` root, one early offset-bearing `ExportDate`, closed root, EOF, and no trailing document;
- quantity/category points and intervals, category strings that look numeric, distinct units as distinct series, NFC normalization, attribute reordering, metadata reordering, exact duplicate collapse, and same-key/different-payload defense;
- `<Me>` discard, supported top-level/recognized nested-family counters, specialized child causing whole-record exclusion, unknown type-prefix unsupported count, and unknown governed child/namespace/wrapper failure;
- required attribute absence, contradictory category unit, missing quantity unit, invalid numeric/date/UTF-8, nonfinite value, and end-before-start;
- direct metadata allowlist: `HKWasUserEntered` parses only `true`/`false` or `1`/`0`, `HKMetadataKeySyncVersion` is an integer in `0..2_147_483_647`, and conflicting duplicates fail; every other bounded pair affects identity then is discarded;
- exact boundaries and one-over cases for attributes, metadata entries, field bytes, record bytes, depth, name bytes, DTD declarations/bytes, non-record text, pre-`ExportDate` bytes, and 100,000 distinct series;
- internal Apple DTD with only `ELEMENT`/`ATTLIST` declarations accepted; `SYSTEM`, `PUBLIC`, `ENTITY`, parameter entity, entity reference other than XML's predefined five, XInclude, processing instruction, recovery-requiring XML, parser warning/error, and a second root rejected as `unsafe_xml` or `malformed_xml`.

For a valid zero-record fixture assert success with zero rows. For `export_unsupported_only.xml`, assert `unsupported_export_schema` because top-level record count is nonzero and imported count is zero.

- [ ] **Step 3: Run parser tests and verify the implementation is absent**

Delegate to Luna-medium:

```bash
bundle exec ruby -Itest test/apple_health_canonical_test.rb
bundle exec ruby -Itest test/apple_health_export_parser_test.rb
```

Expected: FAIL because canonical and parser constants are undefined.

- [ ] **Step 4: Implement canonical encodings and normalized records**

Validate UTF-8, normalize all governed strings with `unicode_normalize(:nfc)`, and encode identity fields as tag/length/value bytes:

```ruby
def encode_fields(fields)
  fields.sort_by(&:first).map do |tag, value|
    bytes = value.nil? ? "".b : value.to_s.encode(Encoding::UTF_8).b
    [tag.bytesize].pack("N") + tag.b + [bytes.bytesize].pack("Q>") + bytes
  end.join
end

def digest_key(prefix, fields)
  "#{prefix}#{Digest::SHA256.hexdigest(encode_fields(fields))}"
end
```

Use `BigDecimal#split` to encode sign, coefficient with insignificant leading/trailing zero normalization, and base-10 exponent without expanding it. Convert to Float only after lexical/bound checks and reject nonfinite output. Parse timestamps with an explicit terminal `Z` or `[+-]HHMM`/`[+-]HH:MM`, at most nine fractional digits, valid offset under 24 hours, rational time arithmetic, and floor to UTC microseconds.

Series tuple is `record`, exact type, `numeric|categorical`, and normalized unit/nil. Dimensions are exactly `{ "record_family" => "record", "apple_type" => type }`. Record digest fields include normalized optional `sourceName`, `sourceVersion`, and `device` plus required `creationDate`, `startDate`, `endDate`, value family/value/unit, and every sorted direct metadata pair. Stored metadata contains only `start_offset_minutes`, `end_offset_minutes`, `creation_offset_minutes`, optional `user_entered`, and optional `synchronization_version`.

- [ ] **Step 5: Implement strict SAX state and bounded DTD/entity guard**

Subclass `Nokogiri::XML::SAX::Document`. Feed it through `Nokogiri::XML::SAX::Parser#parse_io` with `ParserContext#recovery = false` and `#replace_entities = false`; keep network/external subset loading disabled. Implement `#reference` to reject every non-predefined entity, `#external_subset` to reject unconditionally, and fatal `#warning`/`#error` callbacks that raise sanitized errors.

Place a constant-memory prolog guard in front of SAX that tracks comments, quoted declaration values, declaration nesting, and the configured DTD budgets. It accepts only one internal `DOCTYPE HealthData [...]` containing `ELEMENT` and `ATTLIST` declarations; it rejects `SYSTEM`, `PUBLIC`, `ENTITY`, `%`, external identifiers, and any second declaration before libxml sees them. The guard operates on chunk boundaries and never retains more than the current bounded declaration.

The document handler keeps only root/depth state, counters, one current record attribute hash, one metadata-pair array, and the spool's existing distinct-series map. On each supported record close, call `register_series` (idempotently) and `add_observation`; increment duplicate count only from a `:duplicate` return. Abort the entire parse on any governed-record error. Require parser completion, ZIP entry EOF, root closure, and exact one `ExportDate` before returning the frozen summary.

- [ ] **Step 6: Run canonical, parser, spool, and ZIP tests**

Delegate to Luna-medium:

```bash
bundle exec ruby -Itest test/apple_health_canonical_test.rb
bundle exec ruby -Itest test/apple_health_export_parser_test.rb
bundle exec ruby -Itest test/apple_health_zip_test.rb
bundle exec ruby -Itest test/time_series_spool_test.rb
```

Expected: PASS; attributes/records are streamed, exact duplicates collapse on disk, and no DOM/archive-wide record collection is created.

- [ ] **Step 7: Commit the parser checkpoint**

```bash
git add lib/cybort.rb lib/cybort/apple_health_canonical.rb \
  lib/cybort/apple_health_export_parser.rb test/apple_health_canonical_test.rb \
  test/apple_health_export_parser_test.rb test/fixtures/apple_health/export_overlap_one.xml \
  test/fixtures/apple_health/export_overlap_two.xml test/fixtures/apple_health/export_empty.xml \
  test/fixtures/apple_health/export_unsupported_only.xml \
  test/fixtures/apple_health/export_schema_drift.xml \
  test/fixtures/apple_health/export_entities.xml \
  test/fixtures/apple_health/export_malformed.xml
git commit -m "Stream Apple Health records into spools"
```

---

### Task 7: Select one append candidate and return imported, unchanged, cached, or failed results

**Files:**
- Modify: `lib/cybort/time_series_fetch_result.rb`
- Modify: `lib/cybort/time_series_reader.rb`
- Modify: `lib/cybort/adapters/apple_health.rb`
- Modify: `test/time_series_fetch_result_test.rb`
- Modify: `test/time_series_reader_test.rb`
- Modify: `test/adapters/apple_health_test.rb`

**Interfaces:**
- Changes: `TimeSeriesFetchResult#kind -> :imported | :unchanged | :cached | :failure`, plus `#imported?`, `#unchanged?`, and `#cached?`.
- Produces: `TimeSeriesFetchResult.unchanged(instance_id:, started_at:, finished_at:, metadata:, series_count:, observation_count:)`; it has `source_fetched: true`, `artifact: nil`, and `sync_state: nil`.
- Changes: `TimeSeriesReader#context_for(instance_id:)` adds frozen `import_keys: Array<String>` ordered by import key.
- Produces: `Adapters::AppleHealth#fetch(force_fetch: false, fetch_mode: nil, planned_at: nil) -> TimeSeriesFetchResult`.

- [ ] **Step 1: Write failing result-kind and planning-context tests**

Keep the existing `.success` constructor as the imported-success constructor for compatibility, but assert all four exclusive shapes:

```ruby
unchanged = Cybort::TimeSeriesFetchResult.unchanged(
  instance_id: "health", started_at: @started, finished_at: @finished,
  metadata: { "archive_unchanged" => true }, series_count: 12,
  observation_count: 1_500_000
)
assert unchanged.success?
assert unchanged.unchanged?
assert unchanged.source_fetched
assert_nil unchanged.artifact
assert_nil unchanged.sync_state
```

Reject an unchanged result with an artifact/state, a cached result with `source_fetched: true`, an imported result without an artifact, or any inconsistent kind/count/time combination. Import two receipts into the time-series database and assert reader context includes both exact import keys, current counts/state, no receipt metadata, and no artifact digest/path.

- [ ] **Step 2: Write failing adapter cache, discovery, and selection tests**

Use injected acquirer/inspector/parser/spool collaborators with call logs. Cover:

- a TTL cache plan returns `:cached` with stored counts/state and makes zero directory/acquisition/ZIP/parser/spool calls;
- `--force-fetch` reacquires and hashes every candidate even when all are known;
- all immediate-child candidates are acquired and inspected in filename-byte order;
- selection prioritizes unseen over seen, then greatest UTC `ExportDate`, then lexically greatest archive SHA-256; filename/mtime/size do not affect selection;
- an unseen older archive remains selected on a later run after the newer archive's key is durable;
- all-seen selection returns `:unchanged`, with no full parser/spool/writer artifact and unchanged stored counts;
- a byte-identical renamed archive is unchanged, while a repackaged archive with a new archive SHA is parsed and appended;
- any candidate error releases current/best copies and fails without parsing or falling back to a previously valid candidate;
- at most best-plus-current private copies coexist, the superseded copy is released immediately, the selected copy changes to `0400` before full parsing, and all copies/spools are removed after success, parser/spool failure, and interruption;
- source/result metadata has bounded candidate/family/record counts but no path, filename, full/partial digest, profile, raw value, source/device string, metadata pair, or XML/library message.

Use explicit candidate data to lock the ordering rule:

```ruby
candidates = [
  candidate(name: "z.zip", exported_at: Time.utc(2026, 9, 12), sha: "1" * 64, seen: true),
  candidate(name: "a.zip", exported_at: Time.utc(2026, 9, 10), sha: "f" * 64, seen: false),
  candidate(name: "m.zip", exported_at: Time.utc(2026, 9, 10), sha: "e" * 64, seen: false)
]
assert_equal "f" * 64, adapter.send(:select_candidate, candidates).archive_sha256
```

- [ ] **Step 3: Write failing real-spool overlap and normalizer-migration tests**

Drive generated ZIPs through the real inspector/parser/spool, but use the injected acquirer to avoid subprocess concerns. First import `export_overlap_one.xml`, then present `export_overlap_two.xml`, which must contain exactly one unchanged identity, one inserted identity, one corrected identity (old and new both retained), one omitted identity (retained), and one exact duplicate element (collapsed in the spool).

Assert the second artifact uses append mode and:

```ruby
assert_equal "apple-health-import-v1:#{archive_sha256}", result.artifact.import_key
assert_equal :append, result.artifact.import_mode
assert_equal 3, result.artifact.observation_count
assert_equal 1, result.artifact.duplicate_observation_count
assert_equal 1, result.metadata.fetch("duplicate")
```

Set persisted state `normalizer_version` to 2 or remove version from nonempty Apple state and assert `normalizer_migration_required` before acquisition/spooling. A fresh instance with no state remains valid.

- [ ] **Step 4: Run focused tests and verify result/adapter failures**

Delegate to Luna-medium:

```bash
bundle exec ruby -Itest test/time_series_fetch_result_test.rb
bundle exec ruby -Itest test/time_series_reader_test.rb
bundle exec ruby -Itest test/adapters/apple_health_test.rb
```

Expected: FAIL because unchanged results, receipt-key planning context, and adapter source flow are absent.

- [ ] **Step 5: Implement the explicit result variants and receipt-key context**

Give every result an immutable `kind`. Preserve `.success(...)` as `kind: :imported`, make `.cached` `source_fetched: false`, and make `.failure` zero-count/no-state. `.unchanged` is the only success that combines `source_fetched: true` with no artifact and no synchronization state.

Extend the reader with a second bounded-row query:

```ruby
import_keys = @database.execute(
  "SELECT import_key FROM time_series_imports WHERE adapter_instance_id = ? ORDER BY import_key",
  [instance_id]
).map { |row| row.fetch("import_key").dup.freeze }.freeze
```

Merge this into the existing deep-frozen context. Do not expose receipt `metadata_json`, artifact digest, acknowledgement time, or canonical connection to the adapter.

- [ ] **Step 6: Implement deterministic candidate draining and append finalization**

At remote fetch start, reject non-v1/nonempty state before source access. Validate/expand the directory once, enumerate candidates, and maintain one best candidate while scanning:

```ruby
priority = [known_import_keys.include?(import_key) ? 0 : 1,
            candidate.exported_at.to_r, candidate.archive_sha256]
if best.nil? || (priority <=> best_priority) == 1
  acquirer.release(best.acquired_archive) if best
  best = candidate
  best_priority = priority
else
  acquirer.release(candidate.acquired_archive)
end
```

On any acquisition/inspection error, release both current and best and return a failure; never continue to an older fallback. If best is known, release it and return `.unchanged` with only safe discovery counts.

For unseen best, set the acquired copy to `0400`, open a spool with:

```ruby
import_key = "apple-health-import-v1:#{best.acquired_archive.archive_sha256}"
writer = spool_factory.open(
  instance_id: instance.id, import_key: import_key, import_mode: :append,
  source_started_at: started_at
)
```

Stream full XML through `with_export_stream` and parser. Final synchronization state is:

```ruby
{
  "state_version" => 1,
  "normalizer_version" => 1,
  "last_imported_exported_at" => best.exported_at.utc.iso8601(6),
  "last_imported_archive_sha256" => archive_sha256,
  "last_imported_export_xml_sha256" => export_xml_sha256,
  "latest_import_key" => import_key
}
```

Private artifact metadata contains only the approved version/digest/timestamp/byte/entry/family/record/persistence-ready counts from the spec; public result metadata contains only candidate count, supported/unsupported family counts, `imported`, and in-archive `duplicate`. Return the finalized artifact through `.success`. Abort the spool and release the selected copy in every pre-finalization failure; after finalization, writer/orchestrator owns spool deletion.

- [ ] **Step 7: Run adapter, parser, reader, and result tests**

Delegate to Luna-medium:

```bash
bundle exec ruby -Itest test/time_series_fetch_result_test.rb
bundle exec ruby -Itest test/time_series_reader_test.rb
bundle exec ruby -Itest test/adapters/apple_health_test.rb
bundle exec ruby -Itest test/apple_health_export_parser_test.rb
bundle exec ruby -Itest test/apple_health_zip_test.rb
bundle exec ruby -Itest test/apple_health_archive_acquirer_test.rb
```

Expected: PASS; known bytes skip full parsing, repackaged bytes reparse but produce stable observation keys, and every temp path is reclaimed.

- [ ] **Step 8: Commit the adapter checkpoint**

```bash
git add lib/cybort/time_series_fetch_result.rb lib/cybort/time_series_reader.rb \
  lib/cybort/adapters/apple_health.rb test/time_series_fetch_result_test.rb \
  test/time_series_reader_test.rb test/adapters/apple_health_test.rb
git commit -m "Import Apple Health archives append-only"
```

---

### Task 8: Persist unchanged checks and publish safe import outcomes through orchestration

**Files:**
- Modify: `lib/cybort/persistence.rb`
- Modify: `lib/cybort/orchestrator.rb`
- Modify: `test/persistence_test.rb`
- Modify: `test/orchestrator_test.rb`
- Modify: `test/time_series_reconciler_test.rb`
- Modify: `test/system/time_series_orchestration_system_test.rb`
- Create: `test/system/apple_health_system_test.rb`
- Modify: `test/system/cli_system_test.rb`

**Interfaces:**
- Produces: `Persistence#record_time_series_unchanged(result) -> true` for `TimeSeriesFetchResult#unchanged?` only.
- Changes: `Orchestrator#persist_time_series_result` branches imported/unchanged/cached/failure explicitly.
- Changes: successful import status metadata merges `TimeSeriesImportProjection#to_h`; status counts use `stored_series`/`stored_observations`, never private receipt metadata.
- Preserves: receipt acknowledgement and recovery signatures from ADR 0009.

- [ ] **Step 1: Write failing main-persistence unchanged tests**

Register an instance, seed nonempty sync state through a receipt, then record an unchanged check at a later injected clock:

```ruby
assert @persistence.record_time_series_unchanged(unchanged_result)
record = @persistence.instance_record("health")
assert_equal original_sync_state_json, record.fetch("sync_state_json")
assert_equal @now.utc.iso8601(6), record.fetch("last_successful_fetch")
run = @persistence.fetch_runs_for(instance_id: "health").last
assert_equal ["successful", 0], run.values_at("status", "item_count")
```

Assert exactly one main transaction, clamping a future result finish time to one persistence-clock read, no acknowledgement row, no time-series receipt/write, rejection of cached/imported/failed shapes, rejection of unknown instance, and rollback if fetch-history insertion fails. Metadata must say result kind `time_series` and outcome `unchanged` without a digest/path.

- [ ] **Step 2: Write failing orchestrator projection and no-writer tests**

Cover each result kind through a registered test time-series adapter:

- unchanged records one main success and submits zero writer commands;
- cached opens neither directory nor writer import command and does not advance freshness;
- imported submits exactly one append, acknowledges only after receipt, and publishes the writer projection;
- Apple import projection requires `deleted: 0` and `changed: 0`; a nonzero value becomes a source failure before main acknowledgement;
- JSON/diagnostic status contains safe counts but no receipt metadata, archive/XML digest, path, filename, source/device value, raw category value, or XML/library exception;
- acknowledgement-marker failure after durable main success reports `receipt_acknowledgement_pending` without a contradictory failed fetch row;
- parse/persistence failure preserves prior Health observations/freshness and unrelated item-source success.

```ruby
assert_equal({ imported: 3, inserted: 2, duplicate: 1, unchanged: 1,
  changed: 0, deleted: 0, stored_series: 2, stored_observations: 7 },
  status.metadata.slice(:imported, :inserted, :duplicate, :unchanged,
                        :changed, :deleted, :stored_series, :stored_observations))
```

- [ ] **Step 3: Write failing end-to-end append, recovery, and concurrency tests**

In `apple_health_system_test.rb`, create a disposable installation and source directory, generate two overlap ZIPs, and run the real CLI with an injected clock. Assert:

1. First run imports the first ZIP and creates one pending-then-acknowledged receipt.
2. Second run imports the second ZIP: omitted original remains; correction exists beside original; exact overlap is unchanged; duplicate collapses; no rows are deleted; unchanged `ingested_at_us` is stable.
3. Third forced run returns successful unchanged and changes only main freshness/fetch history.
4. A repackaged copy with different ZIP digest creates a receipt but no observation write or ingestion-time change.
5. A malformed candidate added beside a valid one fails the whole source without fallback or canonical/main-state change.
6. A different instance's observations and an ordinary RSS result remain untouched.

Extend receipt crash tests through the real adapter for failure before spool finalization, after canonical append/pending receipt, after main acknowledgement, and during advisory marking. Restart with the source directory removed after canonical commit and assert reconciliation still advances main state exactly once from the receipt.

Use queues around `TimeSeriesPersistence#import` to prove an RSS main commit completes while the Apple writer is blocked. Use the acquisition supervisor's queue hook to prove a blocked helper is killed/reaped at deadline while unrelated item work completes.

- [ ] **Step 4: Run focused/system tests and verify missing orchestration branches fail**

Delegate to Luna-medium:

```bash
bundle exec ruby -Itest test/persistence_test.rb
bundle exec ruby -Itest test/orchestrator_test.rb
bundle exec ruby -Itest test/time_series_reconciler_test.rb
bundle exec ruby -Itest test/system/time_series_orchestration_system_test.rb
bundle exec ruby -Itest test/system/apple_health_system_test.rb
bundle exec ruby -Itest test/system/cli_system_test.rb
```

Expected: FAIL because unchanged results are currently treated as cached/imported incorrectly and projection counts are not carried into terminal status.

- [ ] **Step 5: Implement main-only unchanged persistence**

Validate `result.is_a?(TimeSeriesFetchResult) && result.unchanged?`. In one main transaction, clamp `finished_at` against exactly one `@clock.call`, update only `last_successful_fetch`/`updated_at` for the registered instance, preserve `sync_state_json`, and insert one successful fetch row with item count zero:

```ruby
metadata = result.metadata.merge(
  "result_kind" => "time_series", "outcome" => "unchanged"
)
```

Do not insert `time_series_acknowledgements`, accept a synchronization state, or open the time-series database.

- [ ] **Step 6: Route the four result variants and projection explicitly**

In `persist_time_series_result`:

```ruby
return record_time_series_failure(instance, result, result.error) if result.failure?
return time_series_status(instance, result, status: :cached) if result.cached?
if result.unchanged?
  @persistence.record_time_series_unchanged(result)
  return time_series_status(instance, result, status: :success)
end
command_id = writer.submit_import(result.artifact)
```

On successful import event, validate the immutable projection and Apple invariants before calling main acknowledgement. Save `projection.to_h` in the pending acknowledgement command so the final event never needs to re-expose receipt metadata. Final status metadata merges only `result.metadata`, projection values, and bounded cleanup state. Use projection stored counts for `InstanceRunStatus`; do not use artifact/imported counts as canonical totals.

Keep recovery order unchanged: purge intents, main receipt acknowledgement, advisory marker. Ensure `Persistence#insert_time_series_fetch_run` includes explicit safe counters from receipt columns while full digests remain in private synchronization/receipt metadata and never enter the run status.

- [ ] **Step 7: Run focused and system verification**

Delegate to Luna-medium:

```bash
bundle exec ruby -Itest test/persistence_test.rb
bundle exec ruby -Itest test/orchestrator_test.rb
bundle exec ruby -Itest test/time_series_reconciler_test.rb
bundle exec ruby -Itest test/system/time_series_orchestration_system_test.rb
bundle exec ruby -Itest test/system/apple_health_system_test.rb
bundle exec ruby -Itest test/system/cli_system_test.rb
```

Expected: PASS; all crash windows are idempotent, unchanged runs avoid the time-series writer, and ordinary source commits overlap a blocked Apple import.

- [ ] **Step 8: Commit the orchestration checkpoint**

```bash
git add lib/cybort/persistence.rb lib/cybort/orchestrator.rb \
  test/persistence_test.rb test/orchestrator_test.rb test/time_series_reconciler_test.rb \
  test/system/time_series_orchestration_system_test.rb \
  test/system/apple_health_system_test.rb test/system/cli_system_test.rb
git commit -m "Publish Apple Health import outcomes safely"
```

---

### Task 9: Benchmark Apple-scale imports and execute the offline release gates

**Files:**
- Create: `script/benchmark_apple_health.rb`
- Modify: `script/benchmark_time_series.rb`
- Modify: `Rakefile`
- Modify: `docs/LEARNINGS.md`

**Interfaces:**
- Produces: `script/benchmark_apple_health.rb --records COUNT --overlap-percent PERCENT --output DIRECTORY` with defaults `1_500_000`, `99`, and no default output directory.
- Produces: one newline-terminated JSON summary with dependency/runtime versions, bytes, durations, RSS measurement kind/value, series cardinality, copy/spool/database/WAL sizes, count projections, ingestion-time stability, query latency, and `EXPLAIN QUERY PLAN` rows.
- Preserves: generic `script/benchmark_time_series.rb` as an independent substrate benchmark.

- [ ] **Step 1: Write a failing quick benchmark contract test**

Add a small subprocess test to `test/system/apple_health_system_test.rb` using 1,000 generated records and 99% overlap. Parse the one JSON line and assert exact keys/types, both append runs, zero deletion, stable ingestion timestamps for overlap, and query plans naming `idx_observations_series_time`. Assert the generated XML is written directly into a ZIP stream and the generator has no record array.

```ruby
command = [RbConfig.ruby, "script/benchmark_apple_health.rb",
           "--records", "1000", "--overlap-percent", "99",
           "--output", output_directory]
stdout, stderr, status = Open3.capture3(*command)
assert status.success?, stderr
summary = JSON.parse(stdout)
assert_equal 0, summary.dig("second_import", "deleted")
assert_equal true, summary.dig("second_import", "overlap_ingested_at_stable")
```

- [ ] **Step 2: Run the quick contract and verify the script is missing**

Delegate to Luna-medium:

```bash
bundle exec ruby -Itest test/system/apple_health_system_test.rb --name /benchmark/
```

Expected: FAIL because `script/benchmark_apple_health.rb` does not exist.

- [ ] **Step 3: Implement the streaming synthetic benchmark**

Generate deterministic XML records one at a time into Rubyzip output, alternating a bounded set of quantity/category types and units. Generate the second archive with at least 99% stable record identities plus deterministic inserted/corrected/omitted/duplicate cases; do not retain records, XML, keys, or a DOM in an array.

Use monotonic duration measurement:

```ruby
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
value = operation.call
duration_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
```

Capture high-water RSS from `Process.getrusage` when available; otherwise record `current_rss_bytes` with measurement kind `ps_rss_current` or `null` with `unavailable`. Never label a point measurement as peak. Measure archive-copy/hash, ZIP stream, SAX/spool, canonical import, second 99%-overlap append, private-copy/spool/database/WAL sizes, distinct series, stable overlap ingestion times, bounded early/late range queries, and query plans. Add no duration or RSS pass threshold; a few temporary GiB is acceptable on the target 64-GB laptop.

- [ ] **Step 4: Run 100,000- and 1,500,000-record generated scale gates**

Delegate both commands and output analysis to Luna-medium:

```bash
bundle exec ruby script/benchmark_apple_health.rb \
  --records 100000 --overlap-percent 99 \
  --output /tmp/cybort-apple-health-benchmark-100k
bundle exec ruby script/benchmark_apple_health.rb \
  --records 1500000 --overlap-percent 99 \
  --output /tmp/cybort-apple-health-benchmark-1500k
```

Expected: exit 0; both summaries report a valid selected-entry checksum, `deleted = 0`, `changed = 0` for content-derived Apple keys, stable ingestion times for conflicts, delta-scale inserted/WAL growth on the second import, indexed bounded queries, and distinct series no greater than 100,000. The 1.5-million run must show no retained record list/DOM signature; record measured RSS even if it is several GiB, and record measurement unavailability honestly.

- [ ] **Step 5: Run dependency, malformed-input, offline contract, and generic-substrate gates**

Add Apple Health production files to `QUALITY_FILES`, then delegate all execution/output review to Luna-medium:

```bash
bundle-audit check --update
bundle exec ruby -Itest test/apple_health_zip_test.rb
bundle exec ruby -Itest test/apple_health_export_parser_test.rb
bundle exec ruby -Itest test/system/apple_health_system_test.rb
bundle exec ruby script/benchmark_time_series.rb \
  --observations 1500000 --output /tmp/cybort-time-series-benchmark-apple-gate
bundle exec rake test
bundle exec rake quality
```

Expected: advisory scan, malformed/encrypted/strict parser fixtures, Apple system path, independent generic scale benchmark, complete offline suite, and quality gate all pass without network/personal data.

- [ ] **Step 6: Record measured facts, not projected performance**

Append one dated `docs/LEARNINGS.md` entry with status `Implemented and offline-verified; live export gates open`. Include exact commands, Ruby/SQLite/Rubyzip/Nokogiri versions, record counts, measured bytes/durations/RSS-kind/sizes/counts/query plans, impact, and the remaining live-gate actions. Do not call timings guarantees or infer a peak from current RSS.

- [ ] **Step 7: Commit the benchmark/offline-gate checkpoint**

```bash
git add script/benchmark_apple_health.rb script/benchmark_time_series.rb \
  test/system/apple_health_system_test.rb Rakefile docs/LEARNINGS.md
git commit -m "Benchmark Apple Health import scale"
```

---

### Task 10: Publish configuration/privacy documentation and preserve explicit live gates

**Files:**
- Modify: `.cybort.example.toml`
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `docs/LEARNINGS.md`
- Modify: `lib/cybort/adapter_registry.rb`
- Modify: `test/adapter_registry_test.rb`
- Modify: `test/system/cli_system_test.rb`

**Interfaces:**
- Documents: the only supported configuration shape and the distinction among TTL cache hit, successful unchanged scan, and append import.
- Documents: logical purge is not forensic secure deletion and backups/source/iCloud history remain outside purge guarantees.
- Records: the connector stays experimental until real-export shape, repeat-import, and operational gates have sanitized evidence.
- Registers: adapter name `apple_health`, result kind `:time_series`, display name `Apple Health`, item noun `observations`, no executable/network dependency, and `max_instances: 1`.

- [ ] **Step 1: Write failing CLI/template contract tests**

Assert the default registry/CLI recognizes the fully commented template shape, JSON output contains safe Apple counters and `items: []`, diagnostic output distinguishes cached/unchanged/imported status without pinning whole prose, and no result includes fixture sentinels.

The canonical template block is:

```toml
# Apple Health (experimental): imports one complete archive per stale run.
# Keep this directory dedicated to one person's immediate-child ZIP exports.
# Imports append only; omitted/corrected records never delete earlier observations.
# [instances.personal_apple_health]
# name = "Personal Apple Health"
# adapter = "apple_health"
# ttl_minutes = 1440
# num_items_to_fetch = 1 # one full-history archive per run, not one record
# directory = "~/Library/Mobile Documents/com~apple~CloudDocs/Health Exports"
```

Assert the block omits both retention settings and contains the experimental/privacy pointer.

- [ ] **Step 2: Run documentation-facing tests and verify old copy fails**

Delegate to Luna-medium:

```bash
bundle exec ruby -Itest test/adapter_registry_test.rb
bundle exec ruby -Itest test/system/cli_system_test.rb
```

Expected: FAIL because template/CLI-facing Apple Health behavior is not documented or asserted.

- [ ] **Step 3: Update the configuration template and README**

Add `Adapters::AppleHealth` to `AdapterRegistry.default` with `display_name: "Apple Health"`, `item_noun: "observations"`, `result_kind: :time_series`, `max_instances: 1`, and no dependencies. Add the exact commented block above to `.cybort.example.toml`. In README, replace “no connector emits time-series results” with an experimental Apple Health section that states:

- source directory is dedicated to one person and immediate-child ZIP files; only one instance is supported;
- `directory` path/ownership/mode requirements and iCloud hydration assumption;
- `num_items_to_fetch = 1` means one complete archive publication while all candidates are examined;
- cache hit opens nothing, forced/stale checks acquire/hash all candidates, and identical fingerprints return unchanged;
- append-only identity retains omissions and corrections, repackaged ZIPs deduplicate normalized records, and only explicit purge deletes canonical rows;
- supported quantity/category records and every unsupported artifact family;
- source/device/free metadata may affect one-way identity but are not readable provenance;
- compressed copies, entry streaming, and spools remain under installation `tmp/`, with the 600-second acquisition timeout and published ZIP/parser ceilings;
- health data is sensitive, mode `0600` is not encryption, purge is logical rather than forensic, and source/iCloud/backups/snapshots may retain data;
- the connector makes no network request and remains experimental while real-export/repeat/operational gates remain open.

Link to the approved design, ADRs 0009/0010, this plan, and the canonical template instead of duplicating a second live TOML block.

- [ ] **Step 4: Update durable agent memory**

Add an `AGENTS.md` invariant that `apple_health` is append-only, uses archive plus content identities, never snapshot/deletes on absence, and remains experimental pending the named real gates. State that acquisition/decompression/spools stay under local installation temp and device/source values are identity-only, unreadable provenance.

Keep the benchmark learning from Task 9 factual. If no real export has been exercised, its next action explicitly lists all open shape/repeat/operational checks; do not imply production readiness.

- [ ] **Step 5: Execute and record the manual live-export gates when a legitimate export is available**

Use a disposable installation and the intended dedicated source directory:

```bash
bundle exec bin/cybort init /tmp/cybort-apple-health-live-gate
chmod 700 /tmp/cybort-apple-health-live-gate
bundle exec bin/cybort --root /tmp/cybort-apple-health-live-gate --json --force-fetch
bundle exec bin/cybort --root /tmp/cybort-apple-health-live-gate --json --force-fetch
bundle exec bin/cybort purge personal_apple_health \
  --root /tmp/cybort-apple-health-live-gate --yes \
  --backup /tmp/cybort-apple-health-live-gate-backup
```

Before the first run, edit only `/tmp/cybort-apple-health-live-gate/cybort.toml` to use the exact template block and the actual dedicated directory. Run the first command with the first legitimate export, add the second legitimate export before the second command, then run a third forced collection without changing either ZIP to prove the fingerprint-unchanged path. In the disposable installation, repeat once while replacing the source file during acquisition, once after making the source temporarily unavailable, and once with the temp directory on a deliberately space-limited disposable volume; restore the source/temp setup before backup and purge. Record only wrapper/DTD/entity shape, `ExportDate`/offset shapes, type set, stable-ID presence/absence, duplicate counts, artifact-family counts/sizes, library/runtime versions, checksum result, timings, import projections, omitted-record retention, series churn, interruption/replacement/disk-space/source-disappearance outcomes, and backup/purge/reset/reconciliation results. Never record profile fields, values, paths, filenames, source/device strings, raw metadata, XML excerpts, or raw parser/library messages.

Expected: two legitimate exports prove stable keys, sensible insert/duplicate/correction counts, fingerprint unchanged behavior, retention of omissions, zero deletion, no unexpected series churn, and successful lifecycle recovery. If no legitimate current export is available, leave this step unchecked and keep the connector explicitly experimental; never substitute HTML, HealthKit, CDA, CSV, GPX, or command-line fallbacks.

- [ ] **Step 6: Run final verification**

Delegate tests, quality, syntax, and output analysis to Luna-medium:

```bash
bundle exec rake test
bundle exec rake quality
ruby -c lib/cybort/apple_health_error.rb
ruby -c lib/cybort/apple_health_archive_acquirer.rb
ruby -c lib/cybort/apple_health_zip.rb
ruby -c lib/cybort/apple_health_canonical.rb
ruby -c lib/cybort/apple_health_export_parser.rb
ruby -c lib/cybort/adapters/apple_health.rb
ruby -c script/apple_health_archive_copy_helper.rb
ruby -c script/benchmark_apple_health.rb
git diff --check
```

Expected: all tests, staged correctness/security/performance cops, syntax checks, and whitespace checks pass. Run the repository's local Markdown-link check and confirm every new relative link resolves.

- [ ] **Step 7: Perform the final implementation review**

Inspect code/diffs and require affirmative evidence for every point:

- no parser DOM, record array, identity set, extracted XML file, canonical SQL in adapter/helper, or write under the source directory;
- exact dependency pins and strict parser/ZIP flags are active, not test-only;
- helper timeout always kills/reaps and startup cleanup removes only prefixed regular non-symlink files;
- all candidates are examined, one unseen archive is appended, no broken-candidate fallback exists, and all private copies/spools clean up;
- record/series keys exclude archive/order and retain source/device only one-way; readable rows/events/diagnostics contain none of those clear values;
- spool duplicates are disk-backed, canonical unchanged rows retain ingestion time, repackaging is observation-idempotent, and Apple deletion count is always zero;
- imported receipt commits before main state, unchanged scans touch only main freshness, and reconciliation is source-file-independent after canonical commit;
- existing item connectors, generic append/snapshot sources, backup/reset/purge, and item-only worker behavior remain intact.

Apply accepted review findings and rerun every affected focused test plus the complete suite through Luna-medium.

- [ ] **Step 8: Commit the documentation/release-boundary checkpoint**

```bash
git add .cybort.example.toml README.md AGENTS.md docs/LEARNINGS.md \
  lib/cybort/adapter_registry.rb test/adapter_registry_test.rb \
  test/system/cli_system_test.rb
git commit -m "Document experimental Apple Health imports"
```

---

## Completion criteria

- One configured `apple_health` source imports only ordinary quantity/category records from stable private copies of immediate-child ZIPs and remains bounded by the declared archive/parser/series ceilings.
- Archive acquisition has a tested 600-second monotonic kill/reap boundary; no source mutation, source-directory extraction, leaked private copy, or leaked spool occurs.
- Exact fingerprints skip full XML/spool/time-series work; repackaged archives parse but deduplicate through stable normalized record keys.
- Every Apple import is append mode, corrections remain additional identities, omissions remain stored, and writer/canonical deletion counts are zero.
- Exact in-archive duplicates collapse through SQLite; canonical identical conflicts do not rewrite rows or `ingested_at_us`; the 99%-overlap benchmark shows delta-scale writes/WAL behavior.
- The writer event exposes only the sanitized immutable projection, while full archive/XML digests remain private receipt/state metadata and paths/filenames/source/device/profile/free metadata never reach diagnostics.
- Imported receipts commit before main acknowledgement; unchanged checks advance only main freshness; every crash window reconciles without source presence, premature state, duplicate fetch history, or partial append.
- Existing item connectors and generic time-series append/snapshot behavior remain passing, including concurrent ordinary main commits while Apple parsing/import is blocked.
- Rubyzip 3.6.0 and Nokogiri 1.19.4 are locked, license/advisory/strictness gates pass, and generated 100,000/1,500,000 plus 99%-overlap results are recorded as machine-specific evidence.
- Template, README, AGENTS, ADR index/amendment, and learnings reflect implemented behavior; the approved design and historical sketch remain untouched.
- The connector stays labeled experimental until sanitized evidence closes the real-export shape, repeat-import, and operational gates.
