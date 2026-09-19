# Live Connector Release Gates

This ledger records checks that local fixtures cannot prove. A connector stays
experimental until its required external checks are explicitly recorded as
passed. Do not put credentials, tokens, message bodies, feed bodies, or raw
health data in this file.

**Last reviewed:** 2026-09-19  
**Default status:** Open unless a row below contains dated evidence and an
explicit pass.

## Gate status

| Connector | Status | Required evidence | Current note |
|---|---|---|---|
| Gmail | Open | Authenticated direct-API token exchange, granted read scope, list/get response shapes, cache behavior, and unchanged read/unread labels | No release sign-off recorded |
| Reddit OAuth | Open | Authenticated token scopes, documented response paths/shapes, rate headers, bounded selection, and unread reads with `mark=false` leaving qualifying state unchanged | Reddit Chat remains unsupported |
| Reddit RSS | Open | Permitted public access, availability, exact Atom shape, `t3_` identity/permalinks, publication-time meaning, feed ordering, combined groups, limits, and two legitimate low-volume polls | No alternate host, HTML, JSON fallback, or identity rotation |
| Apple Health | Open | Sanitized real-export shape, repeat/import idempotence, append-only behavior, local-temp operational check, and missing-source behavior | An authorized local export was exercised, but no release sign-off is recorded |

## Recording a gate

Before testing, confirm that the request is permitted and use the lowest
reasonable request volume. Run the smallest live probe that establishes the
listed evidence; do not turn a release gate into a polling loop.

After a successful probe, record:

- the date and connector/configuration shape (without secrets);
- the runtime/client version and endpoint family;
- the bounded observations that establish each requirement;
- the commit or test evidence for any local behavior relied upon; and
- whether the connector remains experimental or is explicitly approved for
  unattended use.

If permission, availability, response shape, privacy, or state-preservation
behavior is uncertain, leave the gate open and document the blocker in
`docs/LEARNINGS.md`. Offline tests remain valuable but do not substitute for
these checks.
