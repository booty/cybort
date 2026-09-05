# Architecture Decision Records

ADRs document accepted architectural decisions and their rationale. They are
historical records: when an accepted decision changes, create a new ADR that
supersedes the old one instead of silently rewriting it.

| ID | Status | Decision | Date |
|---|---|---|---|
| [0001](0001-persistence-storage-and-write-ownership.md) | Accepted | One SQLite database and orchestrator-owned sequential persistence | 2026-08-16 |
| [0002](0002-external-command-dependencies-and-cli-adapters.md) | Proposed | Hybrid HTTP/CLI connectors with startup dependency preflight ([design](../superpowers/specs/2026-09-04-external-command-connectors-design.md), [plan](../superpowers/plans/2026-09-04-external-command-connectors.md)) | 2026-09-04 |
| [0003](0003-configurable-item-retention.md) | Accepted | Optional per-instance item retention after successful remote fetches ([design](../superpowers/specs/2026-09-05-configurable-item-retention-design.md)) | 2026-09-05 |

When adding an ADR:

1. Use the next zero-padded numeric ID.
2. State the status and date near the top of the document.
3. Explain context, the decision, alternatives, and consequences.
4. Add or update its row in this index.
5. If an older ADR has been superceded, update its row in the index and set Status to "Superceded"
