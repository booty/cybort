# Cybort Core Design

**Status:** Approved for implementation planning  
**Date:** 2026-08-16

## Summary

Cybort is a local, single-user personal information collector. It retrieves
information from configured source instances, normalizes that information into
common items, stores it in one SQLite database, and presents cached or freshly
retrieved information through a command-line interface.

Each configured adapter instance is fetched concurrently. Adapter threads return
structured results; they do not write to SQLite. After all adapter threads have
finished, the orchestrator persists results sequentially through a shared
`Persistence` service. Each successful adapter result is committed in its own
transaction, so a failure in one source does not discard successful results from
other sources.

The design intentionally focuses on collection, caching, persistence, and
presentation. It does not design future scheduling, retention, dashboards, or
analysis workflows.

## Scope and non-goals

### Goals

- Keep the application simple, lean, and idiomatic Ruby.
- Fetch multiple configured source instances concurrently.
- Preserve correct, durable, deduplicated local data.
- Support fresh-data checks and explicit forced fetches.
- Make partial source failures visible without losing successful results.
- Provide one queryable local datastore for all source instances.
- Prefer existing libraries and command-line utilities over custom replacements.

### Non-goals

The initial architecture does not include:

- scheduled or background fetching;
- multi-user support;
- distributed deployment or remote shared storage;
- a transaction spanning every adapter instance in a run;
- a dashboard or web UI;
- advanced analysis and external-access integration;
- a retention-policy implementation; or
- a full workflow for classification, summarization, or generated insights.

The design may leave extension points for these capabilities, but does not
define their behavior.

## Architecture

Cybort is divided into four primary responsibilities.

### Adapter

An adapter knows how to communicate with one source type, such as Gmail, Slack,
RSS, or GitHub.

An adapter is responsible for:

- validating source-specific configuration;
- communicating with the external or local source;
- determining whether the available cached data is fresh enough;
- applying `num_items_to_fetch` when requesting source data;
- normalizing source records into Cybort items; and
- producing a stable canonical ID for each source item.

An adapter does not own SQLite schema details, SQL, or transaction management.
It returns a structured success result or an error to the orchestrator.

### Orchestrator

The orchestrator coordinates one adapter instance per configured source
instance.

It is responsible for:

- loading and validating configuration;
- creating adapter instances;
- loading the cached context needed by each adapter;
- starting adapter threads concurrently;
- waiting for every adapter thread to finish;
- collecting success and failure results;
- passing results to `Persistence` sequentially; and
- reporting overall success, partial success, or failure.

The orchestrator owns run coordination but does not construct SQL directly.

### Persistence

`Persistence` is the shared SQLite boundary and the canonical owner of durable
storage behavior.

It is responsible for:

- initializing and accessing the SQLite database;
- reading cached adapter context;
- upserting normalized items;
- recording adapter-instance state;
- recording remote fetch history;
- updating synchronization state; and
- managing per-adapter-result transactions.

The initial implementation will use persistence from the orchestrator after the
fetch phase. Adapter threads will not perform SQLite writes.

### Presentation

The presentation layer reads from `Persistence` and formats results for the
command line or another consumer. JSON and human-readable text are output
formats, not canonical storage formats.

## Runtime data flow

The normal execution flow is:

```text
configuration
      │
      ▼
orchestrator reads adapter context
      │
      ├── adapter instance thread 1 ──┐
      ├── adapter instance thread 2 ──┤
      ├── adapter instance thread 3 ──┤
      └── adapter instance thread N ──┘
                                      │
                              fetch results
                                      │
                                      ▼
                         orchestrator waits for all
                                      │
                                      ▼
                         sequential persistence calls
                                      │
                                      ▼
                              SQLite database
                                      │
                                      ▼
                              CLI presentation
```

Before starting the adapter threads, the orchestrator obtains the cached
context for each instance. That context may include cached items, the last
successful fetch time, and adapter-specific synchronization state.

Each adapter then either:

1. returns the cached result when it is fresh and a forced fetch was not
   requested; or
2. fetches from the source, normalizes the result, and returns the new items
   plus updated synchronization state.

The orchestrator waits for all adapter threads. It then writes successful
remote-fetch results sequentially. A cache hit does not need to rewrite items.

## Adapter instances and configuration

Configuration is stored in `~/.cybort/cybort.toml` by default. A configured
source instance has a stable machine-readable ID and a human-readable display
name.

Example:

```toml
schema_version = 1

[instances.personal_gmail]
name = "John's Personal Gmail"
adapter = "gmail"
ttl_minutes = 60
num_items_to_fetch = 25
api_login = "..."
api_key = "..."

[instances.hacker_news]
name = "Hacker News"
adapter = "rss"
ttl_minutes = 30
num_items_to_fetch = 25
url = "https://example.com/feed.rss"
```

The stable instance ID is used for persistence and relationships. Changing the
display name does not create a new source instance.

`num_items_to_fetch` is a source-fetch/request limit. It is not a retention
policy and does not determine how long data remains in SQLite.

Adapter-specific credentials and options remain in the instance configuration.
The adapter validates the keys it requires.

## Adapter result contract

The exact Ruby class or value object is an implementation detail, but each
adapter result has these conceptual components:

- adapter-instance ID;
- normalized items;
- updated synchronization state, if the source uses one;
- source-fetch metadata; and
- warnings or errors associated with the attempt.

A successful result may contain zero items. An empty successful result still
updates synchronization state and fetch history when appropriate.

An adapter failure is returned as a failure result or exception captured by the
orchestrator. Adapter threads must not terminate the overall run merely because
one source is unavailable.

## Item model

An item is one unit of information returned by an adapter, such as an email,
article, notification, or other source record.

The initial normalized item model includes:

- adapter-instance identity;
- canonical ID;
- zero or more URLs;
- local `fetched_at` timestamp in UTC;
- optional remote creation timestamp;
- required title;
- optional body;
- optional priority;
- optional action-item flag; and
- optional source-specific metadata.

Each adapter supplies the canonical ID. It should use the source-provided ID
when available and a stable adapter-specific fallback otherwise.

Canonical IDs are unique within an adapter-instance scope, not necessarily
globally. The conceptual database uniqueness rule is:

```text
UNIQUE(adapter_instance_id, canonical_id)
```

The canonical ID does not need to be filesystem-safe because SQLite is the
primary datastore.

## Persistence model

Cybort uses one SQLite database as its primary persistence store. The conceptual
entities are:

- **adapter instances:** configured source identity and current synchronization
  state;
- **items:** normalized source records keyed by adapter instance and canonical
  ID; and
- **fetch runs:** successful and unsuccessful remote-fetch attempts, timestamps,
  item counts, and optional debugging metadata.

The exact schema and migration mechanism belong in the implementation plan.

The database is the canonical mutable store. JSON or JSONL may be added later as
an export or inspection format.

### Per-result transactions

Each successful adapter result is persisted in one transaction containing:

```text
BEGIN
  upsert returned items
  update synchronization state
  record successful fetch history
COMMIT
```

There is no global transaction for the entire fetch run. If one adapter fails,
successful results from other adapters remain committed. A failed fetch retains
the adapter’s previous successful items and synchronization state.

## Concurrency model

The initial implementation uses Ruby threads because adapter work is primarily
remote or local I/O. One thread is started for each configured adapter instance.

The adapter threads fetch and normalize only. After all threads return, the
orchestrator persists results sequentially through `Persistence`.

This avoids an additional queue, dedicated writer thread, or application-level
write mutex. It also avoids concurrent application-level SQLite writes without
requiring a transaction that spans all sources.

The persistence API should be batch-oriented, conceptually similar to:

```ruby
write_fetch_result(
  instance_id:,
  items:,
  sync_state:,
  metadata:
)
```

The operation should persist one adapter result in one transaction rather than
opening a transaction for every item.

If future workload characteristics make waiting for all fetches undesirable, a
queue or streaming writer can be introduced without changing the adapter result
contract or the database model.

## Commands and user-visible behavior

### `cybort init [location]`

`init` creates or initializes a Cybort installation. The default location is
`~/.cybort`.

Existing installations must not be overwritten silently. If initialization is
requested for an existing location, the command requires an explicit choice
before backing up, retaining, resetting, or replacing existing data. The exact
interactive backup/reset flow is an operational detail for implementation.

### `cybort [--force-fetch]`

Without `--force-fetch`, each adapter uses its configured TTL to decide whether
cached data is fresh enough or a remote fetch is needed.

With `--force-fetch`, adapters may bypass their normal TTL checks and fetch from
their sources.

The command presents current items and source statuses after the persistence
phase. It reports partial failure when one or more adapter instances fail, even
when other instances succeed.

### Completion semantics

A run is complete when every adapter thread has returned and every result has
been either:

- successfully persisted; or
- recorded as a failure.

The run does not require every adapter instance to succeed.

## Error handling

Errors are isolated at the adapter-instance level.

- A remote fetch error records a failed fetch attempt.
- The previous successful item data remains available.
- A successful result from another adapter is still persisted.
- A persistence transaction that fails must roll back that adapter result rather
  than leaving a partial item update.
- The orchestrator reports whether the run fully succeeded or completed with
  partial failures.

Remote-fetch history should retain enough information for debugging, freshness
reporting, and future retry/backoff behavior, without making retry policy part
of this design.

## Testing strategy

The implementation should test the design at three levels.

### Adapter tests

- source-specific configuration validation;
- canonical ID generation;
- normalization into the common item shape;
- fresh-cache versus stale-cache behavior;
- `--force-fetch` behavior; and
- conversion of source failures into adapter failure results.

### Persistence tests

- database initialization;
- item upsert and deduplication by adapter-instance/canonical-ID pair;
- independent adapter-instance data in one database;
- fetch-history success and failure records;
- synchronization-state updates; and
- transaction rollback when a result cannot be persisted completely.

### Orchestration tests

- all configured adapter instances are started concurrently;
- the orchestrator waits for every adapter result;
- successful and failed adapter results are handled independently;
- persistence calls occur after the fetch phase and sequentially; and
- overall success, partial success, and failure statuses are reported
  correctly.

At least one end-to-end test should exercise a small configuration against a
temporary SQLite database and fake adapters.

## Deferred decisions

The following are intentionally outside this design:

- scheduled fetches;
- retention and cleanup policy;
- detailed retry and exponential-backoff policy;
- attachment or large-payload storage;
- dashboard or web presentation;
- external analysis or classification workflows; and
- external access protocols.

Those decisions should be made when the relevant feature is planned, using this
document’s adapter, orchestrator, persistence, and presentation boundaries as
constraints.

## Related decision record

The storage and write-ownership decision is summarized in
[ADR 0001](../../adr/0001-persistence-storage-and-write-ownership.md).
