# ADR 0010: Append-Only Time-Series Import Results

- Status: Accepted
- Date: 2026-09-13
- Amends: [ADR 0009](0009-isolate-time-series-storage.md)

## Context

ADR 0009 established a dedicated SQLite database and writer for large
time-series imports. The first local importer needs two additional contracts:
it must distinguish a successful source check that found no new archive from a
TTL cache hit, and it must report append results without exposing sensitive
archive provenance. Canonical conflict handling also needs to avoid rewriting
rows whose normalized payload is already identical.

## Decision

Append-only local imports may return an explicit successful-unchanged result
that advances only main-database freshness. Spool insertion collapses exact
duplicate key/payload pairs on disk, canonical observation conflicts skip
materially identical updates, and writer import events carry a sanitized count
projection separate from the durable receipt. Apple Health never invokes
snapshot replacement; source omissions and corrected payloads do not delete or
overwrite older content-derived identities.

The projection reports only bounded nonnegative counts: imported, inserted,
duplicate, unchanged, changed, deleted, stored series, and stored observations.
Archive/XML digests, paths, filenames, source/device values, and raw parser
messages remain private receipt or synchronization metadata and are not
available through writer events or run status.

## Consequences

An unchanged source check can update the main database's freshness and fetch
history without opening the time-series writer or database. A new append still
commits its observations and pending receipt before main-database
acknowledgement, preserving ADR 0009's recovery ordering. Exact duplicate
records no longer require an in-memory identity set, and unchanged canonical
rows retain their ingestion timestamp.

Snapshot imports remain available for existing generic time-series adapters.
Apple Health is explicitly append-only, so its deletion count is always zero;
an explicit instance purge remains the only supported deletion workflow.

## Alternatives considered

- **Use snapshot replacement for every local export:** rejected because a
  later export can omit historical records and this importer is not a source
  synchronization operation.
- **Include archive bytes in observation keys:** rejected because repackaged
  exports would duplicate observations instead of deduplicating by normalized
  record content.
- **Unconditionally update every canonical conflict:** rejected because a
  mostly overlapping full export would rewrite unchanged rows and their
  ingestion timestamps.
- **Expose the full receipt through writer events:** rejected because receipt
  metadata includes archive/XML digests and other private provenance.

## References

- [Apple Health import design](../superpowers/specs/2026-09-11-apple-health-import-design.md)
- [Apple Health import implementation plan](../superpowers/plans/2026-09-13-apple-health-import.md)
- [ADR 0009: Isolate Time-Series Storage](0009-isolate-time-series-storage.md)
