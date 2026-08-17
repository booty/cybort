# Cybort

Cybort is a local, single-user personal information collector. It fetches
configured source instances concurrently, stores normalized items in one SQLite
database, and presents cached or freshly fetched data through the CLI.

## Requirements

- Ruby 4.0.1 (the current development runtime)
- Bundler

Install the declared dependencies:

```bash
bundle install
```

## Initialize an installation

The default installation directory is `~/.cybort`:

```bash
bundle exec bin/cybort init
```

An alternate location can be supplied:

```bash
bundle exec bin/cybort init /path/to/cybort
```

Existing installations require an explicit choice before they are reset. The
backup options create a timestamped `.tar.gz` backup first; a reset without a
backup requires a second confirmation.

## Configure adapter instances

Configuration is stored in `~/.cybort/cybort.toml`. Each instance has a stable
ID, a display name, an adapter type, a freshness TTL, and a
`num_items_to_fetch` source limit.

```toml
schema_version = 1

[instances.personal_rss]
name = "Personal RSS"
adapter = "rss"
ttl_minutes = 30
num_items_to_fetch = 25
url = "https://example.com/feed.xml"

[instances.github]
name = "GitHub Notifications"
adapter = "github"
ttl_minutes = 15
num_items_to_fetch = 25
api_url = "https://api.github.com/notifications"
token = "..."
```

`num_items_to_fetch` limits a source request. It is not a retention policy.

## Fetch data

Use cached data when each adapter’s TTL is still fresh:

```bash
bundle exec bin/cybort
```

Ignore TTL checks and request fresh source data:

```bash
bundle exec bin/cybort --force-fetch
```

The command emits one JSON document containing overall status, per-instance
status, and persisted items. A source failure produces a partial-failure exit
status while preserving successful results and the failed source’s last-known-
good data.

## Architecture

Adapter threads fetch and normalize source data but do not write to SQLite. The
orchestrator waits for every adapter thread, then persists each successful
adapter result sequentially through the shared `Persistence` service. Each
adapter result has its own transaction; there is no transaction spanning all
sources.

## Tests

Run the complete test suite:

```bash
bundle exec rake test
```

Tests use local fixtures and injected HTTP clients; they do not contact external
services.

## Design records

- [Core design](docs/superpowers/specs/2026-08-16-cybort-core-design.md)
- [Persistence ADR](docs/adr/0001-persistence-storage-and-write-ownership.md)
- [Implementation plan](docs/superpowers/plans/2026-08-16-cybort-core-implementation.md)
