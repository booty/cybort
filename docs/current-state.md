# Current Cybort State

This is a compact map for agents. It contains connector-specific details that
are intentionally not repeated in `AGENTS.md`; the linked ADRs and designs are
the authoritative detailed records.

## Architecture snapshot

- `cybort.sqlite3` stores item data, source state, and fetch history.
- `cybort-timeseries.sqlite3` stores series, observations, and import receipts.
- Item adapters run independently and hand results to the orchestrator for
  completion-ordered persistence. Time-series adapters write disposable local
  spools; one dedicated writer imports them into the second database.
- The installation lock covers collection, lifecycle operations, backups, and
  purge. The two databases are not one atomic transaction.

## Connectors

### Gmail (experimental)

Gmail uses the direct Gmail REST API. Authentication is an externally
bootstrapped per-instance Google `authorized_user` credential file; collection
does not execute or depend on `gws` or `gcloud`. The connector remains
experimental until an authenticated smoke test verifies token/list/get shape,
granted read scope, cache behavior, and unchanged read/unread labels.

See [ADR 0005](adr/0005-gmail-direct-api-and-external-oauth-bootstrap.md) and
the [Gmail design](superpowers/specs/2026-09-06-gmail-direct-api-design.md).

### Reddit RSS (experimental)

`reddit_rss` is a separate unauthenticated public Atom-feed adapter. It uses
only fixed `new`, `rising`, and `top?t=day` feeds for configured public
subreddits; it does not use OAuth, cookies, private-feed keys, HTML scraping,
JSON fallback, or alternate hosts. It stores body-free selected items and
bounded observed-pool rank state. A complete three-feed success replaces the
selected snapshot atomically; cache hits and failures preserve prior state.

Its denominator is the observed local candidate pool, not a population-wide
percentile. It remains experimental until permitted public access, feed shape,
publication-time meaning, ordering, combined-group behavior, limits, and two
legitimate low-volume polls are verified live.

The separate `reddit` connector uses documented OAuth Data API endpoints for
subscriptions, bounded personalized `/hot` sampling, explicit subreddit hot
pages, and legacy unread messages with `mark=false`. Reddit Chat is unsupported
by the documented read surface. Storage is body-free and author-free.

See [ADR 0006](adr/0006-reddit-rss-observed-ranking.md), the
[RSS design](superpowers/specs/2026-09-06-reddit-rss-design.md), and the
[Reddit design](superpowers/specs/2026-09-05-reddit-integration-design.md).

### Apple Health (experimental)

`apple_health` is append-only time-series import for one person's dedicated
immediate-child ZIP directory, including an iCloud Drive export source. Archive
fingerprints identify imports; normalized content-derived keys identify
observations. Omitted or corrected source records never delete canonical
observations; explicit purge is the deletion path.

Archive copies, ZIP/XML parsing, and spools stay under local installation
`tmp/`, never inside an iCloud-backed source directory. Source, device, profile,
and free-form metadata are identity-only and not retained as readable
provenance. Keep the connector experimental until sanitized real-export shape,
repeat-import, and operational gates pass.

See [ADR 0010](adr/0010-append-only-time-series-import-results.md), the
[Apple Health design](superpowers/specs/2026-09-11-apple-health-import-design.md),
and the [Apple Health plan](superpowers/plans/2026-09-13-apple-health-import.md).

## Release posture

Gmail, Reddit, Reddit RSS, and Apple Health remain experimental until their
specific live gates are recorded as passed in
[`LIVE_GATES.md`](LIVE_GATES.md). Offline fixtures and the local test suite do
not prove external permission, response availability, or authenticated token
behavior.
