# Project Learnings

This file records dated implementation discoveries and gotchas that are not
architectural decisions. Each entry should include evidence and a status so a
future agent can distinguish observed behavior from an open follow-up.

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

**Status:** Open

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

**Impact:** ADR 0002 and the connector design must remain Proposed, and README
must describe Gmail as experimental until a real account verifies the granted
read-only scope, list JSON, and detail JSON. The version parser now accepts the
installed CLI's `gws X.Y.Z` output.

**Next action:** Re-run `gws auth login --scopes
https://www.googleapis.com/auth/gmail.readonly` in the same host/keyring used by
Cybort, or provide a documented `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE` /
Gmail-scoped `GOOGLE_WORKSPACE_CLI_TOKEN`. Then run `gws auth status`, one
explicit-scope list request, and one metadata detail request; record only the
version, scope names, exit statuses, and sanitized JSON shape before changing
the supported range or ADR status.
