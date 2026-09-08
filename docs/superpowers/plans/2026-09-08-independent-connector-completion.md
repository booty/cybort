# Independent Connector Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist and report each connector result as soon as that connector finishes, without introducing concurrent SQLite writers.

**Architecture:** Adapter workers publish terminal events to a thread-safe completion queue. The orchestrator's calling thread obtains each completed worker's value and persists results sequentially, then restores configuration order when constructing the final `RunResult`. Worker publication occurs in `ensure`, and launch/consumption cleanup observes every started worker without masking the primary error.

**Tech Stack:** Ruby 4.0, core `Thread`/`Queue`, SQLite through the existing `Persistence` service, Minitest.

**Spec:** [Independent connector completion design](../specs/2026-09-08-independent-connector-completion-design.md)

**Status:** Implemented and offline-verified on 2026-09-08. After the final
independent review and its follow-ups, the full suite completed with 390 runs,
2,150 assertions, 0 failures, and 0 errors.

## Global Constraints

- Change no adapter public interface and no persistence public interface.
- Make no SQLite schema or configuration changes.
- Keep one fetch thread per eligible configured instance.
- Keep every persistence operation on the orchestrator caller thread, one instance transaction at a time.
- Publish one terminal event from `ensure` for every successfully started worker.
- Preserve abnormal worker exceptions through `Thread#value`; convert only ordinary adapter `StandardError` failures through the existing source-failure path.
- Persist dependency-preflight failures through the same completion-consumption path.
- Emit each completion diagnostic only after that instance's persistence call completes.
- Preserve `RunResult.instances` configuration order regardless of completion order.
- Do not assert exact human-facing diagnostic prose.
- Bound every test synchronization wait and clean up gated test threads in `ensure`.
- Delegate every test command to a read-only `gpt-5.6-luna` agent at medium reasoning effort.

---

## File map

| File | Responsibility/change |
|---|---|
| `lib/cybort/orchestrator.rb` | Replace the wait-for-all result barrier with terminal-event, completion-ordered persistence |
| `test/orchestrator_test.rb` | Prove early serialized commits, stable final ordering, preflight independence, abnormal-worker propagation, and cleanup |
| `docs/adr/0008-independent-connector-completion.md` | Record the replacement architecture decision while retaining serialized orchestrator-owned persistence |
| `docs/adr/0001-persistence-storage-and-write-ownership.md` | Mark the old execution policy superseded while preserving its historical body |
| `docs/adr/README.md` | Mark ADR 0001 superseded and index ADR 0008 |
| `docs/superpowers/specs/2026-08-16-cybort-core-design.md` | Add a supersession notice for the old global-barrier policy |
| `AGENTS.md` | Replace the wait-for-all invariant with completion-ordered, serialized persistence |
| `README.md` | Describe completion-ordered commits and point to the current persistence ADR |

No adapter, persistence, schema, configuration, or connector-specific test file changes.

---

### Task 1: Specify completion ordering and bounded failure behavior

**Files:**
- Modify: `test/orchestrator_test.rb`

**Interfaces:**
- Consumes: `GateAdapter`, `PersistenceSpy`, `CheckerSpy`, and existing orchestrator dependency fixtures.
- Produces: bounded behavioral regressions for completion order, caller-thread persistence, preflight results, terminal worker events, and cleanup.

- [x] **Step 1: Add bounded synchronization and signaling test helpers.**

  Add `require "timeout"` after `require "test_helper"`, then add these helpers near the existing spies:

  ```ruby
  WAIT_SECONDS = 2

  class ProgressSpy
    attr_reader :events

    def initialize
      @events = Queue.new
    end

    def puts(message)
      @events << message
    end
  end

  class SignalingPersistenceSpy < PersistenceSpy
    attr_reader :events

    def initialize
      super
      @events = Queue.new
    end

    def write_fetch_result(result, retention_ttl_minutes: nil)
      pruned_count = super
      @events << [:successful, result.instance_id, Thread.current]
      pruned_count
    end

    def record_fetch_failure(result)
      super
      @events << [:failed, result.instance_id, Thread.current]
      nil
    end
  end

  class BrokenSafeMetadataError < StandardError
    def safe_metadata
      raise "safe metadata failed"
    end
  end

  class RaisingAdapter
    def initialize(error:, **)
      @error = error
    end

    def fetch(force_fetch: false, fetch_mode: nil, planned_at: nil)
      raise @error
    end
  end

  class ThreadReportingGateAdapter < GateAdapter
    def initialize(worker_threads:, **kwargs)
      super(**kwargs)
      @worker_threads = worker_threads
    end

    def fetch(**options)
      @worker_threads << [@instance.id, Thread.current]
      super
    end
  end

  class GatedRaisingAdapter
    def initialize(instance:, started:, release:, worker_threads:, error:, **)
      @instance = instance
      @started = started
      @release = release
      @worker_threads = worker_threads
      @error = error
    end

    def fetch(force_fetch: false, fetch_mode: nil, planned_at: nil)
      @started << @instance.id
      @worker_threads << [@instance.id, Thread.current]
      @release.pop
      raise @error
    end
  end
  ```

  Change `PersistenceSpy#write_fetch_result` to return `0` after recording its
  arrays so the spy matches the production persistence contract. Add private
  test helpers:

  ```ruby
  def await(queue)
    Timeout.timeout(WAIT_SECONDS) { queue.pop }
  end

  def await_value(thread)
    Timeout.timeout(WAIT_SECONDS) { thread.value }
  end

  def release_and_stop(run_thread, releases)
    releases&.each_value { |release| release << true }
    return unless run_thread

    begin
      run_thread.join(WAIT_SECONDS)
    rescue Exception # rubocop:disable Lint/RescueException -- expected failures are asserted before cleanup
      nil
    end
    return unless run_thread.alive?

    run_thread.kill
    begin
      run_thread.join(WAIT_SECONDS)
    rescue Exception # rubocop:disable Lint/RescueException -- cleanup must not mask the test assertion
      nil
    end
  end
  ```

- [x] **Step 2: Replace the barrier test with an early-commit regression.**

  Replace `test_fetches_adapter_instances_concurrently_then_persists_sequentially`
  with a test that constructs two `GateAdapter` instances using per-instance
  queues:

  ```ruby
  releases = { "one" => Queue.new, "two" => Queue.new }
  registry.register("gate", lambda { |**kwargs|
    GateAdapter.new(
      **kwargs,
      started: started,
      release: releases.fetch(kwargs.fetch(:instance).id)
    )
  })
  ```

  Run the orchestrator in `run_thread` with `SignalingPersistenceSpy` and
  `ProgressSpy`. Use `await(started)` twice to prove both workers started, then
  `await(progress.events)` twice to consume their start events without
  inspecting message text. Release only `two` and assert:

  ```ruby
  assert_equal [:successful, "two", run_thread], await(persistence.events)
  await(progress.events) # completion event; exact prose is intentionally ignored
  assert_equal ["two"], persistence.writes.map(&:instance_id)
  assert run_thread.alive?
  ```

  Release `one`, await its persistence and progress events, obtain the bounded
  `RunResult`, and assert:

  ```ruby
  assert_equal %w[one two], result.instances.map(&:instance_id)
  assert_equal %w[two one], persistence.writes.map(&:instance_id)
  assert_empty persistence.failures
  ```

  Always call `release_and_stop(run_thread, releases)` from `ensure`.

- [x] **Step 3: Add a preflight-failure independence regression.**

  Reuse `unavailable_resolution` and a synthetic dependency for instance
  `blocked`; configure a second `gate` instance whose adapter remains gated.
  Start the run, await the gate worker's start, and require this event before
  releasing the gate:

  ```ruby
  assert_equal [:failed, "blocked", run_thread], await(persistence.events)
  assert run_thread.alive?
  ```

  Then release the gate, obtain the bounded result, and assert statuses remain
  in configuration order with `blocked` failed and `gate` successful. Do not
  assert the diagnostic sentence.

- [x] **Step 4: Add an abnormal worker-conversion regression.**

  Register `RaisingAdapter` with `BrokenSafeMetadataError.new("adapter failed")`.
  Assert that `await_value(run_thread)` raises `RuntimeError` with message
  `safe metadata failed`, rather than timing out. This proves terminal
  publication happens even when the ordinary source-failure conversion itself
  raises. Clean up with `release_and_stop(run_thread, {})`.

- [x] **Step 5: Add escaped-persistence cleanup and error-precedence coverage.**

  Add a test spy whose `write_fetch_result` records an attempt then raises
  `"write failed"`, and whose `record_fetch_failure` raises
  `"failure history failed"`. Use `ThreadReportingGateAdapter` for instance
  `two`, and `GatedRaisingAdapter` with
  `BrokenSafeMetadataError.new("secondary worker failed")` for instance `one`;
  its failing `safe_metadata` conversion makes the worker itself terminate
  abnormally during cleanup. Capture both worker objects from
  `worker_threads` before releasing either gate.

  Release `two`, await its write attempt, and verify the run remains alive while
  cleanup waits for `one`. Release `one`, then require bounded `thread.value` to
  raise `failure history failed`, not `safe metadata failed`. After the
  caller returns, assert both captured worker threads are no longer alive. The
  test's `ensure` must call the bounded, non-raising `release_and_stop` helper.
  This proves cleanup observes a second failed worker, continues through every
  started worker, and preserves the original persistence exception.

- [x] **Step 6: Remove the obsolete persistence-order assumption.**

  In `test_passes_each_instances_retention_to_persistence`, replace the ordered
  array assertion with:

  ```ruby
  assert_equal({ "retained" => 120, "forever" => nil },
               persistence.retention_writes.to_h)
  ```

- [x] **Step 7: Delegate the focused red tests.**

  Run:

  ```sh
  bundle exec ruby -Itest test/orchestrator_test.rb
  ```

  Expected: the early-commit, preflight-independence, and cleanup-precedence
  tests time out or fail their event expectations under the current global
  barrier. The abnormal worker-conversion test is a preservation regression and
  may already pass because the current `Thread#value` path propagates that
  error. All `ensure` cleanup must let the process exit.

---

### Task 2: Implement terminal-event, completion-ordered persistence

**Files:**
- Modify: `lib/cybort/orchestrator.rb`

**Interfaces:**
- Consumes: one preflight `FetchResult` or one completed worker `Thread` per configured instance.
- Produces: sequential `persist_result` calls in completion order and configuration-ordered final statuses.

- [x] **Step 1: Seed preflight results and protect launch plus consumption.**

  Replace the existing thread launch, `thread.value` barrier, and persistence
  loop in `Orchestrator#run`. Use event shapes
  `[:result, instance_id, FetchResult]` for preflight failures and
  `[:thread, instance_id, Thread]` for workers:

  ```ruby
  completions = Queue.new
  results.each do |instance_id, result|
    completions << [:result, instance_id, result]
  end

  threads = {}
  statuses_by_instance_id = {}
  cleanup_error = nil
  begin
    plans.each do |instance_id, entry|
      next if results.key?(instance_id)

      plan = entry.fetch(:plan)
      adapter = entry.fetch(:adapter)
      progress_puts(fetch_start_message(plan)) if @progress && plan.fetch_mode == :remote
      threads[instance_id] = start_worker do
        Thread.current.report_on_exception = false
        begin
          adapter.fetch(
            force_fetch: force_fetch,
            fetch_mode: plan.fetch_mode,
            planned_at: plan.planned_at
          )
        rescue StandardError => error
          FetchResult.failure(
            instance_id: instance_id,
            error: error,
            started_at: @clock.call,
            finished_at: @clock.call,
            metadata: error.respond_to?(:safe_metadata) ? error.safe_metadata : {}
          )
        ensure
          completions << [:thread, instance_id, Thread.current]
        end
      end
    end

    instances.length.times do
      kind, instance_id, payload = completions.pop
      result = kind == :thread ? payload.value : payload
      instance = instances.fetch(instance_id)
      statuses_by_instance_id[instance_id] = persist_result(
        instance: instance,
        result: result,
        retention_ttl_minutes: retention_ttl_minutes_by_instance_id.fetch(instance_id),
        context: contexts.fetch(instance_id),
        hard_expired_items: hard_expired_items_by_instance_id.fetch(instance_id)
      )
    end
  ensure
    active_error = $!
    threads.each_value do |thread|
      begin
        thread.join
      rescue Exception => error # rubocop:disable Lint/RescueException -- observe every worker before propagating
        cleanup_error ||= error
      end
    end
    raise cleanup_error if active_error.nil? && cleanup_error
  end

  statuses = instances.values.map do |instance|
    statuses_by_instance_id.fetch(instance.id)
  end
  ```

  Add this private seam so launch failure can be tested without changing the
  public initializer:

  ```ruby
  def start_worker(&block)
    Thread.new(&block)
  end
  ```

  Keep the existing configuration contract that the instances hash is keyed by
  `instance.id`; do not add speculative alternate-key normalization. Retain
  configured-result identity validation inside `persist_result`.

- [x] **Step 2: Delegate focused green verification.**

  Run `bundle exec ruby -Itest test/orchestrator_test.rb`. Expected: every
  bounded concurrency/failure test and all existing orchestrator tests pass.

- [x] **Step 3: Delegate full implementation verification.**

  Run:

  ```sh
  bundle exec rake test
  RUBOCOP_CACHE_ROOT=/private/tmp/cybort-rubocop-cache bundle exec rake quality
  ```

  Expected: both commands pass. Report existing warnings separately from test
  failures. Do not proceed to documentation if either command fails.

---

### Task 3: Record the replacement architecture decision

**Files:**
- Create: `docs/adr/0008-independent-connector-completion.md`
- Modify: `docs/adr/0001-persistence-storage-and-write-ownership.md`
- Modify: `docs/adr/README.md`
- Modify: `docs/superpowers/specs/2026-08-16-cybort-core-design.md`
- Modify: `AGENTS.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: the implemented and verified queue behavior from Task 2.
- Produces: authoritative documentation distinguishing concurrent fetches, completion-ordered commits, serialized SQLite writes, and configuration-ordered final results.

- [x] **Step 1: Create ADR 0008.**

  Record status `Accepted` and date `2026-09-08`. State explicitly that one
  SQLite database remains canonical; adapters have no persistence access;
  workers publish terminal completion events; the orchestrator caller persists
  results sequentially as they complete; each result retains its own
  transaction and failure isolation; final results retain configuration order;
  and ADR 0008 supersedes ADR 0001 while retaining its datastore, ownership,
  and single-writer decisions. Include the alternatives and consequences from
  the design spec. Link the design and this implementation plan.

- [x] **Step 2: Supersede ADR 0001 in both authoritative locations.**

  Change ADR 0001's own status line to:

  ```markdown
  - Status: Superseded by [ADR 0008](0008-independent-connector-completion.md) on 2026-09-08
  ```

  Add a short note that its historical body is retained and ADR 0008 keeps the
  database/ownership decisions while replacing the global result barrier. In
  `docs/adr/README.md`, retain the ADR 0001 row with status `Superseded` and a
  replacement link, then add ADR 0008 as `Accepted` with decision text
  “Completion-ordered, orchestrator-owned sequential persistence.”

- [x] **Step 3: Update current architecture documentation.**

  In `AGENTS.md`, replace the invariant saying the orchestrator waits for every
  thread before persistence with one saying workers publish terminal events and
  the orchestrator caller persists each completion sequentially. Preserve the
  configured-instance identity and per-result transaction rules.

  In README's Architecture section, state that remote fetches overlap, faster
  connectors commit and report completion without waiting for slower ones,
  SQLite writes remain sequential, and final run aggregation waits for every
  configured instance. Replace the “Persistence ADR” design-record link with
  ADR 0008 and retain ADR 0001 only through ADR 0008's historical link.

  In `docs/superpowers/specs/2026-08-16-cybort-core-design.md`, add a prominent
  notice after the status/date saying the original wait-for-all execution
  policy is superseded by ADR 0008 and the 2026-09-08 design. Preserve the
  original body as historical context.

- [x] **Step 4: Validate documentation and repository consistency.**

  Run these read-only checks directly; do not rerun the project suite for the
  documentation-only edits after Task 2 is green:

  ```sh
  rg -n "waits for every adapter thread|wait for all adapter|completion queue|terminal event|sequential" AGENTS.md README.md docs/adr docs/superpowers/specs/2026-08-16-cybort-core-design.md docs/superpowers/specs/2026-09-08-independent-connector-completion-design.md
  rg -n "0001|0008" README.md docs/adr/README.md docs/adr/0001-persistence-storage-and-write-ownership.md docs/adr/0008-independent-connector-completion.md
  git diff --check
  ```

  Expected: current-authority text describes completion-ordered persistence;
  historical barrier text remains only beneath explicit supersession notices;
  ADR links resolve; `git diff --check` emits nothing.

- [x] **Step 5: Commit and push the implementation and records together.**

  ```sh
  git add lib/cybort/orchestrator.rb test/orchestrator_test.rb \
    AGENTS.md README.md docs/adr/README.md \
    docs/adr/0001-persistence-storage-and-write-ownership.md \
    docs/adr/0008-independent-connector-completion.md \
    docs/superpowers/specs/2026-08-16-cybort-core-design.md
  git commit -m "Persist connectors as they complete"
  git push origin main
  ```

---

### Task 4: Apply final Sol review feedback

**Files:**
- Modify: `lib/cybort/orchestrator.rb`
- Modify: `test/orchestrator_test.rb`
- Modify: `AGENTS.md`

- [x] **Step 1: Add a red regression for launch-error precedence.**

  Override the private `start_worker` seam in a test subclass so the second
  launch raises `WorkerLaunchError`. Gate the first worker, make its
  `safe_metadata` conversion fail during cleanup, and assert with bounded waits
  that the launch error remains primary and the first worker terminates.

- [x] **Step 2: Suppress duplicate automatic thread reports.**

  Set `Thread.current.report_on_exception = false` as the first worker-block
  statement. Continue observing results through `Thread#value` and every
  started worker through cleanup joins. Suppress reports on test-owned run
  threads with a `start_run` helper; continue asserting their exceptions via
  `Thread#value`.

- [x] **Step 3: Correct the durable worker-count invariant.**

  Change `AGENTS.md` from one worker per configured instance to one worker per
  eligible configured instance because dependency-preflight failures do not
  start workers.

- [x] **Step 4: Delegate final verification.**

  The focused orchestrator suite completed with 19 runs and 79 assertions. The
  full suite completed with 390 runs and 2,150 assertions. Both had zero
  failures, errors, or skips, and no thread exception traces. The quality task
  inspected five files with no offenses.

## Plan self-review

- Spec coverage: completion order, caller-thread serialization, final ordering,
  preflight results, failure conversion, launch/worker cleanup, diagnostic
  timing, and documentation supersession each have an implementation or
  verification step.
- Queue cardinality: every started worker publishes a terminal event from
  `ensure`; every preflight failure seeds one materialized-result event; launch
  failure exits into cleanup instead of entering a fixed-count consumer loop.
- Exception semantics: ordinary adapter failures retain the current conversion;
  `Thread#value` re-raises abnormal worker termination; cleanup observes all
  workers and does not mask an active exception.
- Scope: production changes remain confined to `orchestrator.rb`; behavioral
  code tests remain confined to `orchestrator_test.rb`; remaining files update
  architectural authority only.
- Type consistency: queue events are always `[kind, instance_id, payload]`, with
  `payload` a `FetchResult` for `:result` or completed `Thread` for `:thread`.
- Placeholder scan: no TBD, TODO, deferred implementation instruction, or
  undefined production helper remains.
