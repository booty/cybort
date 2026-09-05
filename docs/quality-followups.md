# Deferred Quality Follow-ups

These items were identified during the adversarial review of configurable item
retention on 2026-09-05. They are intentionally deferred because they require
broader performance measurement or a schema/architecture change, not because
they are needed for retention correctness.

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
