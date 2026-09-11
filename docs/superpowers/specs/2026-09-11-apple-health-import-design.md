# Apple Health Import Design

**Status:** Proposed for review  
**Date:** 2026-09-11

## Summary

Cybort will add one experimental `apple_health` time-series adapter for
manually exported Apple Health archives in a configured local directory. Apple
describes the Health export as all health and fitness data in XML; it does not
promise Cybort a stable archive schema. The adapter therefore treats every
immediate-child `.zip` file as an import candidate, validates the complete
candidate set, and publishes at most one non-regressive full snapshot per run.

Version one imports ordinary top-level `Record` elements from the selected
archive's `export.xml`. It handles `HKQuantityTypeIdentifier...` records as
numeric observations and `HKCategoryTypeIdentifier...` records as categorical
observations. Workouts, activity summaries, correlations, nested beat series,
ECGs, routes, clinical documents, audiograms, and user-profile data are
inventoried but not imported. This narrow scope captures the high-volume,
regular time-series data without assigning incorrect semantics to structurally
different health artifacts.

The adapter extends the storage architecture selected by
[ADR 0009](../../adr/0009-isolate-time-series-storage.md). It streams ZIP entry
data through a SAX XML parser into the existing disposable time-series spool;
it never extracts the archive, builds an XML tree, retains all observations in
Ruby, issues canonical SQL, or writes either canonical database. The existing
dedicated time-series writer imports the finalized spool as a snapshot into
`cybort-timeseries.sqlite3`. The orchestrator caller continues to own
`cybort.sqlite3` writes and acknowledges the durable import receipt afterward.

Repeated exports are expected to overlap almost completely. A source archive
SHA-256 fingerprint prevents byte-identical archives from being parsed again,
while content-derived record identities deduplicate observations across
different full-history exports. Canonical persistence must also avoid rewriting
an existing observation when its normalized fields are unchanged. A later
complete export can insert new records, replace corrected records, and delete
records no longer present without making archive-specific identity part of an
observation key.

This document specifies the connector only. It does not authorize an
implementation, add a configuration template, or change the time-series
storage substrate.

## Context and evidence

The source sketch proposes a directory such as an iCloud Drive Health folder,
notes that archive names vary, and requires every `.zip` file in that directory
to be examined. It reports a representative full-history export of about 35 MB
compressed and 850 MB uncompressed, with approximately 99% overlap on a later
import.

The implemented time-series design records a separately inspected export of
about 812 MB, including a roughly 590 MB `export.xml`, a roughly 204 MB
`export_cda.xml`, approximately 1.34 million top-level records, substantial
metadata, nested beat data, workouts, and route files. These are observations
from specific exports, not a stable Apple format guarantee.

The existing substrate has already been benchmarked at 1.5 million synthetic
observations. It provides bounded-memory spooling, indexed canonical storage,
snapshot replacement, import receipts, a dedicated writer, and cross-database
reconciliation. The Apple adapter must use those contracts rather than add a
third canonical store or a connector-owned database.

## Goals

- Import the ordinary numeric and categorical records in a complete Apple
  Health export without memory use growing with record count.
- Make an unchanged archive cheap to recheck and make a new, mostly overlapping
  archive cheap to merge after it has necessarily been parsed.
- Provide stable series and observation identities across renamed, repackaged,
  and overlapping exports.
- Apply a complete newer export atomically as one instance-scoped snapshot so
  source deletions and corrections are reflected.
- Preserve the existing adapter, spool, writer, receipt, lifecycle-lock,
  backup, purge, and recovery ownership boundaries.
- Treat a changing iCloud-synchronized file as an unstable source, never as a
  valid partial snapshot.
- Retain only analytically necessary health data and keep values, profile data,
  paths, filenames, and raw source fragments out of diagnostics.
- Fail safely on malformed, partial, ambiguous, encrypted, or resource-hostile
  archives while preserving the last committed snapshot.
- Define fixture, performance, and real-export gates before the connector is
  described as production-ready.

## Non-goals

- Reading HealthKit directly from an iPhone, Apple Watch, iCloud API, backup,
  or third-party relay.
- Watching the directory continuously or scheduling exports.
- Importing any file outside the configured directory or recursing into child
  directories for more archives.
- Importing `export_cda.xml`, clinical records, ECG waveforms, workout routes,
  location data, workouts, activity summaries, correlations, audiograms, or
  nested instantaneous-beat series in version one.
- Storing the `<Me>` profile, free-form metadata, raw XML, raw CSV/GPX/CDA,
  device descriptions, archive bytes, or archive filenames.
- Resolving HealthKit categorical codes to human labels. Version one preserves
  the source category value as a category, not an interpretation.
- Cross-unit conversion, aggregate derivation, anomaly detection, dashboards,
  or ordinary Cybort items derived from health observations.
- Incremental XML cursors or resuming halfway through an archive. Apple exports
  are treated as complete snapshots.
- Time-series retention, rollup, downsampling, compaction, Parquet, DuckDB, or
  a change to the two-database topology.
- Password support for encrypted archives.
- Database encryption, forensic secure deletion, or retroactive deletion from
  installation backups. The canonical database remains a private mode-`0600`
  SQLite file protected by the host and its full-disk security.

## Assumptions

The following assumptions guide version one and must be checked at the real
export release gate:

- One configured directory contains exports for one person and is dedicated
  to Apple Health ZIP files. A different person requires a different configured
  instance ID and directory.
- Each valid archive contains exactly one `export.xml` entry beneath zero or
  one wrapper directory, and that XML has one `HealthData` root and one early
  `ExportDate` value with an explicit UTC offset.
- `ExportDate` is a usable monotonically increasing snapshot timestamp for
  exports from one person. Filename and filesystem modification time are not.
- The ordinary top-level `Record` entries do not expose a stable HealthKit UUID
  in the export shape under test. This matches the prior inspected export.
- Quantity and category identifier prefixes are sufficient to distinguish the
  two version-one value families. Other record families need a new design
  decision rather than best-effort coercion.
- The archive can be read as a normal local file once iCloud has hydrated it.
  Cybort does not control or poll iCloud download state through a private API.
- The initial resource ceilings in this design comfortably exceed the intended
  user's exports. They are safety boundaries, not Apple format constraints.

If a release-gate export disproves an assumption that affects identity,
snapshot authority, or completeness, the implementation must stop and this
design must be revised before importing personal data.

## Configuration contract

The eventual adapter-specific configuration adds one option,
`directory`. It must be a nonblank absolute path or a path beginning with
`~/`; environment variables, shell expansion, glob patterns, and relative paths
are rejected. `~` means the current user's home directory and is expanded once
at the configuration boundary. The normalized path is never written to a
receipt or diagnostic.

The existing common fields retain these meanings:

- the stable instance ID scopes all Apple Health series, observations, state,
  receipts, and purge behavior;
- `ttl_minutes` controls how long a successful import or successful unchanged
  directory check suppresses another directory scan;
- `num_items_to_fetch` must equal `1` for this adapter, meaning one
  authoritative full-history snapshot may be published per run; it does not
  limit records or the number of ZIP candidates examined; and
- `retention_ttl_minutes` and `hard_expiry_ttl_minutes` must be omitted because
  those options govern ordinary items, while version-one time-series data is
  retained until a later snapshot removes it or the instance is explicitly
  purged.

Only one `apple_health` instance is supported in one version-one configuration.
Cybort is a single-user collector, and this prevents several very large XML
parsers and spools from competing in the same process. Supporting multiple
people or concurrent Health imports requires a later resource-scheduling
decision.

Static validation checks option shapes without opening the directory. A fresh
cache therefore remains usable if an external drive or iCloud folder is
temporarily unavailable. A stale or forced run validates that the expanded
path is a user-owned directory, is not a symlink, and is not group/other
writable. Immediate-child candidate files must likewise be user-owned regular
files, not symlinks, and not group/other writable. Broader read permissions are
reported as a bounded warning rather than silently changed; Cybort never
changes source permissions.

No Apple Health block is added to `.cybort.example.toml` or the README during
design. The implementation that actually registers the connector must update
the commented template and user-facing instructions in the same change,
including the full-snapshot meaning of `num_items_to_fetch = 1`, the dedicated
directory requirement, privacy warning, and experimental release status.

## Archive discovery and acquisition

### Candidate enumeration

On a stale or forced plan, the adapter snapshots the configured directory's
immediate children. A candidate is any child whose final name has a
case-insensitive `.zip` suffix. Hidden ZIP files are candidates; subdirectories
are not traversed. A ZIP-named symlink, directory, special file, wrong-owner
file, or group/other-writable file is an error rather than something silently
ignored.

Candidates are sorted by filename bytes only to make diagnostics and
processing deterministic. Names are not an authority signal and are never
persisted. Version one accepts at most 128 ZIP candidates in one scan. An empty
candidate set is a source failure, not an empty snapshot.

Every candidate is treated as an import candidate and examined. “Examined”
means acquiring a stable private copy, hashing all compressed bytes, validating
the ZIP inventory, locating its unique `export.xml`, and reading enough of that
entry to validate the root and obtain `ExportDate`. It does not mean publishing
each older full-history archive as a separate snapshot.

### Stable private copy

The adapter never parses a live iCloud file directly. It opens a candidate
read-only without following a final symlink, captures its device, inode, size,
nanosecond modification time, and nanosecond change time, and streams it into a
mode-`0600` file under the installation's mode-`0700` temporary directory while
computing SHA-256. Copying uses a fixed-size buffer. It then compares the open
file and path identity and all captured attributes again.

If the entry was replaced, changed size or timestamps, ended before the
captured size, grew during the copy, disappeared, or cannot be read, acquisition
fails with `archive_changed_during_acquisition`. A later run may retry after
iCloud settles. The incomplete private copy is deleted. The source file is
never renamed, locked, deleted, or modified.

Candidate copies are inspected sequentially. At most the current authoritative
candidate and the candidate being copied are retained, so temporary archive
space is bounded by approximately two compressed archives. Superseded copies
are deleted immediately. The selected copy is changed to mode `0400` before
full parsing and is deleted after spool finalization or any failure. Startup
orphan cleanup uses a connector-specific reserved prefix and the same
regular-file/no-symlink rules as time-series spool cleanup.

### ZIP validation and resource ceilings

Version one uses these fixed initial ceilings:

- 4 GiB compressed bytes per archive;
- 100,000 entries per archive;
- 1,024 UTF-8 bytes per entry name;
- 16 GiB total declared and actually streamed uncompressed bytes;
- 12 GiB declared and actually streamed bytes for `export.xml`; and
- an overall 200:1 declared expansion ratio, in addition to the absolute
  limits.

The implementation enforces actual streamed bytes even when ZIP headers lie.
It rejects ZIP64 values outside the ceilings, absolute paths, NULs, `..` path
segments, invalid UTF-8 names, duplicate normalized entry names, link-like
entries, unsupported compression methods, nested archives masquerading as the
primary export, checksum failures, truncation, and encrypted entries. Nothing
is extracted to a source-derived path.

An archive must contain exactly one regular entry whose basename is
`export.xml`, at the archive root or beneath one wrapper directory. Zero or
multiple matching entries are errors. A wrapper name is not required to be
`apple_health_export`, because that observed name is not treated as a stable
contract. All other entries are safely inventoried before being classified by
the scope table below.

### Snapshot authority

The authoritative candidate is selected by parsed `ExportDate` in UTC, never by
filename, directory order, modification time, compressed size, or archive
digest. Byte-identical archives under different names collapse to one
candidate by archive SHA-256. Older distinct candidates are valid but
superseded.

Two different archive digests with the same greatest `ExportDate` are
ambiguous and fail the source. Cybort will not choose one by filename or digest
order. Any malformed, encrypted, unstable, or structurally invalid ZIP in the
dedicated directory fails the complete scan, even if another candidate is
valid; silently ignoring it would violate the promise to examine every ZIP and
could hide a newer partial export.

The adapter compares the selected pair `(exported_at,
archive_sha256)` and the current normalizer version with durable source state:

- with no prior state, it imports the selected candidate;
- a later `ExportDate` imports as a new snapshot;
- the same timestamp, same digest, and same normalizer version is a successful
  unchanged check;
- the same timestamp and same digest with a different normalizer version
  requires a new full snapshot;
- the same timestamp and different digest is an ambiguity failure; and
- an older greatest timestamp is a regression failure.

Failures preserve the previous snapshot and freshness. Cybort never falls back
from a broken newer candidate to an older candidate. Removing the last applied
archive without replacing it with a newer complete export therefore produces a
source failure after the TTL expires; it does not delete canonical data.

## Export artifact scope

The Apple public guide promises an XML export but does not specify a stable ZIP
inventory. Version one uses an explicit allowlist and inventories every other
entry without reading its content.

| Artifact or XML element | Version-one handling | Rationale |
|---|---|---|
| `export.xml` / `HealthData` | Required; stream parsed | Primary observed export and source of ordinary records. |
| `ExportDate` | Required control data; not an observation | Orders complete snapshots and becomes receipt metadata/state. |
| Top-level `Record` with `HKQuantityTypeIdentifier...` | Imported as numeric point or interval | Fits the existing numeric observation model. |
| Top-level `Record` with `HKCategoryTypeIdentifier...` | Imported as categorical point or interval | Fits the existing categorical observation model without inventing labels. |
| Direct `MetadataEntry` children of an imported `Record` | Bounded input to identity; only an explicit semantic allowlist may be stored | Prevents free-form metadata retention and identity collisions. |
| `<Me>` | Discarded; never logged or persisted | Contains direct and quasi-identifying profile data and is not a time series. |
| `Workout`, `WorkoutEvent`, and `WorkoutStatistics` | Counted as unsupported; not imported | Workout identity and aggregate semantics need a dedicated design. |
| `ActivitySummary` | Counted as unsupported; not imported | Daily aggregates should not be mixed with raw records without provenance rules. |
| `Correlation` and nested records | Counted as unsupported; not imported | Group membership is semantically meaningful and is not represented by the flat v1 model. |
| Nested instantaneous-beat or other series elements | Counted as unsupported; enclosing specialized record is not imported | High-frequency nested series need their own timestamp/identity mapping. |
| `ClinicalRecord`, `export_cda.xml`, and clinical-record directories | Size/count inventoried only; content never opened | Clinical documents contain especially sensitive structured and free text and do not fit the observation schema. |
| ECG/electrocardiogram CSV files | Size/count inventoried only; content never opened | Waveforms, lead metadata, and sampling semantics require a separate design. |
| Workout-route GPX files | Size/count inventoried only; content never opened | Location is deliberately outside v1 and outside the current time-series substrate. |
| `Audiogram` and related artifacts | Counted as unsupported; not imported | The value shape is not an ordinary scalar series. |
| Unknown entries or top-level elements | Safely inventoried and counted as unsupported | Forward-compatible visibility without guessed parsing. |

An imported top-level `Record` may contain only the explicitly supported direct
metadata children. A specialized nested child causes that entire record to be
classified as unsupported, not partially normalized. An otherwise supported
record with a missing, malformed, over-limit, or contradictory required field
fails the whole archive.

The parser records bounded aggregate counts for every supported and unsupported
family. If the archive contains top-level records but none can be imported, the
snapshot fails rather than publishing an empty replacement. A genuinely empty
`HealthData` document with zero top-level records may publish an empty snapshot.
This guard prevents an Apple schema change from erasing a previously populated
instance.

## Streaming parser architecture

### Selected approach

The implementation should use a maintained ZIP library that exposes an entry
IO stream and a strict SAX XML parser that accepts an IO. The current preferred
combination is Rubyzip for bounded central-directory validation and entry
streams, plus Nokogiri's XML SAX interface for throughput at the observed
590 MB/1.34-million-record scale. Adding and pinning these runtime dependencies
is part of the eventual connector implementation; this design is the approval
record for that scoped dependency addition, subject to dependency/security
review and the performance gates below.

The ZIP central-directory objects are bounded by the 100,000-entry ceiling.
Uncompressed entry bodies are never materialized. The selected `export.xml`
entry stream is wrapped by byte-counting and SHA-256 digesting IO and passed
directly to the SAX parser. The parser is strict: recovery mode, network
access, external resources, and entity substitution are disabled. The known
internal Apple DTD structure may be accepted only if it declares no external
identifier or entity. Any `SYSTEM`, `PUBLIC`, parameter-entity, or custom entity
declaration is an error.

The parser holds only:

- document state and aggregate counters;
- one current record's bounded attributes and direct metadata;
- one canonical identity digest input;
- prepared spool-writer state already bounded by the storage design; and
- constant-size byte/hash buffers.

A record may have at most 64 attributes, 128 direct metadata entries, 4 KiB per
attribute or metadata value, and 64 KiB of total in-flight record data. These
are parser limits in addition to the existing spool identifier and metadata
limits. They prevent a single XML element from becoming an unbounded object.
No record list, identity set, XML subtree, or archive-wide metadata map exists
in memory.

The parser requires one XML declaration compatible with UTF-8, one
`HealthData` root, exactly one `ExportDate`, well-nested elements, a closing
root, end-of-entry, a valid ZIP checksum, and no trailing second XML document.
Only after all checks and counters succeed does the adapter finalize the spool.
Any parser warning classified as structural is fatal; sanitized aggregate
warnings about intentionally unsupported artifacts remain receipt metadata.

### Why not a DOM or extracted XML file

A DOM would multiply the roughly 590 MB primary XML into a much larger Ruby or
native object graph. Extracting XML first would consume another roughly
uncompressed-export-sized private file and create additional cleanup and
permission surfaces. Streaming directly from the stable compressed copy to the
spool bounds memory and temporary storage while still allowing the source ZIP
to remain untouched.

### Parser fallback boundary

REXML offers pull/stream parsing without another native dependency and is the
fallback alternative. It is not the selected default because its throughput
at 1.34 million records has not been demonstrated. If dependency review blocks
Nokogiri, an REXML implementation must pass the same strictness, memory, and
Apple-scale duration gates before it can replace the selected parser. The
architecture depends on an IO/event interface, not Nokogiri callbacks in the
normalization domain.

## Normalization

### Series identity

Version one creates one logical series for each tuple:

```text
(record_family = "record", exact Apple type identifier, value_type,
 normalized source unit or nil)
```

`metric_key` is the exact validated Apple `type` identifier, limited by the
existing 128-byte contract. It is not translated to a friendlier name whose
mapping might change. `series_key` is
`apple-health-record-v1:` followed by the SHA-256 of a length-prefixed canonical
encoding of the tuple. It is independent of archive path, archive digest,
record order, source application, and device.

Series dimensions contain only `record_family: "record"` and the Apple type
identifier. Value type and unit already have typed columns. Source application
and device are record provenance, not dimensions; making them dimensions would
create high-cardinality series and make unit/type immutability harder to
reason about.

### Observation identity and deduplication

The inspected Apple records do not expose a stable UUID. Version one therefore
defines a canonical record identity from:

- record family and exact type identifier;
- normalized source name, source version, and device attribute when present;
- creation, start, and end timestamps normalized to UTC microseconds, plus
  their numeric source offsets;
- value type, canonical numeric or categorical value, and normalized unit; and
- all direct metadata key/value pairs, sorted after UTF-8 validation and Unicode
  NFC normalization.

Every field is encoded as a field tag plus byte length plus UTF-8 bytes, so
delimiters cannot collide. Numeric identity uses a canonical decimal rendering,
not the original lexical choice between values such as `1` and `1.0`.
`source_record_key` is `apple-health-record-v1:` plus the SHA-256 of that
canonical identity. Archive fingerprint, filename, XML attribute order,
metadata order, and document order are deliberately excluded, allowing the
same record in overlapping exports to retain identity.

Two elements with exactly the same canonical identity collapse to one logical
observation. This is an explicit version-one trade-off: without a source UUID,
an occurrence ordinal would preserve multiplicity but would make identity
depend on unstable document ordering. A cryptographic-key collision is still
checked defensively by comparing the complete normalized payload in the spool;
the same key with different content fails the archive.

Duplicate collapse must remain disk-backed. The persistence-owned spool API
therefore needs an idempotent observation-add operation: the first key/payload
pair inserts, an identical repeated pair is a counted no-op, and the same key
with different normalized content is fatal. The adapter does not retain an
archive-wide key set and does not query or write spool SQL directly.

Corrections are replacement by snapshot, not in-place identity continuity. If
any identity field changes, the newer export produces a new record key and the
old key is absent, so the snapshot transaction inserts the corrected record and
deletes the prior record. A source deletion is likewise represented by absence
from the complete newer snapshot. This is the only deletion mechanism in
version one; older or partial exports never delete data.

If a future Apple export provides a documented stable record UUID, Cybort must
verify its stability across two exports and revise the identity version before
using it. It must not silently switch key algorithms under
`apple-health-record-v1`.

### Numeric and categorical values

`HKQuantityTypeIdentifier...` requires a nonblank unit and a strictly parsed
finite decimal value. Validation uses decimal syntax before conversion to the
existing SQLite numeric representation; NaN, infinity, locale separators,
booleans, and trailing text are rejected. Version one accepts IEEE-754 storage
precision and does not claim exact clinical-decimal preservation.

No cross-unit conversion is performed. The source unit is UTF-8 normalized,
trimmed only where the format defines insignificant surrounding whitespace,
and stored as the series canonical unit. Different units for the same Apple
type produce different series. This avoids incorrect conversions and complies
with the substrate rule that a series unit is immutable.

`HKCategoryTypeIdentifier...` requires no unit and stores the validated source
`value` as `categorical_value`, even when it looks numeric. Values remain
nonblank UTF-8 strings within the existing 1,024-byte limit. Mapping codes such
as sleep states to human labels is deferred until a versioned Apple semantic
mapping is designed and tested.

An unknown type prefix is not coerced based on whether its value looks numeric.
It is counted as unsupported. A known-family record with a missing or
contradictory value/unit contract fails the archive.

### Timestamps and time zones

`startDate` is `observed_at`; `endDate` is `ended_at`. Both require an explicit
numeric UTC offset or `Z`, accept bounded fractional seconds, and are normalized
to integer UTC microseconds. End before start is fatal. Equal start/end is a
valid point-like interval. `creationDate` participates in source identity but
is not the observation time.

The source offset minutes for start, end, and creation are retained in the
observation's allowlisted metadata because local-clock context can matter for
sleep and daily behavior. An IANA timezone name is not inferred from a numeric
offset. Ambiguous offset-free dates are rejected rather than interpreted in the
process timezone. DST behavior is therefore preserved only as the offset
present on each source timestamp.

### Metadata and privacy

Identity and storage have separate metadata policies. All bounded direct
metadata participates in the one-way record digest so otherwise distinct
source records do not collide. Raw metadata is then discarded unless a key is
on a small versioned semantic allowlist. Version one stores only:

- start, end, and creation UTC offset minutes;
- a boolean user-entered indicator when represented unambiguously; and
- a bounded integer synchronization version when present.

Raw synchronization identifiers, source names, source versions, device
descriptions, free-form strings, external UUIDs, profile fields, and unknown
metadata are not stored. Their inclusion in a SHA-256 identity is not a claim
of anonymization; it only avoids retaining the clear values in ordinary query
output.

Receipt metadata contains only bounded non-sensitive facts: format and
normalizer versions, full archive SHA-256, `export.xml` SHA-256, `ExportDate`,
compressed and streamed byte counts, entry counts, supported/unsupported family
counts, total/imported/duplicate record counts, and set-wise inserted, changed,
unchanged, and deleted counts. It contains no filename, path, profile field,
record value, source application, device, XML text, or raw parser message.

## Import key, source state, and receipt

The stable import key is:

```text
apple-health-snapshot-v1:<archive-sha256>
```

It is unique within the configured instance, stays within the substrate's
256-byte limit, and identifies acquired source bytes plus the version-one
normalization contract. Repacking the same XML into different ZIP bytes creates
a new import receipt, but observation identities still deduplicate all overlap.
The receipt metadata's `export.xml` digest makes that relationship auditable
without storing the XML.

The snapshot artifact's synchronization state is a bounded object containing:

```text
state_version
normalizer_version
authoritative_exported_at
authoritative_archive_sha256
authoritative_export_xml_sha256
latest_import_key
```

There is no XML offset or per-record cursor. A failed or interrupted parse
starts from the beginning on retry. This costs source reading but avoids
publishing partial snapshots or relying on unstable compressed offsets.

Changing normalizer or identity behavior requires a new version in the import
key, series key, source-record key, and state. The first run of that version
must parse the full authoritative archive and publish a complete snapshot. A
code upgrade must never reinterpret an old receipt under a new version.

## Import mode and overlap efficiency

Every new authoritative Apple archive uses existing `snapshot` mode. The spool
contains the complete set of version-one-governed series and observations from
that archive. The dedicated writer atomically upserts the spool, deletes
governed observations and series absent from it, records the receipt, and
updates time-series instance state. Readers see either the previous complete
snapshot or the new one.

An append import is rejected for this adapter. Archive-by-archive append would
preserve deleted Health records forever, while applying every candidate as a
snapshot in filename order could let an older archive roll the instance back.
Selecting one non-regressive authoritative archive gives snapshot semantics a
clear meaning.

Parsing a new full export remains O(export size); Cybort cannot discover the
small delta without reading the source. Canonical write amplification must,
however, be proportional to the delta. The generic set-oriented observation
upsert should be narrowed so conflict rows update only when start/end, value, or
stored metadata differs. `ingested_at_us` changes only on insert or a material
update. Before mutation, set comparisons compute inserted, changed, unchanged,
and deleted counts for bounded receipt metadata and diagnostics. Existing
series already avoid no-op dimension updates.

This is an optimization within ADR 0009's canonical import transaction, not a
new storage path. Snapshot absence checks still inspect keys, but the expected
99% overlap does not rewrite 99% of observation rows or grow WAL as though they
were new.

## Successful unchanged scans

A stale scan whose authoritative `(ExportDate, archive SHA-256,
normalizer_version)` exactly matches state must not reparse the hundreds of
megabytes of XML or manufacture a new spool. It also must count as a successful
source check so `last_successful_fetch` and TTL freshness can advance.

The time-series result contract therefore needs one explicit `unchanged`
success shape:

- the source was checked successfully;
- no artifact or new synchronization state is present;
- current stored series and observation counts are carried from planning
  context;
- bounded discovery metadata reports an unchanged fingerprint; and
- the orchestrator caller records a successful zero-import fetch-history row
  and advances freshness in the main database without touching the
  time-series database.

This path is safe without a time-series receipt because no observation, cursor,
or time-series state changes. It is distinct from a TTL cache hit, which does
not open the directory, and from a new snapshot, whose time-series receipt must
commit before the main acknowledgement. The orchestrator's result-kind checks
must distinguish all three shapes. If this contract is judged to amend ADR
0009 rather than clarify the no-change case, implementation must record that
decision in a new ADR before code changes.

`--force-fetch` bypasses TTL but not idempotency: it reacquires and rehashes the
candidate archives, then returns this unchanged success if the authoritative
fingerprint is still identical.

## Data flow and concurrency

```text
adapter thread
  snapshot directory
  -> acquire/hash/inspect each ZIP candidate
  -> select newest non-regressive complete export
  -> stream export.xml -> SAX events -> normalized spool calls
  -> finalize immutable snapshot spool
                                |
                                v
dedicated time-series writer
  validate/attach spool read-only
  -> set-wise no-op-aware snapshot transaction
  -> durable pending receipt in cybort-timeseries.sqlite3
                                |
                                v
orchestrator caller
  acknowledge receipt, state, and fetch history in cybort.sqlite3
  -> request advisory receipt marker
```

The adapter runs in the ordinary source thread and receives the
persistence-owned `TimeSeriesSpoolFactory`. It never receives a canonical
connection. Full parsing can overlap ordinary adapter fetches and main-database
item commits, although it may contend for CPU and filesystem bandwidth. The
single-Apple-instance v1 rule and one parser thread bound that contention.

Only one dedicated time-series writer exists in the run. It serializes Apple
snapshot import with every other time-series import. The potentially large
transaction locks only `cybort-timeseries.sqlite3`; the orchestrator caller may
continue committing RSS, Gmail, Reddit, or GitHub results to
`cybort.sqlite3`. The final run still waits for parser and writer completion.

Normal JSON and diagnostic output includes counts and status, never raw Health
observations. A successful new archive reports imported, inserted, changed,
unchanged, deleted, and stored counts. A successful unchanged scan reports that
the source was checked and unchanged. A TTL cache hit reports stored counts
without opening the source directory.

## Crash, retry, and reconciliation

Acquisition and parsing are disposable work. A crash before spool finalization
leaves neither canonical change nor source-state advancement; startup removes
only connector-prefixed private archive copies and existing spool-prefixed
regular files. A retry reacquires and parses from the beginning.

A finalized spool follows ADR 0009 unchanged:

1. the time-series writer commits the complete snapshot and a pending receipt;
2. the orchestrator caller acknowledges the receipt and advances source state
   and fetch history in the main database; and
3. the writer marks the receipt acknowledged as advisory cleanup.

If the process fails after step 1, startup reconciliation uses the receipt's
durable state and source times to complete step 2 before planning the Apple
source. If it fails after step 2, reconciliation completes only step 3. Import
key acknowledgement remains idempotent and cannot create duplicate fetch
history. Main state never advances to a newer archive before its observations
are durable.

If the process dies after the canonical snapshot commit, the source archive no
longer needs to be present for reconciliation because the receipt contains the
governing state. If it dies before that commit, the archive must remain or be
restored for a retry. No attempt is made to recover or resume a disposable
spool after process failure.

A parse, checksum, normalization, spool, storage, or constraint failure aborts
the entire candidate. No partial result, partial cursor, fallback archive, or
empty replacement is published. Existing data and state remain last-known-good
and successful results from unrelated sources remain durable.

## Errors and diagnostics

Errors are normalized into stable categories at the responsible boundary:

- `directory_unavailable` or `directory_unsafe`;
- `too_many_archives` or `archive_size_limit`;
- `archive_changed_during_acquisition`;
- `invalid_zip`, `encrypted_zip`, `unsupported_compression`, or
  `zip_resource_limit`;
- `missing_export_xml`, `duplicate_export_xml`, or
  `ambiguous_export_snapshot`;
- `invalid_export_root`, `unsafe_xml`, `malformed_xml`, or
  `unsupported_export_schema`;
- `invalid_record`, `record_resource_limit`, or `invalid_timestamp`;
- `spool_failure`, `time_series_persistence_failure`, or
  `receipt_acknowledgement_pending`; and
- `snapshot_regression`.

Diagnostics may include the configured instance ID, phase, candidate ordinal,
category, relevant configured limit name, and bounded aggregate counts. They
must not include directory paths, filenames, archive bytes, XML excerpts,
parser-provided source lines, profile attributes, metadata keys or values,
record types paired with values, device/source strings, SQL, or raw exception
messages from ZIP/XML libraries. A digest may be included only as a short
prefix when necessary to distinguish duplicate candidates; full digests remain
in private receipt metadata.

Tests assert category, phase, durable outcome, and secret absence rather than
exact prose. A malformed archive failure does not discard the prior Apple
snapshot, and it does not convert unrelated source successes into failures.

## Security and privacy operations

- The connector performs no network requests, executes no external command,
  loads no archive-provided code, and never follows source or ZIP symlinks.
- ZIP and XML parsing use strict allowlists, absolute byte/count ceilings, no
  network access, no external entities, and no source-derived extraction path.
- Source access is read-only. Private archive copies and spools are `0600`
  while writable, `0400` after finalization, and live only beneath a `0700`
  installation temporary directory.
- Canonical health observations inherit the `0600` time-series database,
  installation lock, backup, reset, and instance purge behavior already
  selected by ADR 0009.
- The connector never prints or persists `<Me>`, archive paths/names, raw
  device descriptions, source application names, free-form metadata, clinical
  documents, ECG samples, or location routes.
- Library errors are mapped to safe categories before they reach fetch history
  or CLI output. Raw exception text is not treated as safe metadata.
- Dependencies must be locked, license-reviewed, and checked for known security
  advisories before the experimental adapter is enabled.

Mode bits are confidentiality controls, not encryption. A user must protect the
installation, source directory, temporary volume, and backups with appropriate
host access controls and disk encryption. Existing purge is logical deletion;
SQLite pages, WAL files, filesystem snapshots, iCloud history, and prior
backups are not promised to be forensically erased. User-facing documentation
must say this before the adapter leaves experimental status.

## Testing strategy

All automated tests use generated local fixtures and injected clocks/filesystem
collaborators. They do not read a personal export, contact Apple or iCloud, or
depend on a live synchronized directory.

### Parser and normalization fixtures

Small ZIP fixtures cover:

- numeric and categorical points and intervals;
- category values that look numeric;
- multiple units for one type producing separate series;
- reordered XML attributes, records, and metadata producing stable identity;
- equivalent numeric lexical forms producing stable identity;
- explicit positive, negative, and `Z` offsets plus fractional seconds;
- missing offsets, invalid dates, end-before-start, non-finite values, and
  invalid UTF-8;
- direct allowlisted metadata, discarded free-form metadata, and specialized
  nested-record exclusion;
- exact normalized duplicate collapse and same-key/different-payload defense;
- zero-record valid exports and the nonempty-but-zero-supported safety guard;
  and
- unsupported top-level artifact inventory without opening clinical, ECG, or
  route bodies.

### Archive and file-consistency fixtures

Coverage includes renamed byte-identical archives, several ordered export
dates, same-date/different-digest ambiguity, newly copied older exports,
missing/duplicate `export.xml`, alternate wrapper names, path traversal,
absolute paths, duplicate entry names, link-like entries, nested ZIPs,
encrypted entries, unsupported compression, CRC errors, truncated archives,
lying size headers, entry/count/ratio limits, source symlinks, wrong ownership
or writable permissions, and a file replaced or changed while acquisition is
blocked by test coordination queues.

Directory tests prove that every ZIP candidate is examined, no child directory
is traversed, a broken newer candidate does not fall back, at most two private
archive copies exist, and every temporary file is cleaned after success,
failure, interruption, and startup recovery.

### Idempotency, snapshot, and recovery tests

Two generated exports model heavy overlap. The second includes unchanged,
inserted, corrected, deleted, and exact-duplicate records. Tests assert stable
series/record keys, expected inserted/changed/unchanged/deleted counts, no
material update of unchanged rows or `ingested_at_us`, complete snapshot
replacement, and no cross-instance deletion.

An exact authoritative fingerprint exercises the successful unchanged result:
no XML body parse, spool, time-series writer command, receipt, or time-series
write occurs, while main freshness advances once. TTL cache hits do not open
the directory; `--force-fetch` reacquires and hashes it. Normalizer-version
changes force a new full snapshot even with the same source archive.

Existing receipt tests are extended through the real adapter for crashes before
spool finalization, after time-series commit, after main acknowledgement, and
during advisory marker cleanup. Tests prove no premature state advancement,
duplicate fetch history, partial snapshot, or leaked source/staging path. A
queue-controlled system test proves an ordinary item commit completes while an
Apple snapshot import is blocked in the dedicated writer.

### Performance benchmarks

An opt-in synthetic Apple export generator produces valid compressed XML
without retaining records. Connector benchmarks run at 100,000 and at least
1.5 million records, with an uncompressed primary XML size near the observed
range. They record:

- compressed and streamed bytes and checksum/digest time;
- SAX parse and spool construction duration;
- high-water RSS with the measurement kind, never a current RSS mislabeled as
  peak;
- private-copy, spool, canonical database, and WAL sizes;
- canonical import duration and inserted/changed/unchanged/deleted counts; and
- representative indexed range-query latency and query plans.

The 1.5-million-record run must demonstrate that high-water memory is bounded
by parser/record/spool batches rather than record count. As an initial release
review threshold, measured peak RSS should remain below 256 MiB and should not
grow by more than 64 MiB from the 100,000-record run on the same runtime and
machine. If reliable peak measurement is unavailable, the memory release gate
remains open rather than being inferred from a point measurement.

A second benchmark snapshot with at least 99% unchanged identities verifies
that unchanged canonical rows are not materially updated, their ingestion
timestamps remain stable, and WAL growth reflects the delta rather than a
full-history rewrite. Wall-clock results are recorded as machine-specific
evidence, not CI assertions or product guarantees. The existing generic
time-series benchmark continues to guard the substrate independently.

## Rollout and release gates

The connector remains experimental until every gate below is recorded with
sanitized evidence:

1. **Dependency gate:** selected ZIP/XML versions are locked, licenses are
   acceptable, no known applicable security advisory is open, strict parser
   options are verified, and malformed/encrypted fixtures fail closed.
2. **Offline contract gate:** all local parser, identity, snapshot,
   no-op-update, privacy, file-consistency, recovery, orchestration, full-suite,
   and quality tests pass.
3. **Generated scale gate:** both benchmark sizes complete, memory is measured
   and bounded, the 99%-overlap run avoids full-row rewrite, and disk/WAL growth
   is recorded.
4. **Real-export shape gate:** a disposable private copy of a current Apple
   export confirms wrapper layout, DTD/entity behavior, `ExportDate`, date
   offsets, quantity/category prefixes, absence or presence of stable record
   IDs, duplicate behavior, actual artifact families, limits, and complete
   entry/checksum handling. Record only counts, sizes, types-as-a-set, versions,
   and timings—never profile fields, values, paths, source/device strings, raw
   metadata, or document excerpts.
5. **Real repeat-import gate:** two legitimate exports from the same Health
   store demonstrate stable identities, sensible insert/correction/deletion
   counts, exact-fingerprint unchanged behavior, and no unexpected series churn.
6. **Operational gate:** interruption, iCloud replacement during acquisition,
   insufficient temporary space, source disappearance, backup, purge, reset,
   and receipt reconciliation are exercised on a disposable installation.
7. **Documentation gate:** only when the adapter is registered, update the
   canonical configuration template and README with setup, privacy, permission,
   full-snapshot, no-secure-delete, unsupported-artifact, and experimental
   caveats. Add or amend architectural records if implementation changes an
   accepted ADR contract.

A failed real gate does not justify an HTML, iCloud, HealthKit, CDA, CSV, GPX,
or command-line fallback. Stop, preserve last-known-good data, and revise the
design with evidence.

## Alternatives considered

### Import every archive in append mode

Rejected. Stable record keys would deduplicate overlap, but records deleted
from a later full export would remain forever and corrections would be harder
to distinguish from historical variants.

### Apply every archive as a snapshot

Rejected. It repeatedly parses overlapping history and makes ordering
dangerous: filename or directory order can let an older archive delete newer
data. One newest non-regressive snapshot gives absence an unambiguous meaning.

### Merge all archives into one union snapshot

Rejected. An old archive would reintroduce records deliberately removed from a
new export. It would also make the canonical result depend on which historical
files happen to remain in the directory.

### Choose the newest filename or filesystem modification time

Rejected. Archive names vary, users rename files, and iCloud or copying changes
filesystem times. The export's own timestamp is the best available authority,
subject to the real-export monotonicity gate.

### Extract the archive and parse a DOM

Rejected. This adds uncompressed temporary copies and memory proportional to
the export. Streaming ZIP entry IO into SAX events and the disk-backed spool
fits the existing ownership and scaling model.

### Use REXML by default to avoid a native dependency

Not selected initially. It preserves the desired streaming interface but has
not demonstrated adequate throughput at the observed scale. It remains a valid
fallback only after matching the same performance and strict XML security
gates.

### Use source file attributes as the durable fingerprint

Rejected. Inode, size, and timestamps are useful for detecting change during
one acquisition, but they are not source identity across iCloud replacement,
copying, or renaming. SHA-256 of the acquired archive is the durable source
fingerprint.

### Include archive fingerprint in every observation key

Rejected. It would make every full export appear entirely new and defeat
cross-export deduplication. Fingerprints belong in import keys, state, and
receipt provenance; record identity belongs in the normalized record content.

### Preserve duplicate multiplicity with document ordinals

Rejected for version one. Ordinals make identities change when Apple reorders
records. Exact canonical duplicates collapse until a stable source record ID
or evidence of meaningful duplicate multiplicity justifies another identity
version.

### Import workouts, ECGs, routes, and clinical artifacts opportunistically

Rejected. Their value shapes, relationships, privacy risks, and query needs are
different from ordinary scalar records. Partial or guessed mappings would be
harder to correct after canonical import than an explicit later design.

## Unresolved questions

These questions are explicit release blockers or future-scope decisions, not
permission to choose silently during implementation:

- Does a current export always include a unique offset-bearing `ExportDate`,
  and is it monotonic across rapid repeated exports and device clock changes?
- Does any current ordinary record include a stable UUID or synchronization ID
  that is both present across exports and safe to use without retaining it?
- Are exact canonical duplicate records source duplication to collapse, or can
  they represent distinct legitimate samples whose multiplicity matters?
- Which internal DTD constructs occur in current exports, and can the selected
  strict SAX parser accept those declarations while rejecting entities and all
  external resolution?
- Which direct metadata keys are sufficiently stable and analytically useful to
  join the version-one allowlist? Until answered, only the minimal fields named
  in this design are stored.
- Are raw category codes stable across OS/export versions? Version one stores
  them without labels; semantic mapping remains deferred.
- Do current exports contain offset-free dates, sub-microsecond timestamps,
  numeric values outside finite IEEE-754 range, or unit strings beyond the
  existing substrate limits?
- Are the 4 GiB/12 GiB/16 GiB, 100,000-entry, and 200:1 ceilings adequate for
  the intended long-lived Health store?
- Does the selected ZIP library validate CRC and data descriptors for the exact
  Apple ZIP shape while streaming, including any ZIP64 archive Apple produces?
- Is one Apple instance per installation acceptable long term, or will future
  multi-person use require an explicit parser/resource queue?
- Should a future design bind an instance to a privacy-preserving person token?
  Version one assumes directory/instance discipline and does not persist
  `<Me>` data to detect a person switch.
- Do users need explicit inclusion/exclusion filters by record type? Version one
  imports all supported ordinary records so snapshot completeness stays clear.
- What retention or secure-erasure policy, if any, should apply to health data?
  Version one inherits indefinite time-series retention and logical purge.

## Documentation and decision impact

This proposal does not supersede ADR 0009. It supplies the first connector
design that consumes the implemented spool, snapshot, receipt, writer, and
reconciliation substrate. The no-op observation update predicate and explicit
successful-unchanged result are focused extensions needed for full-snapshot
local imports. If ADR review determines either changes an accepted invariant,
record the amendment in a new ADR rather than editing historical decisions
silently.

No existing README, configuration template, ADR, learning, code, or test should
change during review of this proposal. After approval, implementation planning
must identify the exact dependency versions, source-result contract change,
adapter registration, fixtures, benchmarks, documentation updates, and any ADR
work as separate reviewable steps.

## References

- [Apple Health importer source sketch](../../spitballing/apple-health.md)
- [ADR 0009: Isolate Time-Series Storage](../../adr/0009-isolate-time-series-storage.md)
- [Time-Series Storage Design](2026-09-09-time-series-storage-design.md)
- [Time-Series Storage Implementation Plan](../plans/2026-09-09-time-series-storage.md)
- [Cybort project learnings](../../LEARNINGS.md)
- [Apple Support: Share your health and fitness data in XML format](https://support.apple.com/guide/iphone/share-your-health-data-iph5ede58c3d/ios)
- [Rubyzip README: streaming ZIP input](https://github.com/rubyzip/rubyzip/blob/main/README.md)
- [Nokogiri SAX parser documentation](https://nokogiri.org/rdoc/Nokogiri/XML/SAX/Parser.html)
- [REXML pull parser documentation](https://ruby.github.io/rexml/REXML/Parsers/PullParser.html)
