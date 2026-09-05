# Configurable Item Retention Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add optional per-adapter-instance item retention that prunes expired items atomically after successful remote fetches while preserving indefinite retention by default.

**Architecture:** Configuration exposes an optional positive integer `retention_ttl_minutes` as common instance state. Immediately after registry validation, the orchestrator snapshots that mutable value and validates each adapter result against the configured instance ID. It passes the snapshot only when persisting a successful remote fetch, and `Persistence` independently validates the policy, upserts current items, and prunes expired rows for the same instance inside the existing per-result transaction. Persistence uses one clock reading to clamp the adapter's completion time for both the destructive cutoff and durable cache freshness; fetch history retains the raw result timestamp. Existing `items.fetched_at` values serve as last-seen timestamps, so neither the schema nor adapter and fetch-result contracts change.

**Tech Stack:** Ruby 4.0.1, Minitest, SQLite3, TOML via `tomlrb`

**Spec:** `docs/superpowers/specs/2026-09-05-configurable-item-retention-design.md`

## Global Constraints

- `retention_ttl_minutes` is optional; omission produces `nil` and means retain items forever.
- When present, `retention_ttl_minutes` must be a positive integer. Zero, negative values, strings, floats, and booleans are invalid configuration. This is intentionally stricter than the legacy positive-`Numeric` `ttl_minutes` contract because retention controls a destructive boundary; do not change the existing cache-TTL contract in this feature.
- Retention may be less than or equal to `ttl_minutes`. Cache TTL is a freshness minimum, not a fetch schedule: cache hits may preserve items beyond retention, and the next successful remote fetch may remove every unseen item.
- The configuration remains schema version 1, and `retention_ttl_minutes` is a common key rather than an adapter-specific option.
- Snapshot each instance's validated `retention_ttl_minutes` immediately after registry configuration validation and before adapter planning or threads; do not read mutable instance policy after fetch.
- Reject any `FetchResult` whose `instance_id` differs from its configured instance before success or failure persistence. Record mismatch and rescue failures under the configured ID only.
- `Persistence#write_fetch_result` independently accepts only `nil` or a positive `Integer` policy and raises `ValidationError` before deletion for invalid direct callers.
- An item expires when `item.fetched_at <= min(result.finished_at, persistence_clock_now) - (retention_ttl_minutes * 60)`.
- Capture the persistence clock once per successful write where practical. Store `min(result.finished_at, persistence_clock_now)` as `last_successful_fetch`, but retain raw `result.finished_at` in fetch history.
- Both stored `fetched_at` values and the cutoff must pass through `Persistence#timestamp` so lexicographic SQLite comparison remains chronological: UTC ISO 8601, six fractional digits, trailing `Z`.
- Validate and upsert the current result before pruning. Prune only rows with the same `instance_id` as the successful result.
- Upserts, pruning, synchronization-state updates, and successful fetch-history insertion remain one SQLite transaction.
- Successful empty remote fetches prune; cache hits, source failures, dependency failures, and persistence failures do not commit pruning.
- Retention applies only to normalized items. It does not delete adapter-instance records, synchronization state, or fetch-run history.
- Do not add a schema migration, background cleanup, adapter-owned SQL, per-item retention, count-based retention, or a CLI output change.
- Tests must remain offline and use temporary SQLite databases and injected clients.
- Do not modify `docs/initial-spitballing.md` or include the existing untracked `.serena/` directory in a commit.

## Deferred quality follow-ups

- Avoid eager hydration of every stored item into adapter contexts when a fetch
  can be planned without item bodies.
- Consider a composite pruning index and schema migration only after measured
  database size/query evidence justifies it.

---

## File Map

| File | Responsibility |
|---|---|
| `lib/cybort/configuration.rb` | Parse, validate, and expose the optional common retention duration. |
| `test/configuration_test.rb` | Lock down omission, valid values, invalid values, per-instance independence, retention/cache-TTL relationships, and separation from adapter options. |
| `lib/cybort/persistence.rb` | Prune expired items for one instance inside the successful-result transaction. |
| `test/persistence_test.rb` | Prove cutoff, last-seen, isolation, empty-result, default, and rollback semantics. |
| `lib/cybort/orchestrator.rb` | Associate each result with its configured retention duration and pass it to persistence. |
| `test/orchestrator_test.rb` | Prove policy propagation and that cached/failed results do not reach the pruning write path. |
| `test/system/cli_system_test.rb` | Prove a successful fetch prunes rows before the CLI reads its final item list. |
| `README.md` | Document the three independent limits and the optional retention setting. |
| `AGENTS.md` | Record the implemented retention behavior as a stable project invariant. |

No change is planned for `lib/cybort/schema.rb`, `lib/cybort/fetch_result.rb`, or any adapter.

---

### Task 1: Parse and Validate the Optional Retention Duration

**Files:**
- Modify: `test/configuration_test.rb`
- Modify: `lib/cybort/configuration.rb`

**Interfaces:**
- Consumes: TOML instance tables accepted by `Cybort::Configuration.load(path)` and `Cybort::Configuration.new(data)`.
- Produces: `Cybort::Configuration::Instance#retention_ttl_minutes -> Integer | nil`.
- Preserves: `Instance#options` contains only adapter-specific keys.

- [ ] **Step 1: Add failing configuration tests**

In `test/configuration_test.rb`, extend the existing valid-fixture test with the omitted-key assertion:

```ruby
assert_nil instance.retention_ttl_minutes
```

Add tests for a configured value, every rejected type, and independent sibling
configuration. The sibling test deliberately uses retention shorter than cache
TTL: this regime is valid and must remain explicit rather than being rejected
as an accidental configuration.

```ruby
def test_loads_optional_retention_ttl_minutes_as_common_configuration
  source = File.read(FIXTURE).sub(
    "ttl_minutes = 30\n",
    "ttl_minutes = 30\nretention_ttl_minutes = 2880\n"
  )

  Tempfile.create(["cybort-config", ".toml"]) do |file|
    file.write(source)
    file.flush
    instance = Cybort::Configuration.load(file.path).instances.fetch("personal_rss")

    assert_equal 2880, instance.retention_ttl_minutes
    refute instance.options.key?(:retention_ttl_minutes)
  end
end

def test_rejects_invalid_retention_ttl_minutes
  invalid_values = ["0", "-1", "1.5", '"48h"', "true"]

  invalid_values.each do |value|
    source = File.read(FIXTURE).sub(
      "ttl_minutes = 30\n",
      "ttl_minutes = 30\nretention_ttl_minutes = #{value}\n"
    )

    Tempfile.create(["cybort-config", ".toml"]) do |file|
      file.write(source)
      file.flush

      error = assert_raises(Cybort::ConfigurationError) do
        Cybort::Configuration.load(file.path)
      end
      assert_includes error.message, "retention_ttl_minutes"
    end
  end
end

def test_retention_is_independent_per_instance_and_may_be_shorter_than_cache_ttl
  fixture = File.expand_path("fixtures/configuration/rss_and_github.toml", __dir__)
  source = File.read(fixture).sub(
    "[instances.rss]\n",
    "[instances.rss]\nretention_ttl_minutes = 5\n"
  )

  Tempfile.create(["cybort-config", ".toml"]) do |file|
    file.write(source)
    file.flush
    instances = Cybort::Configuration.load(file.path).instances

    assert_equal 5, instances.fetch("rss").retention_ttl_minutes
    assert_nil instances.fetch("github").retention_ttl_minutes
  end
end
```

- [ ] **Step 2: Run the focused test and confirm the new contract fails**

Run:

```bash
bundle exec ruby -Itest test/configuration_test.rb
```

Expected: FAIL because `Instance` does not expose `retention_ttl_minutes`; after only adding the reader, the configured-key test must still fail because the key remains in `options` and invalid values are accepted.

- [ ] **Step 3: Implement common-key parsing and validation**

In `lib/cybort/configuration.rb`, replace the instance struct and key constants with:

```ruby
Instance = Struct.new(
  :id,
  :name,
  :adapter,
  :ttl_minutes,
  :retention_ttl_minutes,
  :num_items_to_fetch,
  :options,
  keyword_init: true
)

REQUIRED_INSTANCE_KEYS = %i[name adapter ttl_minutes num_items_to_fetch].freeze
COMMON_INSTANCE_KEYS = (REQUIRED_INSTANCE_KEYS + %i[retention_ttl_minutes]).freeze
```

In `#build_instance`, read and validate the optional value after validating `ttl_minutes` and `num_items_to_fetch`:

```ruby
retention_ttl_minutes = raw[:retention_ttl_minutes]
unless retention_ttl_minutes.nil? ||
       (retention_ttl_minutes.is_a?(Integer) && retention_ttl_minutes.positive?)
  raise ConfigurationError,
        "instance #{id} retention_ttl_minutes must be a positive integer"
end
```

Do not compare retention to `ttl_minutes`. The two settings intentionally have
different roles and validation contracts: the former is a whole-minute
destructive boundary; the latter retains its backward-compatible positive
`Numeric` cache-freshness contract.

Then exclude every common key from adapter options and assign the new field:

```ruby
options = raw.reject { |key, _value| COMMON_INSTANCE_KEYS.include?(key) }
Instance.new(
  id: id,
  name: raw.fetch(:name).to_s,
  adapter: raw.fetch(:adapter).to_s,
  ttl_minutes: ttl_minutes,
  retention_ttl_minutes: retention_ttl_minutes,
  num_items_to_fetch: num_items_to_fetch,
  options: options
)
```

- [ ] **Step 4: Run the focused configuration tests**

Run:

```bash
bundle exec ruby -Itest test/configuration_test.rb
```

Expected: PASS with no failures or errors.

- [ ] **Step 5: Commit the configuration contract**

```bash
git add lib/cybort/configuration.rb test/configuration_test.rb
git commit -m "feat: add optional item retention configuration"
```

---

### Task 2: Prune Expired Items Atomically in Persistence

**Files:**
- Modify: `test/persistence_test.rb`
- Modify: `lib/cybort/persistence.rb`

**Interfaces:**
- Consumes: `Persistence#write_fetch_result(result, retention_ttl_minutes: Integer | nil)` and a successful, remote `FetchResult` selected by the orchestrator.
- Produces: atomic item upsert plus optional instance-scoped pruning using the earlier of `result.finished_at` and the injected persistence clock.
- Preserves: `Persistence#write_fetch_result(result)` retains all prior items when the keyword is omitted.

- [ ] **Step 1: Make persistence test timestamps configurable**

In `test/persistence_test.rb`, replace the `item` and `result` helpers with:

```ruby
def item(instance_id: "rss", canonical_id: "entry-1", title: "Article",
         fetched_at: Time.utc(2026, 8, 16, 12))
  Cybort::Item.new(
    instance_id: instance_id,
    canonical_id: canonical_id,
    urls: ["https://example.test/#{canonical_id}"],
    fetched_at: fetched_at,
    remote_created_at: Time.utc(2026, 8, 16, 11),
    title: title,
    body: "Body",
    priority: 50,
    action_item: false,
    info: { source: "test" }
  )
end

def result(instance_id: "rss", items: [item(instance_id: instance_id)],
           sync_state: { cursor: "next" },
           finished_at: Time.utc(2026, 8, 16, 12, 1))
  Cybort::FetchResult.success(
    instance_id: instance_id,
    items: items,
    sync_state: sync_state,
    started_at: finished_at - 60,
    finished_at: finished_at,
    metadata: { status: 200 },
    source_fetched: true
  )
end
```

This is test-only preparation and must leave the existing persistence tests passing.

- [ ] **Step 2: Add failing default, cutoff, isolation, and last-seen tests**

Add these tests to `PersistenceTest`:

```ruby
def test_omitted_retention_keeps_old_items
  with_database do |path|
    persistence = Cybort::Persistence.new(path)
    persistence.setup!
    persistence.register_instance(instance)
    persistence.write_fetch_result(
      result(items: [item(canonical_id: "old", fetched_at: Time.utc(2026, 8, 16, 10))])
    )

    persistence.write_fetch_result(
      result(items: [], finished_at: Time.utc(2026, 8, 16, 14))
    )

    assert_equal ["old"], persistence.items_for(instance_id: "rss").map(&:canonical_id)
  end
end

def test_retention_prunes_older_and_boundary_items_for_only_one_instance
  with_database do |path|
    now = Time.utc(2026, 8, 16, 13)
    persistence = Cybort::Persistence.new(path, clock: -> { now })
    persistence.setup!
    persistence.register_instance(instance("rss"))
    persistence.register_instance(instance("other"))
    persistence.write_fetch_result(
      result(
        items: [
          item(canonical_id: "older", fetched_at: Time.utc(2026, 8, 16, 11, 59, 59)),
          item(canonical_id: "boundary", fetched_at: Time.utc(2026, 8, 16, 12)),
          item(canonical_id: "newer", fetched_at: Time.utc(2026, 8, 16, 12, 0, 1))
        ]
      )
    )
    persistence.write_fetch_result(
      result(
        instance_id: "other",
        items: [item(instance_id: "other", canonical_id: "other-old", fetched_at: Time.utc(2026, 8, 16, 10))]
      )
    )

    persistence.write_fetch_result(
      result(items: [], finished_at: Time.utc(2026, 8, 16, 13)),
      retention_ttl_minutes: 60
    )

    assert_equal ["newer"], persistence.items_for(instance_id: "rss").map(&:canonical_id)
    assert_equal ["other-old"], persistence.items_for(instance_id: "other").map(&:canonical_id)
    refute_nil persistence.instance_record("rss")
    assert_equal({ cursor: "next" }, persistence.context_for(instance_id: "rss").fetch(:sync_state))
    assert_equal 2, persistence.fetch_runs_for(instance_id: "rss").length
    assert_equal 1, persistence.fetch_runs_for(instance_id: "other").length
  end
end

def test_returned_item_refreshes_last_seen_timestamp_before_pruning
  with_database do |path|
    persistence = Cybort::Persistence.new(path)
    persistence.setup!
    persistence.register_instance(instance)
    persistence.write_fetch_result(
      result(items: [item(canonical_id: "seen-again", fetched_at: Time.utc(2026, 8, 16, 10))])
    )

    persistence.write_fetch_result(
      result(
        items: [item(canonical_id: "seen-again", fetched_at: Time.utc(2026, 8, 16, 13))],
        finished_at: Time.utc(2026, 8, 16, 13, 1)
      ),
      retention_ttl_minutes: 60
    )

    stored = persistence.items_for(instance_id: "rss")
    assert_equal ["seen-again"], stored.map(&:canonical_id)
    assert_equal Time.utc(2026, 8, 16, 13), stored.first.fetched_at
  end
end

def test_retention_succeeds_when_the_instance_has_no_stored_items
  with_database do |path|
    now = Time.utc(2026, 8, 16, 13)
    persistence = Cybort::Persistence.new(path, clock: -> { now })
    persistence.setup!
    persistence.register_instance(instance)

    persistence.write_fetch_result(
      result(items: [], finished_at: now),
      retention_ttl_minutes: 60
    )

    assert_empty persistence.items_for(instance_id: "rss")
    assert_equal 1, persistence.fetch_runs_for(instance_id: "rss").length
  end
end

def test_future_result_timestamp_cannot_advance_cutoff_beyond_persistence_clock
  with_database do |path|
    now = Time.utc(2026, 8, 16, 13)
    persistence = Cybort::Persistence.new(path, clock: -> { now })
    persistence.setup!
    persistence.register_instance(instance)
    persistence.write_fetch_result(
      result(
        items: [
          item(canonical_id: "expired", fetched_at: Time.utc(2026, 8, 16, 11, 59, 59)),
          item(canonical_id: "safe", fetched_at: Time.utc(2026, 8, 16, 12, 0, 1))
        ]
      )
    )

    persistence.write_fetch_result(
      result(items: [], finished_at: Time.utc(2030, 1, 1)),
      retention_ttl_minutes: 60
    )

    assert_equal ["safe"], persistence.items_for(instance_id: "rss").map(&:canonical_id)
    assert_equal now, persistence.context_for(instance_id: "rss").fetch(:last_successful_fetch)
    assert_equal "2030-01-01T00:00:00.000000Z",
                 persistence.fetch_runs_for(instance_id: "rss").last.fetch("finished_at")
  end
end
```

The second test deliberately uses an empty successful result to prove that zero returned items still authorize pruning.

- [ ] **Step 3: Add a failing rollback-after-pruning test**

Use a scoped singleton-method override for the late transaction failure rather
than adding a test subclass coupled to persistence inheritance. The installed
Minitest 6.0.6 does not add `stub` to arbitrary objects, so restore the private
method in `ensure`. Return a new item in the attempted write to prove rollback
removes an upsert that occurred before the forced history failure:

```ruby
def test_failure_after_pruning_rolls_back_deletion_and_state_update
  with_database do |path|
    persistence = Cybort::Persistence.new(path)
    persistence.setup!
    persistence.register_instance(instance)
    persistence.write_fetch_result(
      result(
        items: [item(canonical_id: "old", fetched_at: Time.utc(2026, 8, 16, 10))],
        sync_state: { cursor: "old" }
      )
    )
    persistence.define_singleton_method(:insert_fetch_run) do |_result, _status|
      raise "fetch history unavailable"
    end
    begin
      assert_raises(RuntimeError) do
        persistence.write_fetch_result(
          result(
            items: [item(canonical_id: "new", fetched_at: Time.utc(2026, 8, 16, 13, 30))],
            sync_state: { cursor: "new" },
            finished_at: Time.utc(2026, 8, 16, 14)
          ),
          retention_ttl_minutes: 60
        )
      end
    ensure
      persistence.singleton_class.send(:remove_method, :insert_fetch_run)
    end

    assert_equal ["old"], persistence.items_for(instance_id: "rss").map(&:canonical_id)
    refute_includes persistence.items_for(instance_id: "rss").map(&:canonical_id), "new"
    assert_equal({ cursor: "old" }, persistence.context_for(instance_id: "rss").fetch(:sync_state))
    assert_equal 1, persistence.fetch_runs_for(instance_id: "rss").length
  end
end
```

- [ ] **Step 4: Run the persistence tests and confirm the keyword is unsupported**

Run:

```bash
bundle exec ruby -Itest test/persistence_test.rb
```

Expected: FAIL with `ArgumentError: unknown keyword: :retention_ttl_minutes` in the new retention tests. Existing tests and the omitted-retention test should continue to pass. The clock-skew test also locks down the safe deletion authority before the implementation is added.

- [ ] **Step 5: Implement transactional instance-scoped pruning**

Change `Persistence#write_fetch_result` in `lib/cybort/persistence.rb` to:

```ruby
def write_fetch_result(result, retention_ttl_minutes: nil)
  raise ValidationError, "cannot persist a failed fetch result" unless result.success?
  unless retention_ttl_minutes.nil? ||
         (retention_ttl_minutes.is_a?(Integer) && retention_ttl_minutes.positive?)
    raise ValidationError, "retention_ttl_minutes must be a positive integer"
  end

  persistence_now = @clock.call
  successful_fetch_at = [result.finished_at, persistence_now].min

  @database.transaction do
    result.items.each { |item| validate_item!(item, result.instance_id) }
    result.items.each { |item| upsert_item(item) }
    if retention_ttl_minutes
      cutoff = successful_fetch_at - (retention_ttl_minutes * 60)
      prune_expired_items(instance_id: result.instance_id, cutoff: cutoff)
    end
    update_instance_state(
      result,
      last_successful_fetch: successful_fetch_at,
      updated_at: persistence_now
    )
    insert_fetch_run(result, "successful")
  end
end
```

Add this private method immediately after `upsert_item`:

```ruby
def prune_expired_items(instance_id:, cutoff:)
  # Both values compared here pass through #timestamp, whose fixed-width UTC
  # ISO 8601 representation makes SQLite TEXT ordering chronological.
  @database.execute(
    "DELETE FROM items WHERE instance_id = ? AND fetched_at <= ?",
    [instance_id, timestamp(cutoff)]
  )
end
```

Validate the policy before any destructive statement and capture `@clock.call`
once per successful write. Use the same clamp for pruning and
`last_successful_fetch`, while leaving fetch history's completion time raw. Do not pass the whole
`FetchResult` into the destructive helper, add a schema column, add an adapter
callback, or expose a public standalone pruning method. A future-skewed adapter
time is clamped; a past-skewed time safely under-prunes.

- [ ] **Step 6: Run the focused persistence tests**

Run:

```bash
bundle exec ruby -Itest test/persistence_test.rb
```

Expected: PASS with no failures or errors, including direct invalid-policy,
exact-boundary, future-clock-skew freshness/history, durable-state,
empty-database, and rollback-of-a-new-upsert assertions.

- [ ] **Step 7: Commit the persistence behavior**

```bash
git add lib/cybort/persistence.rb test/persistence_test.rb
git commit -m "feat: prune expired items after successful fetches"
```

---

### Task 3: Propagate Retention Through Orchestration and Document It

**Files:**
- Modify: `test/orchestrator_test.rb`
- Modify: `test/system/cli_system_test.rb`
- Modify: `lib/cybort/orchestrator.rb`
- Modify: `README.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: `Configuration::Instance#retention_ttl_minutes` from Task 1 and `Persistence#write_fetch_result(result, retention_ttl_minutes:)` from Task 2.
- Produces: remote-success writes paired with the originating instance's retention duration.
- Preserves: `FetchResult`, adapter constructors, cache planning, dependency preflight, CLI JSON shape, and exit statuses.

- [ ] **Step 1: Extend the orchestrator persistence spy**

In `test/orchestrator_test.rb`, update `PersistenceSpy` to record retention arguments without changing existing `writes` assertions:

```ruby
class PersistenceSpy
  attr_reader :writes, :failures, :registered, :retention_writes

  def initialize
    @writes = []
    @failures = []
    @registered = []
    @retention_writes = []
  end

  def register_instance(instance)
    @registered << instance
  end

  def context_for(instance_id:)
    { items: [], last_successful_fetch: nil, sync_state: nil }
  end

  def write_fetch_result(result, retention_ttl_minutes: nil)
    @writes << result
    @retention_writes << [result.instance_id, retention_ttl_minutes]
  end

  def record_fetch_failure(result)
    @failures << result
  end
end
```

Change the test helper signature and add the new instance field:

```ruby
def instance(id, retention_ttl_minutes: nil)
  Cybort::Configuration::Instance.new(
    id: id,
    name: id.capitalize,
    adapter: "gate",
    ttl_minutes: 30,
    retention_ttl_minutes: retention_ttl_minutes,
    num_items_to_fetch: 5,
    options: {}
  )
end
```

- [ ] **Step 2: Add failing propagation and non-write assertions**

Add this remote-success test:

```ruby
def test_passes_each_instances_retention_to_persistence
  calls = []
  registry = Cybort::AdapterRegistry.new
  registry.register(
    "force",
    ->(**kwargs) { ForceRecordingAdapter.new(**kwargs, calls: calls) }
  )
  retained = instance("retained", retention_ttl_minutes: 120).tap do |value|
    value.adapter = "force"
  end
  forever = instance("forever").tap { |value| value.adapter = "force" }
  configuration = Struct.new(:instances).new(
    { "retained" => retained, "forever" => forever }
  )
  persistence = PersistenceSpy.new
  orchestrator = Cybort::Orchestrator.new(
    configuration: configuration,
    persistence: persistence,
    registry: registry,
    http_client: nil
  )

  orchestrator.run(force_fetch: true)

  assert_equal [
    ["retained", 120],
    ["forever", nil]
  ], persistence.retention_writes
end
```

In `test_fresh_cache_skips_dependency_preflight`, configure retention and add an assertion that cached results never invoke the write path:

```ruby
configured = instance("mail", retention_ttl_minutes: 60).tap do |value|
  value.adapter = "gmail"
end
```

```ruby
assert_empty persistence.retention_writes
```

The existing `test_stale_missing_dependency_fails_only_that_instance_and_groups_guidance` already proves dependency failures do not produce a write; retain its assertion that only the healthy source appears in `persistence.writes`.

Also add a mutating-adapter regression that changes the instance field after
validation and proves persistence receives the snapshot. Add success-result and
failure-result mismatch regressions with real `Persistence`; both must create a
failed run only for the configured ID and no rows, state, or history for the
adapter-supplied ID.

- [ ] **Step 3: Add CLI-system pruning and cache-hit tests**

In `test/system/cli_system_test.rb`, add a valid empty feed fixture constant beside `RSS_URL` and `GITHUB_URL`:

```ruby
EMPTY_RSS_BODY = <<~XML
  <?xml version="1.0"?>
  <rss version="2.0">
    <channel><title>Empty</title></channel>
  </rss>
XML
```

Add an end-to-end test that uses a successful empty second fetch:

```ruby
def test_successful_remote_fetch_prunes_expired_items_before_cli_output
  Dir.mktmpdir do |directory|
    root = File.join(directory, ".cybort")
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "cybort.toml"), <<~TOML)
      schema_version = 1

      [instances.rss]
      name = "RSS"
      adapter = "rss"
      ttl_minutes = 30
      retention_ttl_minutes = 60
      num_items_to_fetch = 5
      url = "#{RSS_URL}"
    TOML
    now = [Time.utc(2026, 9, 5, 10)]
    populated_client = FakeHttpClient.new(
      responses: { RSS_URL => rss_body }
    )
    empty_client = FakeHttpClient.new(
      responses: { RSS_URL => EMPTY_RSS_BODY }
    )

    first_status = Cybort::CLI.start(
      ["--force-fetch"],
      out: StringIO.new,
      err: StringIO.new,
      home: directory,
      http_client: populated_client,
      clock: -> { now.fetch(0) }
    )
    now[0] = Time.utc(2026, 9, 5, 12)
    output = StringIO.new
    second_status = Cybort::CLI.start(
      ["--force-fetch"],
      out: output,
      err: StringIO.new,
      home: directory,
      http_client: empty_client,
      clock: -> { now.fetch(0) }
    )

    payload = JSON.parse(output.string)
    assert_equal 0, first_status
    assert_equal 0, second_status
    assert_equal "success", payload.fetch("status")
    assert_empty payload.fetch("instances").first.fetch("items")

    persistence = Cybort::Persistence.new(File.join(root, "cybort.sqlite3"))
    assert_empty persistence.items_for(instance_id: "rss")
    assert_equal 2, persistence.fetch_runs_for(instance_id: "rss").length
  end
end
```

The persisted-item assertions are the evidence that pruning occurred;
`item_count` is deliberately not asserted because it reports the adapter
result's item count and would be zero for any empty feed, regardless of whether
retention ran.

Add a second end-to-end scenario proving that retention never turns a cache hit
into cleanup, even when the cached item is already older than the configured
duration:

```ruby
def test_cache_hit_preserves_items_older_than_retention_duration
  Dir.mktmpdir do |directory|
    root = File.join(directory, ".cybort")
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "cybort.toml"), <<~TOML)
      schema_version = 1

      [instances.rss]
      name = "RSS"
      adapter = "rss"
      ttl_minutes = 30
      retention_ttl_minutes = 5
      num_items_to_fetch = 5
      url = "#{RSS_URL}"
    TOML
    now = [Time.utc(2026, 9, 5, 10)]
    http_client = FakeHttpClient.new(responses: { RSS_URL => rss_body })

    first_status = Cybort::CLI.start(
      ["--force-fetch"],
      out: StringIO.new,
      err: StringIO.new,
      home: directory,
      http_client: http_client,
      clock: -> { now.fetch(0) }
    )
    now[0] = Time.utc(2026, 9, 5, 10, 10)
    output = StringIO.new
    second_status = Cybort::CLI.start(
      [],
      out: output,
      err: StringIO.new,
      home: directory,
      http_client: http_client,
      clock: -> { now.fetch(0) }
    )

    payload = JSON.parse(output.string)
    instance_payload = payload.fetch("instances").first
    assert_equal 0, first_status
    assert_equal 0, second_status
    assert_equal "cached", instance_payload.fetch("status")
    refute_empty instance_payload.fetch("items")

    persistence = Cybort::Persistence.new(File.join(root, "cybort.sqlite3"))
    refute_empty persistence.items_for(instance_id: "rss")
    assert_equal 1, persistence.fetch_runs_for(instance_id: "rss").length
  end
end
```

- [ ] **Step 4: Run the focused orchestration and system tests to verify they fail**

Run:

```bash
bundle exec ruby -Itest test/orchestrator_test.rb
bundle exec ruby -Itest test/system/cli_system_test.rb
```

Expected: FAIL because the orchestrator calls persistence without the instance's retention keyword, so the propagation assertion sees `nil` and the pruning system test retains the first fetch's items. The cache-hit system test may already pass; it is regression coverage for the non-pruning CLI path rather than evidence of the missing propagation.

- [ ] **Step 5: Snapshot retention, validate result identity, and pass policy to persistence**

In `lib/cybort/orchestrator.rb`, snapshot retention immediately after
configuration validation:

```ruby
@registry.validate_configuration!(instances)
retention_ttl_minutes_by_instance_id = instances.values.to_h do |instance|
  [instance.id, instance.retention_ttl_minutes]
end.freeze
```

Pass the snapshot through the status mapping:

```ruby
statuses = instances.values.map do |instance|
  persist_result(
    instance: instance,
    result: results.fetch(instance.id),
    retention_ttl_minutes: retention_ttl_minutes_by_instance_id.fetch(instance.id)
  )
end
```

Change the private persistence helper signature, validate identity before both
result branches, and use the configured ID in every status and rescue failure:

```ruby
def persist_result(instance:, result:, retention_ttl_minutes:)
  unless result.instance_id == instance.id
    raise ValidationError,
          "adapter result instance_id #{result.instance_id.inspect} does not match configured instance #{instance.id.inspect}"
  end

  if result.failure?
    failure = FetchResult.failure(
      instance_id: instance.id,
      error: result.error,
      started_at: result.started_at,
      finished_at: result.finished_at,
      metadata: result.metadata
    )
    @persistence.record_fetch_failure(failure)
    return InstanceRunStatus.new(instance_id: instance.id, status: :failure, source_fetched: false, item_count: 0, error: result.error, metadata: result.metadata)
  end

  if result.source_fetched
    @persistence.write_fetch_result(
      result,
      retention_ttl_minutes: retention_ttl_minutes
    )
  end
  status = result.source_fetched ? :success : :cached
  InstanceRunStatus.new(instance_id: instance.id, status: status, source_fetched: result.source_fetched, item_count: result.items.length, metadata: result.metadata)
rescue StandardError => error
  failure = FetchResult.failure(
    instance_id: instance.id,
    error: error,
    started_at: result.started_at,
    finished_at: @clock.call,
    metadata: error.respond_to?(:safe_metadata) ? error.safe_metadata : {}
  )
  @persistence.record_fetch_failure(failure)
  InstanceRunStatus.new(instance_id: instance.id, status: :failure, source_fetched: result.source_fetched, item_count: 0, error: error, metadata: failure.metadata)
end
```

Do not put retention on `FetchResult`, trust an adapter-supplied mismatched ID,
or call persistence for cached results.

- [ ] **Step 6: Run the focused orchestration and system tests**

Run:

```bash
bundle exec ruby -Itest test/orchestrator_test.rb
bundle exec ruby -Itest test/system/cli_system_test.rb
```

Expected: PASS with no failures or errors.

- [ ] **Step 7: Update user and agent documentation**

In `README.md`:

1. State that a configured instance may also define optional item retention.
2. Add `retention_ttl_minutes = 10080` to one example instance.
3. Replace the existing one-line fetch-limit note with:

```markdown
`ttl_minutes` controls how long cached data is considered fresh before Cybort
performs another remote fetch. `num_items_to_fetch` limits one source request.
Neither setting deletes stored items.

`retention_ttl_minutes` is optional and defaults to retaining items forever.
When configured, Cybort deletes items last seen at or before the retention
cutoff only after that instance completes a successful remote fetch. Cache hits
and failed fetches preserve the existing items, even when they are older than
the configured duration. It is valid for retention to be shorter than
`ttl_minutes`; in that case, a cache hit preserves the old items and the next
successful remote fetch may remove every item it does not return.
```

4. Add the retention design, ADR, and this implementation plan to **Design records**.

In `AGENTS.md`, update the stable invariants so they state:

```markdown
- A configured source instance may define `retention_ttl_minutes`. Omission
  means retain items forever. When configured, a successful remote fetch
  prunes items for that instance whose local `fetched_at` is at or before the
  retention cutoff in the same transaction as the result upsert. Persistence
  validates the policy independently and clamps the result completion time to
  one reading of its own clock for both that cutoff and durable cache
  freshness. Fetch history retains the raw completion timestamp. Cache hits and
  failed fetches do not prune.
- The orchestrator snapshots each validated instance's retention policy before
  adapter planning. It rejects mismatched adapter result IDs before persistence
  and records mismatch and rescue failures only under the configured ID.
```

Remove `retention policies` from the sentence that currently says scheduling,
retention, dashboards, and analysis/LLM workflows are not implemented or
architected. Keep scheduling, dashboards, and analysis/LLM workflows listed as
unimplemented.

Do not add a `docs/LEARNINGS.md` entry unless implementation reveals a new,
evidence-backed gotcha not already captured by the design or ADR.

- [ ] **Step 8: Run complete verification**

Run:

```bash
bundle exec rake test
git diff --check
test -f docs/adr/0003-configurable-item-retention.md
test -f docs/superpowers/specs/2026-09-05-configurable-item-retention-design.md
test -f docs/superpowers/plans/2026-09-05-configurable-item-retention.md
rg -n "retention_ttl_minutes" AGENTS.md README.md docs/adr/README.md docs/adr/0003-configurable-item-retention.md docs/superpowers/specs/2026-09-05-configurable-item-retention-design.md docs/superpowers/plans/2026-09-05-configurable-item-retention.md
```

Expected: all  tests pass with zero failures and errors; `git diff --check` and all `test -f` commands exit 0; every durable documentation layer references the exact unit-bearing key.

- [ ] **Step 9: Review the final diff for scope**

Run:

```bash
git status --short
git diff --stat
git diff -- .gitignore AGENTS.md docs/LEARNINGS.md docs/adr/0003-configurable-item-retention.md docs/superpowers/specs/2026-09-05-configurable-item-retention-design.md docs/superpowers/plans/2026-09-05-configurable-item-retention.md lib/cybort/persistence.rb lib/cybort/orchestrator.rb test/persistence_test.rb test/orchestrator_test.rb test/system/cli_system_test.rb
```

Expected: only the planned implementation, tests, documentation, and deliberate
`.gitignore` cleanup are changed. `.serena/` remains ignored and unstaged. There
is no change to `lib/cybort/schema.rb`, adapters, `FetchResult`, or
`docs/initial-spitballing.md`.

- [ ] **Step 10: Commit orchestration, system coverage, and documentation**

```bash
git add lib/cybort/orchestrator.rb test/orchestrator_test.rb test/system/cli_system_test.rb README.md AGENTS.md
git commit -m "feat: apply per-instance item retention"
```

---

## Completion Criteria

- Existing schema-version-1 configuration files load unchanged and retain items forever.
- A positive integer `retention_ttl_minutes` is exposed as common instance state and never leaks into adapter options; sibling instances remain independent and retention shorter than cache TTL is valid.
- Each validated retention policy is snapshotted before adapter planning, and adapter mutation cannot change the policy used by that run.
- Adapter result identity must match the configured instance before any success or failure persistence; mismatch and rescue failures are recorded under the configured ID only.
- Persistence independently rejects direct retention values other than `nil` or a positive `Integer` before changing stored data.
- A successful remote fetch atomically upserts current items and prunes expired items for only its own instance.
- The cutoff and durable `last_successful_fetch` use the earlier of result completion and one captured persistence clock, fetch history retains raw completion, the exact cutoff is expired, and refetched items use their refreshed local `fetched_at` timestamp.
- Pruning preserves the adapter-instance record, synchronization state, and fetch history, including when no item rows existed before the write.
- A successful empty result prunes, while cache hits and all failure paths preserve prior items.
- A later failure in the result transaction rolls back new upserts, pruning, and state changes.
- CLI output after a successful retained-source fetch reflects the post-pruning database contents without changing its JSON schema.
- README, `AGENTS.md`, ADR index, ADR 0003, design specification, and implementation plan agree on the retention semantics.
- The full offline test suite passes, documentation links resolve, and unrelated user files remain untouched.
