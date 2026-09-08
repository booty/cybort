# Deferred Quality Follow-ups

These items were identified during the 2026-09-05 adversarial reviews of
configurable retention and the Reddit integration. The implementation pass on
2026-09-08 addressed the actionable items while preserving the existing
success-triggered retention contract. The accepted lifecycle decision is in
[ADR 0007](adr/0007-lifecycle-expiry-and-instance-purge.md).

## Establish a staged RuboCop baseline — implemented

The repository now has a checked-in `.rubocop.yml` and a `rake quality` task.
Correctness, security, and performance cops run on the reviewed
connector/configuration files. Style, layout, naming, and metrics remain
disabled until they can be ratcheted in smaller reviewed changes. No mass
autocorrection was performed.

**Evidence:** `.rubocop.yml`, `Rakefile`, and the README quality command.

## Avoid eager item hydration during remote-only runs — implemented

`Persistence#planning_context_for` returns freshness/state metadata and a
canonical-ID set without materializing item objects. The orchestrator uses it
for planning and hydrates full items only for cache plans; remote result
accounting uses the ID set.

**Evidence:** `lib/cybort/persistence.rb`, `lib/cybort/orchestrator.rb`, and
the planning-context tests.

## Evaluate an instance/fetched-at pruning index — implemented

Schema version 2 adds the idempotent composite index
`idx_items_instance_fetched_at` for instance-scoped expiry deletes. `setup!`
creates it for both new and existing databases.

**Evidence:** `lib/cybort/schema.rb` and the persistence schema test.

## Add hard wall-clock expiry independent of fetch success — implemented

`hard_expiry_ttl_minutes` performs instance-scoped startup cleanup using
persistence's clock before planning. It is independent of remote success and
reports `items_expired` metadata. It is intentionally startup-bound rather
than a background daemon; powered-off processes cannot delete data.

**Evidence:** `lib/cybort/configuration.rb`, `lib/cybort/persistence.rb`,
`lib/cybort/orchestrator.rb`, and ADR 0007.

## Add explicit instance-removal and user-request deletion workflows — implemented

`Persistence#delete_instance` and `cybort purge INSTANCE_ID` provide a narrow
instance-ID boundary. The CLI requires exact confirmation unless `--yes` is
supplied and offers `--backup PATH` before deletion. The transaction deletes
fetch history and items before the adapter-instance row.

**Evidence:** `lib/cybort/persistence.rb`, `lib/cybort/cli.rb`, the persistence
and CLI tests, and ADR 0007.
