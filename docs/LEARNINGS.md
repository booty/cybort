# Project Learnings

This file records dated implementation discoveries and gotchas that are not
architectural decisions. Each entry should include evidence and a status so a
future agent can distinguish observed behavior from an open follow-up.

## 2026-09-07 — RSS rank history needs independent bounds and verified timestamps

**Status:** Design constraint recorded; RSS detector implementation pending.

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

**Next action:** Implement the [plan](superpowers/plans/2026-09-06-reddit-rss.md)
and its state/clock/transaction regressions only when requested. Verify permitted
access, publication meaning, ordering, and combined feeds separately before
removing the experimental designation. No project tests ran for this planning work.

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

## 2026-09-04 — Alternate installation paths are not selectable at runtime

**Status:** Open

**Observation:** `cybort init /alternate/path` creates an installation at the
specified path, but normal CLI execution currently reads `~/.cybort` and has no
installation-path option.

**Evidence:** `lib/cybort/cli.rb`; installer tests cover creation at an
alternate path, while CLI startup uses `Dir.home`.

**Impact:** An alternate installation cannot currently be run through the
normal CLI without additional path-selection support.

**Next action:** Add an explicit installation-path option or environment
setting before documenting alternate paths as a complete runtime workflow.

## 2026-09-04 — Gmail connector remains experimental pending gws contract smoke test

**Status:** Superseded as implementation direction on 2026-09-06 by
[ADR 0005](adr/0005-gmail-direct-api-and-external-oauth-bootstrap.md).
The observed failure remains relevant to the current, still-unreplaced `gws` runtime.

**Observation:** The Gmail adapter is implemented behind the Google-maintained
`googleworkspace/cli` `gws` executable, with an explicit read-only scope and a
tested-version gate in code. `gws` is installed at `/usr/local/bin/gws` and
reports `gws 0.22.5`, which matches the supported range. A real Cybort
read-only fetch reached `gws`, but the available credential returned an
insufficient-authentication-scopes API error; the local gws credential cache is
not currently usable in this execution environment.

**Evidence:** `bundle exec rake test` passes with 116 runs and 408 assertions;
`gws --version` returned `gws 0.22.5`; `gws auth status` reported no usable
credential after an undecryptable cache was removed; a gcloud-minted token
changed the Cybort failure from missing credentials to API exit code 1 with
`insufficient authentication scopes`; and `gws ... --dry-run` resolved the
expected Gmail list endpoint. The manual gate is documented in the connector
design and README.

**Impact:** This evidence originally kept ADR 0002 Proposed and Gmail
experimental. ADR 0005 now supersedes that architectural direction, with a
separate direct-API release gate. The existing runtime remains experimental.
The version parser accepts the installed CLI's `gws X.Y.Z` output.

**Next action:** Implement the
[direct Gmail API plan](superpowers/plans/2026-09-06-gmail-direct-api.md), then
verify its dedicated OAuth bootstrap and authenticated read contract. Do not
interpret this historical failure as proof of the cause of every later Gmail error.
