# Cybort

Cybort is a local, single-user personal information collector. It fetches
configured source instances concurrently, stores normalized items in one SQLite
database, and presents cached or freshly fetched data through the CLI.

## Requirements

- Ruby 4.0.1 (the current development runtime)
- Bundler
- macOS/POSIX for command-backed connectors in this slice

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
`num_items_to_fetch` source limit. An instance may also define optional item
retention.

```toml
schema_version = 1

[instances.personal_rss]
name = "Personal RSS"
adapter = "rss"
ttl_minutes = 30
retention_ttl_minutes = 10080
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

`ttl_minutes` controls how long cached data is considered fresh before Cybort
performs another remote fetch. `num_items_to_fetch` limits one source request.
Neither setting deletes stored items.

`retention_ttl_minutes` is optional and defaults to retaining items forever.
When configured, Cybort deletes items last seen at or before the retention
cutoff only after that instance completes a successful remote fetch. Cache hits
and failed fetches preserve the existing items, even when they are older than
the configured duration. It is valid for retention to be shorter than
`ttl_minutes`; in that case, a cache hit preserves the old items and the next
successful remote fetch may remove every item it does not return.

### Gmail connector (experimental)

Gmail uses the `gws` executable from the Google-maintained
[`googleworkspace/cli`](https://github.com/googleworkspace/cli) project. It is
in the Google Workspace GitHub organization, but its own README says it is not
an officially supported Google product and is under pre-1.0 development.

`gws` relies upon the official gcloud CLI. [Install that first](https://docs.cloud.google.com/sdk/docs/install-sdk).


```bash
curl -O https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-darwin-arm.tar.gz
tar -xf google-cloud-cli-darwin-arm.tar.gz
./google-cloud-sdk/install.sh
```

Add gcloud executables and completions to your path; you probably want to add this to ~/.zshrc or ~/.zshrc.local

```bash
source "/Users/booty/code/tmp/google-cloud-sdk/path.zsh.inc"
source "/Users/booty/code/tmp/google-cloud-sdk/completion.zsh.inc"
```

Install and authenticate it outside Cybort:

```bash
brew install googleworkspace-cli
gws auth setup
gws auth login --scopes https://www.googleapis.com/auth/gmail.readonly
gws auth status
```

`gws auth setup` can use `gcloud` to automate Google Cloud project and
credential creation. If `gcloud` is unavailable, complete the equivalent
manual Cloud Console setup described by `gws`, then run `gws auth login`.
Cybort never performs an interactive login or stores OAuth credentials.

Configure a read-only Gmail instance like this:

```toml
[instances.personal_gmail]
name = "Personal Gmail"
adapter = "gmail"
ttl_minutes = 60
num_items_to_fetch = 25
user_id = "me"
query = "in:anywhere"
```

Before a stale or forced fetch, Cybort checks the required executable and its
tested version range. Missing or unsupported dependencies fail only the
affected source and include Homebrew/authentication guidance in the JSON
result; fresh cached data remains available. The Gmail connector remains
experimental until an authenticated contract smoke test verifies the
installed `gws` version, read-only scopes, and list/detail response shapes.

## Fetch data

Use cached data when each adapter’s TTL is still fresh:

```bash
bundle exec bin/cybort
```

Ignore TTL checks and request fresh source data:

```bash
bundle exec bin/cybort --force-fetch
```

The command emits one JSON document containing overall status, grouped
unavailable-dependency guidance, per-instance status, and persisted items. A
source failure produces a partial-failure exit status while preserving
successful results and the failed source’s last-known-good data.

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

Tests use local fixtures and injected HTTP/command clients; they do not contact
external services or invoke `gws`.

## Design records

- [Core design](docs/superpowers/specs/2026-08-16-cybort-core-design.md)
- [Persistence ADR](docs/adr/0001-persistence-storage-and-write-ownership.md)
- [External command connector ADR](docs/adr/0002-external-command-dependencies-and-cli-adapters.md)
- [External command connector design](docs/superpowers/specs/2026-09-04-external-command-connectors-design.md)
- [External command connector implementation plan](docs/superpowers/plans/2026-09-04-external-command-connectors.md)
- [Implementation plan](docs/superpowers/plans/2026-08-16-cybort-core-implementation.md)
- [Configurable item retention design](docs/superpowers/specs/2026-09-05-configurable-item-retention-design.md)
- [Configurable item retention ADR](docs/adr/0003-configurable-item-retention.md)
- [Configurable item retention implementation plan](docs/superpowers/plans/2026-09-05-configurable-item-retention.md)
- [Deferred quality follow-ups](docs/quality-followups.md)
