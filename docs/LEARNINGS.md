# Project Learnings

This file records dated implementation discoveries and gotchas that are not
architectural decisions. Each entry should include evidence and a status so a
future agent can distinguish observed behavior from an open follow-up.

## 2026-09-07 — Public Reddit RSS is offline-verified but remains experimental

**Status:** Implemented and offline-verified; live release gates remain open.

**Observation:** The selected `reddit_rss` design is now implemented as a
separate registered adapter. It uses local Atom fixtures and injected
HTTP/clock/sleeper dependencies for bounded parsing, three-feed composition,
observed-pool ranking, cache/failure behavior, and SQLite snapshot round-trips.
The OAuth `reddit` connector and generic RSS connector remain separate.

**Evidence:** Tasks 1–5 implementation commits and their focused/system tests;
the final `bundle exec rake test` run completed with 319 runs, 1,612
assertions, 0 failures, 0 errors, and 0 skips. Diff whitespace, Ruby syntax,
and local documentation-link checks also passed. The [implementation plan](superpowers/plans/2026-09-06-reddit-rss.md)
records the release boundary. No live Reddit request or permission check was
performed.

**Impact:** `reddit_rss` is available only as an explicitly configured,
experimental public-feed connector. Its denominator is an observed local
candidate pool, and its bounded state and selected snapshot are committed only
after a complete three-feed success. Offline evidence does not establish public
permission, feed availability, or ranking/timestamp semantics.

**Next action:** Before unattended use, verify permitted access and the exact
three public routes, Atom identity/permalinks, `published` creation-time
meaning, `new`/`rising`/`top` ordering, combined-group behavior and limits, and
two legitimate low-volume poll cycles. Stop on denial or throttle; do not use
alternate hosts, identities, HTML, or JSON fallback.

## 2026-09-07 — RSS rank history needs independent bounds and verified timestamps

**Status:** Superseded as an implementation-pending note on 2026-09-07 by the
offline-verified implementation note above; the design constraints remain
active.

**Observation:** Existing item retention does not prune `sync_state_json`.
The proposed RSS detector therefore needs explicit bounded state transitions.
Atom publication and update times have different meanings, and Atom itself
assigns no ranking significance to entry order. Neither an updated timestamp
nor RSS availability establishes the proposed detector's creation/rank contract.

**Evidence:** `Persistence#update_instance_state` writes returned sync state
unchanged; `prune_expired_items` targets only the items table. [ADR 0003](adr/0003-configurable-item-retention.md)
documents this distinction. [Atom RFC 4287](https://www.rfc-editor.org/rfc/rfc4287)
defines the timestamp/order semantics. The documentation-tool feed probe on
September 6 returned Cache miss, not an observed Reddit status or Atom body.

**Impact:** [ADR 0006](adr/0006-reddit-rss-observed-ranking.md) selects capped
candidates/four-poll history committed with successful snapshots, requires
publication timestamps, and labels the ranked universe observed-only. The
original [sketch](spitballing/reddit-v2-spitballing.md) is preserved unchanged.

**Next action:** The plan and its state/clock/transaction regressions were
implemented after this design-phase note. Verify permitted access, publication
meaning, ordering, and combined feeds separately before removing the
experimental designation; see the implementation note above for current
evidence. The original planning work did not run project tests.

## 2026-09-05 — Reddit transport deadlines and errors need boundary normalization

**Status:** Active

**Observation:** A per-request timeout alone is not a total Reddit fetch
deadline: Net::HTTP read timeouts are inactivity-based and can reset between
streamed chunks. Transport failures also need to be converted before adapter
errors reach persistence, and a rate response without reset metadata must not
poison a process-wide client key forever.

**Evidence:** `lib/cybort/http_client.rb` enforces an injected monotonic
deadline across streamed reads and maps common socket/EOF/TLS failures to
`HttpTransportError`; `lib/cybort/reddit_rate_limit_coordinator.rb` uses a
finite unknown-reset cooldown; `test/http_client_test.rb`,
`test/reddit_rate_limit_coordinator_test.rb`, and
`test/system/cli_system_test.rb` cover the regressions.

**Impact:** Injected HTTP doubles may omit the optional deadline keyword, but
the production `NetHttpTransport` must implement it for the absolute deadline
contract. Configuration parse errors must remain content-free because CLI
stderr is user-visible.

**Next action:** Keep the authenticated Reddit smoke gate and real TCP/TLS
transport coverage as release work; offline tests intentionally use injected
transports.

## 2026-09-05 — Installed Minitest lacks arbitrary-object `stub`

**Status:** Active

**Observation:** Under the installed Minitest 6.0.6, ordinary objects do not
respond to `stub`, so `persistence.stub(:method, replacement) { ... }` cannot be
used for a scoped late-transaction failure.

**Evidence:** `bundle exec ruby -Itest -e 'require "test_helper"; puts
Minitest::VERSION; p Object.new.respond_to?(:stub)'` printed `6.0.6` and
`false`. `test/persistence_test.rb` injects the fetch-history failure with a
singleton-method override and restores it in `ensure`.

**Impact:** Tests that need to replace a method on an arbitrary object must use
another scoped mechanism and guarantee restoration even when an assertion
fails.

**Next action:** Keep the current singleton-method pattern unless the test
framework gains an equivalent scoped arbitrary-object stub API.

## 2026-09-08 — Alternate installation paths are selectable at runtime

**Status:** Resolved

**Observation:** The normal and purge CLI workflows accept `--root PATH`, so an
installation created with `cybort init /alternate/path` can be selected without
changing the default `~/.cybort` behavior.

**Evidence:** `lib/cybort/cli.rb`, `test/cli_test.rb`, and the README runtime
root example.

**Impact:** Alternate installations are now usable through the normal CLI and
can be purged without touching the default installation.

**Next action:** None for this follow-up; retain the option in future command
surface changes.

## 2026-09-04 — Gmail command runtime superseded; direct API gate remains open

**Status:** The former `gws` runtime path was superseded on 2026-09-06 by
[ADR 0005](adr/0005-gmail-direct-api-and-external-oauth-bootstrap.md). The
direct API implementation is offline-verified; its authenticated live gate is
still open, so Gmail remains experimental.

**Observation (historical):** The Gmail adapter was implemented behind the
Google-maintained `googleworkspace/cli` `gws` executable, with an explicit
read-only scope and a tested-version gate in code. `gws` was installed at
`/usr/local/bin/gws` and reported `gws 0.22.5`, which matched the supported
range. A real Cybort read-only fetch reached `gws`, but the available
credential returned an insufficient-authentication-scopes API error; the local
gws credential cache was not currently usable in that execution environment.

**Evidence (historical):** `gws --version` returned `gws 0.22.5`; `gws auth
status` reported no usable credential after an undecryptable cache was removed;
a gcloud-minted token changed the Cybort failure from missing credentials to
API exit code 1 with `insufficient authentication scopes`; and `gws ...
--dry-run` resolved the expected Gmail list endpoint. At that time,
`bundle exec rake test` passed with 116 runs and 408 assertions. Do not
interpret this historical failure as proof of the cause of every later Gmail
error.

**Implementation evidence (2026-09-06):** `lib/cybort/gmail_credentials.rb`,
`lib/cybort/gmail_client.rb`, and `lib/cybort/adapters/gmail.rb` now use an
explicit private `authorized_user` credential file and direct Gmail REST
token/list/get requests. The adapter has no runtime `gws` or `gcloud`
dependency. Offline fixtures cover credential boundaries, HTTP contracts,
normalization, cache behavior, source isolation, and safe diagnostics. The
authorized offline suite `bundle exec rake test` completed with 285 runs,
1,498 assertions, 0 failures, 0 errors, and 0 skips. No authorized account or
mailbox call was available for this implementation pass.

**Impact:** The generic command/preflight infrastructure remains available for
other connectors, while Gmail's former executable/version gate is retired.
The direct connector's setup, cache migration behavior, and static/source
error boundaries are now documented separately from the historical `gws`
failure.

**Next action:** Run the dedicated authenticated OAuth bootstrap and one-message
direct-API smoke test when an authorized account is available. Verify token,
list, and metadata get behavior, granted scope, unchanged read/unread labels,
cache behavior, and absence of executable dependencies. Record only sanitized
results.
