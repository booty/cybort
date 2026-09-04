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
