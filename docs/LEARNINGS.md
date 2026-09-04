# Project Learnings

This file records dated implementation discoveries and gotchas that are not
architectural decisions. Each entry should include evidence and a status so a
future agent can distinguish observed behavior from an open follow-up.

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
tested-version gate in code. The development environment does not have `gws`
installed, so the real list/detail command contract and granted scopes have not
been authenticated or verified.

**Evidence:** `bundle exec rake test` passes with 114 runs and 398 assertions;
`command -v gws` and `gws --version` produced no output on 2026-09-04. The
manual gate is documented in the connector design and README.

**Impact:** ADR 0002 and the connector design must remain Proposed, and README
must describe Gmail as experimental until a real account verifies version,
scope set, list JSON, and detail JSON.

**Next action:** With an authenticated test account, run `gws --version`,
`gws auth status`, one explicit-scope list request, and one metadata detail
request; record only the version, scope names, exit statuses, and sanitized
JSON shape before changing the support range or ADR status.
