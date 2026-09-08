# Cybort

Cybort is a local, single-user personal information collector. It has two
separate pillars:

- Collection fetches configured source instances, normalizes and caches their
  data in one SQLite database, and prunes it according to the configured
  retention policy.
- Dashboards will present that collected data through CLI and web views in a
  future phase; dashboard design has not started yet.

The collector CLI is diagnostic: it reports source progress and outcomes so
users can monitor collection and diagnose errors. It is not a dashboard.

## Requirements

- Ruby 4.0.1 (the current development runtime)
- Bundler
- macOS/POSIX for command-backed connectors in this slice

Install the declared dependencies:

```bash
bundle install
```

Run the staged static-quality baseline with:

```bash
bundle exec rake quality
```

The baseline currently gates correctness, security, and performance cops on
the connector/configuration files reviewed most recently. Legacy style,
layout, naming, and metrics offenses remain intentionally outside the gate
until they can be ratcheted in smaller reviewed changes.

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
retention. See [.cybort.example.toml](.cybort.example.toml) for commented
configuration templates for every registered connector. Copy the relevant
fields into `~/.cybort/cybort.toml` and replace all placeholders; never commit
credentials.

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

`hard_expiry_ttl_minutes` is an independent optional bound. When configured,
Cybort deletes items older than that window at the start of every collection
run, before source planning, even when the source is unavailable. Omit it when
last-known-good items must survive outages; use it when a source requires a
wall-clock local bound.

To remove one instance's items, synchronization state, and fetch history after
an instance is removed from configuration or an approved use ends, run:

```bash
bundle exec bin/cybort purge INSTANCE_ID --backup /path/to/backup.sqlite3
```

The command requires typing `PURGE INSTANCE_ID` unless `--yes` is supplied. A
backup is optional but recommended; deletion is transactional and irreversible
after the backup step completes.

### Reddit connector

A separate public RSS-only connector is available as the experimental
`reddit_rss` adapter. It retains bounded rank history and selects highlights
from an explicitly observed pool—not a subreddit-wide vote percentile. See the
[design](docs/superpowers/specs/2026-09-06-reddit-rss-design.md) and
[plan](docs/superpowers/plans/2026-09-06-reddit-rss.md), and copy its commented
shape from [.cybort.example.toml](.cybort.example.toml).

`reddit_rss` requires only a normalized list of 1–10 public subreddit names, a
printable identifying User-Agent, and optional four-part integer weights. It
fetches one bounded Atom page each for `new`, `rising`, and `top`, with no OAuth,
cookies, private messages, subscription discovery, HTML scraping, JSON
fallback, or alternate host. A configured group is one pooled ranking universe;
use a new instance ID when changing membership. The denominator is the
observed local candidate pool, so results are not population-wide measurements.
Only a complete three-feed remote success advances history and replaces the
selected snapshot. Cache hits and failures preserve the last-known-good items
and state; the process-local request lane's backoff is not durable across CLI
invocations. Invoke externally at the configured TTL (for example every 15
minutes) and honor any server retry hint.

Public-feed permission, availability, exact Atom shape and `t3_` permalink
identity, feed ordering, combined-group behavior, returned limits, and whether
`published` reflects post creation remain live release gates. Two legitimate
low-volume polls are also required to confirm warmup/history behavior. Keep the
connector experimental until those checks are confirmed for the intended use;
unauthenticated RSS is not an exemption from Reddit policies. The current
`reddit` connector below still uses OAuth.

Reddit uses the documented OAuth Data API directly. Configure an approved
confidential OAuth application and obtain its authorization-code refresh token
outside Cybort; Cybort does not provide an interactive login flow. The token,
client secret, and client ID are configuration inputs only. Cybort exchanges the
refresh token for short-lived bearer access and does not persist the access
token.

The Reddit-specific keys and limits are:

- `client_id`, `client_secret`, and `refresh_token` are required nonblank
  printable strings of at most 256, 1,024, and 4,096 UTF-8 bytes respectively.
- `user_agent` is required, is limited to 256 bytes, and must identify the
  application and Reddit user in the form
  `product:app:version (by /u/username)`. C0 controls and DEL are rejected in
  all four credential/User-Agent fields. These values never appear in stored
  items, metadata, URLs, errors, or logs.
- The external OAuth grant must include `read`, `mysubreddits`, and
  `privatemessages` scopes. `read` permits thread listings, `mysubreddits`
  discovers joined communities, and `privatemessages` reads the legacy unread
  inbox listing.
- `include_subreddits` and `exclude_subreddits` are optional arrays of at most
  50 names each. Names omit `r/`, contain 2–21 letters, numbers, or
  underscores, and are normalized case-insensitively. Exclusions win over
  inclusions and subscriptions.
- `num_items_to_fetch` must be an integer from 1 through 100. It limits the
  final combined selection, not candidate scanning, subreddit discovery, or
  retention.

The default subreddit scope is all discovered subscriptions, but coverage is
deliberately bounded: Cybort fully paginates subscription discovery and then
samples one authenticated personalized `/hot` page, retaining only posts whose
subreddit is in the effective joined set. This is not an exhaustive hot-page
scan of every joined subreddit. Each explicit, non-subscribed included
subreddit receives one documented `/r/<name>/hot` request. If `news` is joined,
Cybort makes one additional `/r/news/hot` request so a megathread is not lost
from the personalized sample; if `news` is explicitly included, its ordinary
single-subreddit request is sufficient. Excluded communities receive neither
selection nor avoidable outbound requests. Cybort never constructs a
multi-subreddit `+` path and only fetches the first hot page from each listing.

Unread collection uses `/message/unread` with `mark=false` and paginates before
applying the quota so unrelated inbox objects cannot crowd out qualifying
legacy private messages. V1 does not read consumer Reddit Chat: it reports chat
as unsupported by the documented Data API. The authenticated release gate below
must verify the observed unread state before this connector is treated as
production-ready.

Thread activity is deterministic. For each candidate, negative scores and
comment counts are clamped to zero, `age_minutes` is
`max(floor((fetched_at - created_utc) / 60), 60)`, and
`activity_score_milli` is:

```text
floor((vote_score + (2 * comment_count)) * 60_000 / age_minutes)
```

Candidates rank by activity score descending, then comment count, visible vote
score, creation time, and fullname (each descending except fullname, which is
ascending). In `r/news`, a title matching `mega thread` or `live thread`
(case-insensitively, allowing whitespace in “mega thread”) is a megathread;
`stickied` is retained as metadata but does not define one. With a limit of 1,
an unread message wins over a megathread, which wins over an ordinary thread.
With a limit of at least 2, Cybort reserves an available message and thread,
and reserves an available `r/news` megathread when capacity permits, then fills
remaining slots in message, megathread, ordinary-thread order. Every selected
item receives a one-based `info.selection_rank` in final output order. Message
priority is 100; thread priority ranges from 99 to 0 by activity rank. Priority
does not change the global CLI ordering: the CLI still presents durable items
by `remote_created_at` (falling back to `fetched_at`) descending.

Stored Reddit items contain message subjects or thread titles, canonical Reddit
URLs, timestamps, the visible Reddit score, comment totals, and small typed
metadata. They do not contain bodies, comments, authors/usernames, media,
previews, outbound linked-page content, or raw API responses. Reddit's `score`
is the visible/fuzzed value, not a guarantee of an exact vote total. LLM
summaries and aggregate statistics about personal posts are deferred.

Each complete successful remote Reddit fetch is a current bounded snapshot and
atomically replaces that instance's prior selected items. A cache hit, failed
fetch, or incomplete remote operation leaves the prior items intact. The normal
`retention_ttl_minutes` transaction still applies to successful remote writes;
for Reddit, configure it at or below 2,880 minutes (48 hours) unless there is
a deliberate reason not to. `hard_expiry_ttl_minutes` provides a separate
startup-bound local deletion policy when a wall-clock bound is required.
Removing an instance does not automatically purge its local rows; use the
explicit `purge` workflow above. To remove locally stored Reddit data, stop
Cybort and delete the intended
SQLite installation data (normally `~/.cybort/cybort.sqlite3`); this is
irreversible, so make any desired backup first. See
[`docs/quality-followups.md`](docs/quality-followups.md) for the deferred
lifecycle work.

#### Reddit authenticated release gate

Offline fixtures verify parsing and selection but cannot establish the live
Reddit contract. Before declaring the connector production-ready, run one
account-authenticated smoke test with the configured read-only scopes. Record
only sanitized statuses and response shapes: successful token fields/scopes,
valid `t5` and `t4` cursor shapes, `/hot` and one `/r/<name>/hot` request,
rate-limit headers, absence of any `+` route, and the qualifying unread
message IDs/count immediately before and after collection. The before/after
check must show that the `mark=false` fetch did not change qualifying unread
state. Do not record credentials, access tokens, bodies, authors, or raw
responses. This gate has not been run in the current development environment.

### Gmail connector (experimental)

Gmail uses the direct Gmail REST API through Cybort's existing HTTP client. The
runtime has no `gws` or `gcloud` executable dependency and never performs an
interactive login, discovers ambient credentials, or writes OAuth files. It
fetches one bounded list page followed by metadata requests (1–500 selected
messages) and remains experimental until the authenticated smoke-test gate
below has passed.

#### Gmail setup

Authorize Gmail outside Cybort with a user-owned Desktop OAuth client:

1. Select or create a personal [Google Cloud project](https://console.cloud.google.com/),
   then [enable the Gmail API](https://console.cloud.google.com/apis/library/gmail.googleapis.com).
2. In [Google Auth Platform](https://console.cloud.google.com/auth/overview),
   configure branding and audience, and add the Gmail read-only scope. If the
   app is external and in **Testing**, add the intended Gmail account as a test
   user.
3. On the [OAuth Clients page](https://console.cloud.google.com/auth/clients),
   create a **Desktop app** client and download its JSON. This downloaded
   client JSON is setup input only: it is not the runtime credential file and
   does not contain a user's refresh token.
4. Install the [Google Cloud CLI](https://docs.cloud.google.com/sdk/docs/install-sdk)
   if it is not already available. In your terminal, place the downloaded
   client JSON at the example path below and create a private, per-mailbox
   bootstrap directory:

   ```sh
   mkdir -p "$HOME/.cybort/google-auth/personal_gmail"
   chmod 700 "$HOME/.cybort/google-auth/personal_gmail"
   CLOUDSDK_CONFIG="$HOME/.cybort/google-auth/personal_gmail" \
     gcloud auth application-default login \
       --client-id-file="$HOME/Downloads/cybort-google-client.json" \
       --scopes=https://www.googleapis.com/auth/gmail.readonly
   chmod 600 "$HOME/.cybort/google-auth/personal_gmail/application_default_credentials.json"
   ```

   The command opens Google's browser consent flow. `CLOUDSDK_CONFIG` keeps
   this bootstrap state separate from the normal Cloud CLI directory; a named
   `gcloud --configuration` alone is not the credential-file isolation
   contract. Verify the generated path and permissions yourself. These setup
   commands are documentation for the user; Cybort does not run them.
5. Authorize the intended account in the browser, then copy the relevant fields
   from the [commented configuration template](.cybort.example.toml) into
   `~/.cybort/cybort.toml`. Keep `credentials_file` pointed at the generated
   `application_default_credentials.json`, and keep the same instance ID when
   migrating the same account so its existing local data remains associated
   with that account. Use a new directory and instance ID for another mailbox;
   this prevents local items from being silently mixed.

For the `in:anywhere` query, set `include_spam_trash = true` when Spam or
Trash should be eligible; the query syntax does not set the Gmail API's
separate `includeSpamTrash` flag. See the [commented template](.cybort.example.toml).

The runtime scope is
`https://www.googleapis.com/auth/gmail.readonly`. Gmail read-only is a
restricted scope, so Google's consent, verification, and applicable Workspace
administrator policies still apply. External apps in Testing commonly receive
refresh tokens that expire after seven days for Gmail access; consent status,
password changes, revoked grants, or administrator policy can also require
reauthorization. Publishing status alone is not a universal remedy for those
constraints, so do not treat this setup as unattended-use approval.

`credentials_file` must be an absolute path or `~/...`; static configuration
validation does not read the file or contact the network. A missing key is
allowed so an existing fresh cache remains readable, but the next remote fetch
fails with a setup diagnostic (exit status `1`). A relative path, wrong type,
or other malformed static value is a configuration error (exit status `2`). A
remote attempt also checks that the file is a regular, user-owned private file
with no group/other permission bits (normally mode `0600`), and accepts only a
bounded `authorized_user` JSON shape. Diagnostics do not include the path,
query, user ID, tokens, credential contents, or remote response bodies.

Existing Gmail configurations without `credentials_file` are not rewritten and
no local data is deleted. Fresh cached data continues to be served without
opening a credential file; a stale or forced fetch reports the missing setup
while preserving the last-known-good items and freshness. Do not read, decrypt,
revoke, or delete any previous `gws` state automatically. Authenticate through
the dedicated procedure above instead.

#### Gmail authenticated release gate

Offline fixtures verify the credential, token, list/detail, normalization,
cache, and failure-isolation contracts but cannot establish a live grant. An
authorized account was not available for this implementation pass, so the
manual gate remains open and Gmail remains experimental. Before calling it
production-ready, run a separate one-message smoke test through the Gmail
adapter using the dedicated credential directory. Record only sanitized
statuses, granted scope names when available, response field names, counts,
timings, and whether the read/unread labels are unchanged before and after.
Verify token/list/get, cache behavior, and that collection works without
`gws` or `gcloud` in the runtime PATH. Never print credentials, access tokens,
full mail JSON, bodies, or raw headers.

## Fetch data

Use cached data when each adapter’s TTL is still fresh:

```bash
bundle exec bin/cybort
```

For an installation initialized outside `~/.cybort`, select it explicitly:

```bash
bundle exec bin/cybort --root /path/to/cybort
```

Ignore TTL checks and request fresh source data:

```bash
bundle exec bin/cybort --force-fetch
```

The default command emits one complete, newline-terminated diagnostic message
for each source as it starts and finishes. A successful source reports its
item count, new and cached counts, and any expired items purged; a failed
source reports a concise error. A source failure produces a partial-failure
exit status while preserving successful results and the failed source’s
last-known-good data.

For scripts that need the structured run summary, request the explicit JSON
mode:

```bash
bundle exec bin/cybort --json
bundle exec bin/cybort --json --force-fetch
```

JSON mode emits overall status, grouped unavailable-dependency guidance,
per-instance status, and persisted items. Neither mode is a dashboard; both
are collection interfaces over the same normalized store.

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
- [Reddit integration design](docs/superpowers/specs/2026-09-05-reddit-integration-design.md)
- [Reddit snapshot replacement ADR](docs/adr/0004-current-snapshot-item-replacement.md)
- [Reddit integration implementation plan](docs/superpowers/plans/2026-09-05-reddit-integration.md)
- [Deferred quality follow-ups](docs/quality-followups.md)
