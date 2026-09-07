# Project Learnings

This file records dated implementation discoveries and gotchas that are not
architectural decisions. Each entry should include evidence and a status so a
future agent can distinguish observed behavior from an open follow-up.

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
