# Deferred Quality Follow-ups

These items were identified during the 2026-09-05 adversarial reviews of
configurable retention and the Reddit integration. They are intentionally
deferred because they require broader measurement, lifecycle UX, or an
architecture change, not because they are needed for the approved
success-triggered retention and current-snapshot contracts.

## Establish a staged RuboCop baseline

The repository now bundles RuboCop and RuboCop Performance, but the existing
codebase has no `.rubocop.yml`; a full run currently reports 2,754 offenses
across 52 files, mostly legacy string-literal, frozen-string, layout, and
metrics defaults. The reviewed Reddit/transport production files are clean for
the focused Lint and Security departments.

Follow-up: agree on a project style baseline, add configuration in stages, and
ratchet only changed files or newly touched cops before enabling a whole-tree
gate. Do not mass-autocorrect the existing suite without a separately reviewed
formatting change.

Evidence: `bundle exec rubocop --format simple` and
`bundle exec rubocop --only Lint,Security --format simple
lib/cybort/http_client.rb lib/cybort/reddit_client.rb
lib/cybort/adapters/gmail.rb lib/cybort/reddit_rate_limit_coordinator.rb
lib/cybort/configuration.rb` on 2026-09-05.

## Avoid eager item hydration during remote-only runs

`Orchestrator#run` currently asks `Persistence#context_for` for every instance
before planning. That call materializes all stored items, even when a forced or
stale remote fetch will discard them and the CLI will read the database again
after persistence.

Follow-up: split freshness/synchronization metadata from item hydration, or
load item rows only for cache paths. Measure retained item counts and startup
memory/time before choosing the API shape.

Evidence: `lib/cybort/orchestrator.rb`, `lib/cybort/persistence.rb`, and the
2026-09-05 Sol adversarial review.

## Evaluate an instance/fetched-at pruning index

Retention deletes by `instance_id` and `fetched_at`, while the current primary
key is `(instance_id, canonical_id)`. A composite index may improve pruning for
large histories, but adding it requires a schema migration.

Follow-up: collect realistic database-size/query timings first, then decide
whether to add a migration for `(instance_id, fetched_at)`.

Evidence: `lib/cybort/schema.rb`, `lib/cybort/persistence.rb`, and the
2026-09-05 Sol adversarial review.

## Add hard wall-clock expiry independent of fetch success

Both configured retention and current-snapshot replacement intentionally run
only after a successful remote fetch. During a prolonged authentication,
network, rate-limit, or service outage, locally stored Reddit subjects and
titles can therefore outlive the configured retention interval. The Reddit
integration must not be represented as guaranteeing a fixed deletion deadline
or full Data API deletion compliance during outages.

Follow-up: design an explicit background/startup expiry mechanism, including
clock ownership, transaction behavior, cache presentation, failure reporting,
and how it supersedes or composes with ADR 0003. Treat this as a Reddit release
and operator compliance caveat until that design is accepted. Operators who
require a hard bound must remove the affected local data themselves rather than
relying solely on successful-fetch cleanup.

Evidence: [ADR 0003](adr/0003-configurable-item-retention.md),
[ADR 0004](adr/0004-current-snapshot-item-replacement.md), and the 2026-09-05
independent Reddit design review.

## Add explicit instance-removal and user-request deletion workflows

Removing an instance from `cybort.toml`, revoking Reddit access, terminating an
approved use, or receiving a user deletion request does not currently target
and purge that instance's items, synchronization state, and fetch history.
Snapshot replacement cannot help when no later successful fetch occurs.

Follow-up: design an explicit, narrowly targeted lifecycle command/API with a
reviewable deletion boundary, backup guidance, recovery expectations, and tests
for instance-ID isolation. Treat the absence of this workflow as a Reddit
release/operator compliance caveat. Until it exists, operators remain
responsible for deleting the SQLite database or otherwise removing the affected
local data when access or approved use ends.

Evidence: `lib/cybort/persistence.rb`,
[ADR 0004](adr/0004-current-snapshot-item-replacement.md), Reddit's
[Data API Terms](https://redditinc.com/policies/data-api-terms), and the
2026-09-05 independent Reddit design review.
