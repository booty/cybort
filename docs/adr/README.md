# Architecture Decision Records

ADRs document accepted architectural decisions and their rationale. They are
historical records: when an accepted decision changes, create a new ADR that
supersedes the old one instead of silently rewriting it.

| ID | Status | Decision | Date |
|---|---|---|---|
| [0001](0001-persistence-storage-and-write-ownership.md) | Accepted | One SQLite database and orchestrator-owned sequential persistence | 2026-08-16 |

When adding an ADR:

1. Use the next zero-padded numeric ID.
2. State the status and date near the top of the document.
3. Explain context, the decision, alternatives, and consequences.
4. Add or update its row in this index.
5. If an older ADR has been superceded, update its row in the index and set Status to "Superceded"
