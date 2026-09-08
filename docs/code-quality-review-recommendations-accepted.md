# Code-quality review recommendations

Review scope: current `main` implementation and the project design/ADR
documents. No tests, linters, builds, or source changes were run as part of
this read-only review.

## Concrete correctness and maintainability recommendations


2. **Make `Item`'s boolean and value-object contract explicit.**
   `Item` accepts any `action_item` value at `lib/cybort/item.rb:24-35`, while
   `Persistence#upsert_item` converts every non-`nil` truthy value to `1` at
   `lib/cybort/persistence.rb:148`. For example, `"false"` or `0` silently
   round-trips as `true`. Reject values other than `nil`, `true`, and `false`
   (and add a regression test). Consider also duplicating/freezing `urls` and
   `info`, or returning copies from `to_h` (`lib/cybort/item.rb:39-50`), so
   callers cannot mutate a cached item through an accessor or serialized hash.

3. **Reject duplicate item identities before persistence.**
   `Persistence#write_fetch_result` validates and upserts each item at
   `lib/cybort/persistence.rb:93-99`, but the `ON CONFLICT` clause at
   `lib/cybort/persistence.rb:129-137` means duplicate
   `(instance_id, canonical_id)` values in one result silently become
   last-write-wins. This can make `item_count`, `new_items`, and snapshot
   behavior disagree with the returned collection. Detect duplicate canonical
   IDs before the replacement/delete phase and raise `ValidationError` (or
   explicitly deduplicate with a documented policy).

4. **Avoid hydrating the entire cache for remote-only runs and use set
   membership for counts.**
   `Orchestrator#run` loads every item for every instance at
   `lib/cybort/orchestrator.rb:64` through `Persistence#context_for`/
   `items_for` (`lib/cybort/persistence.rb:47-68`), even when a forced or
   stale remote fetch only needs freshness/sync state. This is already called
   out in `docs/quality-followups.md`; split lightweight planning context from
   cache-item hydration. Also, `lib/cybort/orchestrator.rb:199-203` performs
   two `Array#include?` scans for every fetched item, making status accounting
   O(existing × fetched). Use a `Set` (or a persistence-side count) while
   retaining the full item list only on cache paths.

5. **Resolve the alternate-installation path mismatch.**
   `cybort init /path` accepts an alternate location at
   `lib/cybort/cli.rb:14-16`, but normal execution hard-codes
   `home/.cybort` at `lib/cybort/cli.rb:18-20`. The README advertises the
   alternate init path as a workflow, while `docs/LEARNINGS.md` records the
   gap as open. Add an explicit runtime root option/environment setting, or
   stop presenting alternate initialization as a usable runtime installation.

## Optional polish

- Add deterministic tie-breakers to `Persistence#items_for` after the primary
  timestamp sort (`lib/cybort/persistence.rb:63`). Items sharing a timestamp
  currently have database-dependent output order, which makes CLI/JSON output
  harder to compare and test.
- Move adapter display names and item nouns out of the two hard-coded maps in
  `Orchestrator#fetch_start_message` and `#progress_message`
  (`lib/cybort/orchestrator.rb:231-252`). The newly registered `reddit_rss`
  adapter falls through to the raw adapter name and generic “items”; registry
  metadata would make adding connectors less error-prone. Alternatively, consider having the orchestrator iterate over files in lib/cybort/adapters and autoload them.
- Consolidate small helpers that are duplicated with slightly different error
  text: `unsafe_controls?` in `lib/cybort/reddit_rss_client.rb:278-352`, the
  two `option` methods in `lib/cybort/adapters/reddit.rb:447-489`, and numeric
  validators duplicated between `HttpClient` and `NetHttpTransport`
  (`lib/cybort/http_client.rb:98-114` and `:258-274`). Preserve the current
  boundary-specific exception categories while extracting shared mechanics.
- `RedditRssState` intentionally validates both pre-canonical and canonical
  representations, but the near-parallel candidate/poll/rank validators at
  `lib/cybort/reddit_rss_state.rb:346-398` and `:449-498` will drift unless
  shared semantic checks or table-driven shape helpers are introduced. Keep the
  raw-key/duplicate-key pass separate because it protects the JSON boundary.
