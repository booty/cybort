# Architecture Decision Records

ADRs document accepted architectural decisions and their rationale. They are
historical records: when an accepted decision changes, create a new ADR that
supersedes the old one instead of silently rewriting it.

| ID | Status | Decision | Date |
|---|---|---|---|
| [0001](0001-persistence-storage-and-write-ownership.md) | Accepted | One SQLite database and orchestrator-owned sequential persistence | 2026-08-16 |
| [0002](0002-external-command-dependencies-and-cli-adapters.md) | Superseded | Replaced by [0005](0005-gmail-direct-api-and-external-oauth-bootstrap.md), which retains generic dependency preflight and replaces the Gmail mechanism | 2026-09-04 |
| [0003](0003-configurable-item-retention.md) | Accepted | Optional per-instance item retention after successful remote fetches ([design](../superpowers/specs/2026-09-05-configurable-item-retention-design.md)) | 2026-09-05 |
| [0004](0004-current-snapshot-item-replacement.md) | Accepted | Optional complete-result replacement of one instance's current item set ([design](../superpowers/specs/2026-09-05-reddit-integration-design.md), [plan](../superpowers/plans/2026-09-05-reddit-integration.md)) | 2026-09-05 |
| [0005](0005-gmail-direct-api-and-external-oauth-bootstrap.md) | Accepted | Direct Gmail API with external OAuth bootstrap; implementation pending ([design](../superpowers/specs/2026-09-06-gmail-direct-api-design.md), [plan](../superpowers/plans/2026-09-06-gmail-direct-api.md)) | 2026-09-06 |
| [0006](0006-reddit-rss-observed-ranking.md) | Accepted | Separate public Reddit RSS adapter with bounded observed-pool ranking; implementation and live gates pending ([design](../superpowers/specs/2026-09-06-reddit-rss-design.md), [plan](../superpowers/plans/2026-09-06-reddit-rss.md)) | 2026-09-06 |

When adding an ADR:

1. Use the next zero-padded numeric ID.
2. State the status and date near the top of the document.
3. Explain context, the decision, alternatives, and consequences.
4. Add or update its row in this index.
5. If an older ADR is superseded, retain its row with status `Superseded` and link to the replacement ADR.
