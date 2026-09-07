# ADR 0006: Public Reddit RSS with Observed-Pool Ranking

- Status: Accepted (design decision; implementation and live gates pending)
- Date: 2026-09-06
- Supplements: [ADR 0004](0004-current-snapshot-item-replacement.md)

## Context

The user cannot currently provision usable Reddit API access and proposed a
public RSS-only detector for noteworthy recent posts. Feed ranks can support
an explainable prominence heuristic, but not exact vote/comment counts or a
statistically representative percentile of an entire subreddit. Public
availability is not proof that every automated use is authorized.

## Decision

Add an explicitly selected `reddit_rss` adapter alongside unchanged OAuth
`reddit`. Fetch one public `new`, `rising`, and `top?t=day` Atom page for one
configured subreddit or combined group. No credentials, private feeds,
pagination, scraping, fallback hosts, or account discovery.

Reuse Ruby RSS and Cybort's bounded HttpClient. Keep at most 2,000 candidate
records and four complete rank observations in existing sync-state JSON. A
pure transformation produces state and selected Items; existing persistence
commits both in one per-result snapshot transaction. No adapter SQL or schema
changes. Complete empty results clear the selection; failed/cached results
preserve prior state. Candidate eviction is independent of item retention.

Use versioned integer weights and fixed-point arithmetic. The quota is a tenth
of all age-eligible observed candidates, capped by configured output limit and
available current top/rising signals. A combined group is one pooled universe.
Always label observed-only coverage, cold starts, gaps, and truncation. Require
publication timestamps and stable post identities. Store no authors or bodies.

Serialize public feed requests within a process with two-second spacing and
observed throttling. Extend safe Retry-After parsing to HTTP-date values. Do not
add a durable retry scheduler; disclose that the external invoker must honor
retry hints between CLI runs. Access permission, feed shape, publication-time
meaning, and ranking order remain release gates.

## Alternatives and consequences

Ordinary RSS instances cannot share a ranking universe or history; replacing
OAuth in place would silently remove capabilities and risk mixing cached
private messages with public posts. A separate adapter makes the change
explicit while retaining useful generic snapshot infrastructure.

State is bounded and transaction-safe, but can remain beyond its nominal
48-hour lifetime during failures. Heuristics are tunable and inspectable, not
calibrated probabilities. Process-local pacing cannot regulate other programs
or separate invocations. A live gate may reveal that publication or ranking
semantics are unavailable; that requires a design revision, not evasion.

Accepted records the user's delegated design authority, not implementation or
permission from Reddit. ADRs 0001, 0003, and 0004 remain accepted and unchanged.

## Records

- [Design and sketch evaluation](../superpowers/specs/2026-09-06-reddit-rss-design.md)
- [Implementation plan](../superpowers/plans/2026-09-06-reddit-rss.md)
- [Original sketch](../spitballing/reddit-v2-spitballing.md)
