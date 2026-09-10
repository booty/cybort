require "test_helper"

class PersistenceTest < Minitest::Test
  INVALID_RETENTION_TTL_MINUTES = {
    zero: 0,
    negative: -1,
    float: 1.5,
    string: "60",
    boolean: true
  }.freeze

  def with_database
    Tempfile.create(["cybort", ".sqlite3"]) do |file|
      file.close
      yield file.path
    end
  end

  def instance(id = "rss")
    Cybort::Configuration::Instance.new(
      id: id,
      name: id.capitalize,
      adapter: "rss",
      ttl_minutes: 30,
      num_items_to_fetch: 10,
      options: { url: "https://example.test/#{id}.xml" }
    )
  end

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
             finished_at: Time.utc(2026, 8, 16, 12, 1),
             source_fetched: true, replace_existing_items: false)
    Cybort::FetchResult.success(
      instance_id: instance_id,
      items: items,
      sync_state: sync_state,
      started_at: finished_at - 60,
      finished_at: finished_at,
      metadata: { status: 200 },
      source_fetched: source_fetched,
      replace_existing_items: replace_existing_items
    )
  end

  def time_series_receipt(instance_id: "rss", import_key: "batch-1",
                          source_started_at: Time.utc(2026, 8, 16, 11, 59),
                          source_finished_at: Time.utc(2026, 8, 16, 12),
                          sync_state: { "cursor" => "next" },
                          imported_observation_count: 2)
    Cybort::TimeSeriesImportReceipt.new(
      instance_id: instance_id,
      import_key: import_key,
      artifact_digest: "a" * 64,
      import_mode: :append,
      source_started_at: source_started_at,
      source_finished_at: source_finished_at,
      committed_at: source_finished_at,
      imported_series_count: 1,
      imported_observation_count: imported_observation_count,
      stored_series_count: 1,
      stored_observation_count: imported_observation_count,
      sync_state: sync_state,
      metadata: { "fixture" => true }
    )
  end

  def test_setup_creates_schema_and_is_idempotent
    with_database do |path|
      persistence = Cybort::Persistence.new(path)

      persistence.setup!
      persistence.setup!

      assert_equal ["adapter_instances", "fetch_runs", "items", "schema_migrations",
                    "time_series_acknowledgements", "time_series_purge_intents"], persistence.table_names
      indexes = persistence.send(:query, "PRAGMA index_list('items')").map { |row| row.fetch("name") }
      assert_includes indexes, "idx_items_instance_fetched_at"
    end
  end

  def test_close_is_owner_safe_and_idempotent
    with_database do |path|
      persistence = Cybort::Persistence.new(path).setup!

      assert_nil persistence.close
      assert_nil persistence.close

      error = Thread.new { persistence.close rescue $! }.value
      assert_instance_of RuntimeError, error
    end
  end

  def test_setup_read_write_backup_and_purge_are_owner_safe
    with_database do |path|
      persistence = Cybort::Persistence.new(path).setup!
      persistence.register_instance(instance)
      persistence.write_fetch_result(result)
      operations = {
        setup: -> { persistence.setup! },
        read: -> { persistence.items_for(instance_id: "rss") },
        write: -> { persistence.register_instance(instance("other")) },
        backup: -> { persistence.backup_to(File.join(File.dirname(path), "wrong-thread.sqlite3")) },
        purge: -> { persistence.delete_instance(instance_id: "rss") }
      }

      operations.each do |name, operation|
        error = Thread.new { operation.call rescue $! }.value
        assert_instance_of RuntimeError, error, "#{name} must reject a non-owner thread"
      end

      assert_equal 1, persistence.instance_count
      assert_equal ["entry-1"], persistence.items_for(instance_id: "rss").map(&:canonical_id)
    end
  end

  def test_registering_instance_updates_display_name_without_duplicate
    with_database do |path|
      persistence = Cybort::Persistence.new(path)
      persistence.setup!

      persistence.register_instance(instance)
      persistence.register_instance(instance("rss").tap { |value| value.name = "Renamed RSS" })

      assert_equal "Renamed RSS", persistence.instance_record("rss").fetch("name")
      assert_equal 1, persistence.instance_count
    end
  end

  def test_planning_context_returns_ids_without_hydrating_items
    with_database do |path|
      persistence = Cybort::Persistence.new(path)
      persistence.setup!
      persistence.register_instance(instance)
      persistence.write_fetch_result(result)

      context = persistence.planning_context_for(instance_id: "rss")

      assert_empty context.fetch(:items)
      assert_equal ["entry-1"], context.fetch(:item_ids).to_a
      assert_equal({ cursor: "next" }, context.fetch(:sync_state))
    end
  end

  def test_hard_expiry_prunes_only_the_target_instance
    with_database do |path|
      now = Time.utc(2026, 8, 16, 13)
      persistence = Cybort::Persistence.new(path, clock: -> { now })
      persistence.setup!
      persistence.register_instance(instance("rss"))
      persistence.register_instance(instance("other"))
      persistence.write_fetch_result(result(items: [item(canonical_id: "old", fetched_at: now - 3_600)]))
      persistence.write_fetch_result(result(instance_id: "other", items: [item(instance_id: "other", fetched_at: now - 3_600)]))

      assert_equal 1, persistence.expire_items(instance_id: "rss", hard_expiry_ttl_minutes: 60)
      assert_empty persistence.items_for(instance_id: "rss")
      assert_equal ["entry-1"], persistence.items_for(instance_id: "other").map(&:canonical_id)
    end
  end

  def test_delete_instance_removes_items_state_and_fetch_history
    with_database do |path|
      persistence = Cybort::Persistence.new(path)
      persistence.setup!
      persistence.register_instance(instance)
      persistence.write_fetch_result(result)
      persistence.acknowledge_time_series_import(time_series_receipt)

      assert persistence.delete_instance(instance_id: "rss")
      refute persistence.delete_instance(instance_id: "rss")
      assert_nil persistence.instance_record("rss")
      assert_empty persistence.items_for(instance_id: "rss")
      assert_empty persistence.fetch_runs_for(instance_id: "rss")
      refute persistence.time_series_import_acknowledged?(instance_id: "rss", import_key: "batch-1")
    end
  end

  def test_acknowledge_time_series_import_advances_state_and_records_durable_history
    with_database do |path|
      now = Time.utc(2026, 8, 16, 13)
      persistence = Cybort::Persistence.new(path, clock: -> { now })
      persistence.setup!
      persistence.register_instance(instance)
      receipt = time_series_receipt(
        source_started_at: Time.utc(2026, 8, 16, 12, 59),
        source_finished_at: Time.utc(2026, 8, 16, 13),
        sync_state: { "cursor" => "batch-1" }, imported_observation_count: 2
      )

      assert persistence.acknowledge_time_series_import(receipt)
      assert persistence.time_series_import_acknowledged?(instance_id: "rss", import_key: "batch-1")
      assert_equal({ cursor: "batch-1" }, persistence.context_for(instance_id: "rss").fetch(:sync_state))
      assert_equal now, persistence.context_for(instance_id: "rss").fetch(:last_successful_fetch)

      run = persistence.fetch_runs_for(instance_id: "rss").first
      assert_equal "successful", run.fetch("status")
      assert_equal "2026-08-16T12:59:00.000000Z", run.fetch("started_at")
      assert_equal "2026-08-16T13:00:00.000000Z", run.fetch("finished_at")
      assert_equal 2, run.fetch("item_count")
      assert_equal "time_series", JSON.parse(run.fetch("metadata_json")).fetch("result_kind")

      refute persistence.acknowledge_time_series_import(receipt)
      assert_equal 1, persistence.fetch_runs_for(instance_id: "rss").length
    end
  end

  def test_acknowledgement_rolls_back_state_history_and_key_on_late_failure
    with_database do |path|
      persistence = Cybort::Persistence.new(path)
      persistence.setup!
      persistence.register_instance(instance)
      persistence.write_fetch_result(result(sync_state: { cursor: "old" }))

      with_persistence_failure(
        persistence, :insert_time_series_fetch_run,
        lambda do |_receipt, finished_at:|
          raise "fetch history unavailable"
        end
      ) do
        assert_raises(RuntimeError) do
          persistence.acknowledge_time_series_import(
            time_series_receipt(import_key: "failed", sync_state: { "cursor" => "new" })
          )
        end
      end

      assert_equal({ cursor: "old" }, persistence.context_for(instance_id: "rss").fetch(:sync_state))
      assert_equal ["entry-1"], persistence.items_for(instance_id: "rss").map(&:canonical_id)
      assert_equal 1, persistence.fetch_runs_for(instance_id: "rss").length
      refute persistence.time_series_import_acknowledged?(instance_id: "rss", import_key: "failed")
    end
  end

  def test_acknowledgement_uses_durable_source_start_after_reopening_persistence
    with_database do |path|
      receipt = time_series_receipt(
        source_started_at: Time.utc(2026, 8, 16, 11, 58),
        source_finished_at: Time.utc(2026, 8, 16, 12),
        sync_state: { "cursor" => "durable" }
      )
      first = Cybort::Persistence.new(path)
      first.setup!
      first.register_instance(instance)
      first.acknowledge_time_series_import(receipt)

      reopened = Cybort::Persistence.new(path)
      reopened.setup!

      assert_equal "2026-08-16T11:58:00.000000Z",
                   reopened.fetch_runs_for(instance_id: "rss").first.fetch("started_at")
      assert_equal({ cursor: "durable" }, reopened.context_for(instance_id: "rss").fetch(:sync_state))
    end
  end

  def test_acknowledgement_rejects_unknown_instance_without_writing_history
    with_database do |path|
      persistence = Cybort::Persistence.new(path)
      persistence.setup!
      receipt = time_series_receipt(instance_id: "missing")

      assert_raises(Cybort::ValidationError) { persistence.acknowledge_time_series_import(receipt) }
      refute persistence.time_series_import_acknowledged?(instance_id: "missing", import_key: "batch-1")
      assert_empty persistence.send(:query, "SELECT * FROM adapter_instances")
      assert_empty persistence.send(:query, "SELECT * FROM fetch_runs")
    end
  end

  def test_future_time_series_completion_is_clamped_in_state_and_fetch_history
    with_database do |path|
      now = Time.utc(2026, 8, 16, 13)
      persistence = Cybort::Persistence.new(path, clock: -> { now })
      persistence.setup!
      persistence.register_instance(instance)
      persistence.acknowledge_time_series_import(
        time_series_receipt(source_finished_at: Time.utc(2030, 1, 1))
      )

      assert_equal now, persistence.context_for(instance_id: "rss").fetch(:last_successful_fetch)
      assert_equal "2026-08-16T13:00:00.000000Z",
                   persistence.fetch_runs_for(instance_id: "rss").first.fetch("finished_at")
    end
  end

  def test_time_series_purge_intent_and_finish_are_idempotent_and_complete
    with_database do |path|
      persistence = Cybort::Persistence.new(path)
      persistence.setup!
      persistence.register_instance(instance)
      persistence.write_fetch_result(result)
      persistence.acknowledge_time_series_import(time_series_receipt)

      assert persistence.begin_time_series_purge(instance_id: "rss")
      refute persistence.begin_time_series_purge(instance_id: "rss")
      assert_equal ["rss"], persistence.pending_time_series_purges.map { |row| row.fetch("instance_id") }

      assert persistence.finish_time_series_purge(instance_id: "rss")
      refute persistence.finish_time_series_purge(instance_id: "rss")
      assert_empty persistence.pending_time_series_purges
      assert_nil persistence.instance_record("rss")
      assert_empty persistence.items_for(instance_id: "rss")
      assert_empty persistence.fetch_runs_for(instance_id: "rss")
      refute persistence.time_series_import_acknowledged?(instance_id: "rss", import_key: "batch-1")
    end
  end

  def test_time_series_purge_rolls_back_late_failure_and_survives_reopen
    with_database do |path|
      first = Cybort::Persistence.new(path)
      first.setup!
      first.register_instance(instance)
      first.write_fetch_result(result)
      first.acknowledge_time_series_import(time_series_receipt)
      assert first.begin_time_series_purge(instance_id: "rss")

      reopened = Cybort::Persistence.new(path)
      reopened.setup!
      assert_equal ["rss"], reopened.pending_time_series_purges.map { |row| row.fetch("instance_id") }

      database = reopened.instance_variable_get(:@database)
      database.execute(<<~SQL)
        CREATE TRIGGER fail_time_series_purge BEFORE DELETE ON adapter_instances
        BEGIN SELECT RAISE(ABORT, 'injected purge failure'); END
      SQL
      assert_raises(SQLite3::ConstraintException) do
        reopened.finish_time_series_purge(instance_id: "rss")
      end

      assert reopened.instance_record("rss")
      assert_equal ["entry-1"], reopened.items_for(instance_id: "rss").map(&:canonical_id)
      assert_equal 2, reopened.fetch_runs_for(instance_id: "rss").length
      assert reopened.time_series_import_acknowledged?(instance_id: "rss", import_key: "batch-1")
      assert_equal ["rss"], reopened.pending_time_series_purges.map { |row| row.fetch("instance_id") }

      database.execute("DROP TRIGGER fail_time_series_purge")
      assert reopened.finish_time_series_purge(instance_id: "rss")
      assert_nil reopened.instance_record("rss")
      assert_empty reopened.pending_time_series_purges
    end
  end

  def test_backup_to_writes_a_standalone_database
    with_database do |path|
      persistence = Cybort::Persistence.new(path)
      persistence.setup!
      persistence.register_instance(instance)
      persistence.write_fetch_result(result)
      backup = "#{path}.backup"

      assert_equal backup, persistence.backup_to(backup)
      backup_persistence = Cybort::Persistence.new(backup).setup!
      assert_equal ["entry-1"], backup_persistence.items_for(instance_id: "rss").map(&:canonical_id)
    end
  end

  def test_successful_result_upserts_items_and_records_fetch_history
    with_database do |path|
      persistence = Cybort::Persistence.new(path)
      persistence.setup!
      persistence.register_instance(instance)

      persistence.write_fetch_result(result)

      stored = persistence.items_for(instance_id: "rss")
      assert_equal ["entry-1"], stored.map(&:canonical_id)
      assert_equal "next", persistence.context_for(instance_id: "rss").fetch(:sync_state).fetch(:cursor)
      assert_equal ["successful"], persistence.fetch_runs_for(instance_id: "rss").map { |run| run.fetch("status") }
    end
  end

  def test_rejects_duplicate_item_identities_before_changing_persisted_data
    with_database do |path|
      persistence = Cybort::Persistence.new(path)
      persistence.setup!
      persistence.register_instance(instance)

      duplicate_items = [item(canonical_id: "same", title: "First"), item(canonical_id: "same", title: "Second")]
      error = assert_raises(Cybort::ValidationError) do
        persistence.write_fetch_result(result(items: duplicate_items))
      end

      assert_includes error.message, "duplicate item canonical_id: same"
      assert_empty persistence.items_for(instance_id: "rss")
      assert_empty persistence.fetch_runs_for(instance_id: "rss")
    end
  end

  def test_items_with_equal_timestamps_have_deterministic_identity_order
    with_database do |path|
      persistence = Cybort::Persistence.new(path)
      persistence.setup!
      persistence.register_instance(instance)
      persistence.write_fetch_result(
        result(items: [item(canonical_id: "z"), item(canonical_id: "a")])
      )

      assert_equal %w[a z], persistence.items_for(instance_id: "rss").map(&:canonical_id)
    end
  end

  def test_same_item_is_updated_and_same_id_can_exist_for_two_instances
    with_database do |path|
      persistence = Cybort::Persistence.new(path)
      persistence.setup!
      persistence.register_instance(instance("rss"))
      persistence.register_instance(instance("other"))

      persistence.write_fetch_result(result(items: [item(title: "Original")]))
      persistence.write_fetch_result(result(items: [item(title: "Updated")], sync_state: { cursor: "latest" }))
      persistence.write_fetch_result(result(instance_id: "other", items: [item(instance_id: "other")]))

      assert_equal "Updated", persistence.items_for(instance_id: "rss").first.title
      assert_equal 1, persistence.items_for(instance_id: "other").length
      assert_equal 2, persistence.items_for.length
    end
  end

  def test_replacement_removes_items_missing_from_the_complete_snapshot
    with_database do |path|
      persistence = Cybort::Persistence.new(path)
      persistence.setup!
      persistence.register_instance(instance)
      persistence.write_fetch_result(
        result(items: [item(canonical_id: "old-a"), item(canonical_id: "old-b")])
      )

      persistence.write_fetch_result(
        result(
          items: [item(canonical_id: "old-b", title: "Refreshed"), item(canonical_id: "new-c")],
          replace_existing_items: true
        )
      )

      assert_equal %w[new-c old-b], persistence.items_for(instance_id: "rss").map(&:canonical_id).sort
      assert_equal "Refreshed", persistence.items_for(instance_id: "rss").find { |value| value.canonical_id == "old-b" }.title
    end
  end

  def test_empty_replacement_clears_the_instance_items
    with_database do |path|
      persistence = Cybort::Persistence.new(path)
      persistence.setup!
      persistence.register_instance(instance)
      persistence.write_fetch_result(result)

      persistence.write_fetch_result(result(items: [], replace_existing_items: true))

      assert_empty persistence.items_for(instance_id: "rss")
    end
  end

  def test_default_false_success_keeps_items_missing_from_the_result
    with_database do |path|
      persistence = Cybort::Persistence.new(path)
      persistence.setup!
      persistence.register_instance(instance)
      persistence.write_fetch_result(result)

      persistence.write_fetch_result(result(items: [item(canonical_id: "new")]))

      assert_equal %w[entry-1 new], persistence.items_for(instance_id: "rss").map(&:canonical_id).sort
    end
  end

  def test_replacement_requires_a_remote_success
    with_database do |path|
      persistence = Cybort::Persistence.new(path)
      persistence.setup!
      persistence.register_instance(instance)

      cached = result(items: [], source_fetched: false, replace_existing_items: true)
      assert_raises(Cybort::ValidationError) { persistence.write_fetch_result(cached) }

      failure = Cybort::FetchResult.failure(
        instance_id: "rss",
        error: RuntimeError.new("unavailable"),
        started_at: Time.utc(2026, 8, 16, 12),
        finished_at: Time.utc(2026, 8, 16, 12, 1)
      )
      failure.replace_existing_items = true
      assert_raises(Cybort::ValidationError) { persistence.write_fetch_result(failure) }
    end
  end

  def test_replacement_and_retention_apply_in_the_same_write
    with_database do |path|
      now = Time.utc(2026, 8, 16, 13)
      persistence = Cybort::Persistence.new(path, clock: -> { now })
      persistence.setup!
      persistence.register_instance(instance)
      persistence.write_fetch_result(
        result(items: [item(canonical_id: "old", fetched_at: Time.utc(2026, 8, 16, 10))])
      )

      persistence.write_fetch_result(
        result(
          items: [item(canonical_id: "fresh", fetched_at: now)],
          finished_at: now,
          replace_existing_items: true
        ),
        retention_ttl_minutes: 60
      )

      assert_equal ["fresh"], persistence.items_for(instance_id: "rss").map(&:canonical_id)
    end
  end

  def test_persistence_rejects_mutated_replacement_flag_before_changing_data
    with_database do |path|
      persistence = Cybort::Persistence.new(path)
      persistence.setup!
      persistence.register_instance(instance)
      persistence.write_fetch_result(result(items: [item(canonical_id: "old")], sync_state: { cursor: "old" }))
      invalid = result(items: [item(canonical_id: "new")], sync_state: { cursor: "new" })
      invalid.replace_existing_items = "true"

      assert_raises(Cybort::ValidationError) { persistence.write_fetch_result(invalid) }
      assert_equal ["old"], persistence.items_for(instance_id: "rss").map(&:canonical_id)
      assert_equal({ cursor: "old" }, persistence.context_for(instance_id: "rss").fetch(:sync_state))
    end
  end

  def test_failure_records_error_without_changing_last_good_state
    with_database do |path|
      persistence = Cybort::Persistence.new(path)
      persistence.setup!
      persistence.register_instance(instance)
      persistence.write_fetch_result(result)

      failure = Cybort::FetchResult.failure(
        instance_id: "rss",
        error: RuntimeError.new("network unavailable"),
        started_at: Time.utc(2026, 8, 16, 13),
        finished_at: Time.utc(2026, 8, 16, 13, 1)
      )
      persistence.record_fetch_failure(failure)

      assert_equal ["entry-1"], persistence.items_for(instance_id: "rss").map(&:canonical_id)
      assert_equal({ cursor: "next" }, persistence.context_for(instance_id: "rss").fetch(:sync_state))
      assert_equal "failed", persistence.fetch_runs_for(instance_id: "rss").last.fetch("status")
      assert_includes persistence.fetch_runs_for(instance_id: "rss").last.fetch("error_message"), "network unavailable"
    end
  end

  def test_invalid_item_rolls_back_the_entire_result
    with_database do |path|
      persistence = Cybort::Persistence.new(path)
      persistence.setup!
      persistence.register_instance(instance)

      invalid_item = Struct.new(:instance_id, :canonical_id, :urls, :fetched_at,
                                 :remote_created_at, :title, :body, :priority,
                                 :action_item, :info).new(
        "rss", "bad", [], Time.utc(2026, 8, 16, 12), nil, nil, nil, nil, nil, {}
      )

      assert_raises(Cybort::ValidationError) do
        persistence.write_fetch_result(result(items: [item, invalid_item]))
      end

      assert_empty persistence.items_for(instance_id: "rss")
      assert_empty persistence.fetch_runs_for(instance_id: "rss")
      assert_nil persistence.context_for(instance_id: "rss").fetch(:sync_state)
    end
  end

  def test_empty_successful_result_updates_state_and_history
    with_database do |path|
      persistence = Cybort::Persistence.new(path)
      persistence.setup!
      persistence.register_instance(instance)

      persistence.write_fetch_result(result(items: [], sync_state: { cursor: "empty-page" }))

      assert_empty persistence.items_for(instance_id: "rss")
      assert_equal({ cursor: "empty-page" }, persistence.context_for(instance_id: "rss").fetch(:sync_state))
      assert_equal "successful", persistence.fetch_runs_for(instance_id: "rss").first.fetch("status")
    end
  end

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
      assert_equal "2030-01-01T00:00:00.000000Z", persistence.fetch_runs_for(instance_id: "rss").last.fetch("finished_at")
    end
  end

  INVALID_RETENTION_TTL_MINUTES.each do |description, invalid_value|
    define_method("test_rejects_#{description}_retention_before_changing_persisted_data") do
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

        assert_raises(Cybort::ValidationError) do
          persistence.write_fetch_result(
            result(
              items: [item(canonical_id: "new", fetched_at: Time.utc(2026, 8, 16, 13, 30))],
              sync_state: { cursor: "new" },
              finished_at: Time.utc(2026, 8, 16, 14)
            ),
            retention_ttl_minutes: invalid_value
          )
        end

        assert_equal ["old"], persistence.items_for(instance_id: "rss").map(&:canonical_id)
        assert_equal({ cursor: "old" }, persistence.context_for(instance_id: "rss").fetch(:sync_state))
        assert_equal 1, persistence.fetch_runs_for(instance_id: "rss").length
      end
    end
  end

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
      with_persistence_failure(
        persistence, :insert_fetch_run,
        ->(_result, _status) { raise "fetch history unavailable" }
      ) do
        assert_raises(RuntimeError) do
          persistence.write_fetch_result(
            result(
              items: [item(canonical_id: "new", fetched_at: Time.utc(2026, 8, 16, 13, 30))],
              sync_state: { cursor: "new" },
              finished_at: Time.utc(2026, 8, 16, 14),
              replace_existing_items: true
            ),
            retention_ttl_minutes: 60
          )
        end
      end

      assert_rolled_back_replacement(persistence)
    end
  end

  def test_upsert_failure_after_replacement_rolls_back_the_delete
    with_database do |path|
      persistence = Cybort::Persistence.new(path)
      persistence.setup!
      persistence.register_instance(instance)
      persistence.write_fetch_result(result(items: [item(canonical_id: "old")], sync_state: { cursor: "old" }))
      with_persistence_failure(
        persistence, :upsert_item,
        ->(_item) { raise "upsert unavailable" }
      ) do
        assert_raises(RuntimeError) do
          persistence.write_fetch_result(
            result(items: [item(canonical_id: "new")], sync_state: { cursor: "new" }, replace_existing_items: true)
          )
        end
      end

      assert_rolled_back_replacement(persistence)
    end
  end

  def test_state_update_failure_after_replacement_rolls_back_the_delete
    with_database do |path|
      persistence = Cybort::Persistence.new(path)
      persistence.setup!
      persistence.register_instance(instance)
      persistence.write_fetch_result(result(items: [item(canonical_id: "old")], sync_state: { cursor: "old" }))
      with_persistence_failure(
        persistence, :update_instance_state,
        lambda do |_result, last_successful_fetch:, updated_at:|
          raise "state unavailable"
        end
      ) do
        assert_raises(RuntimeError) do
          persistence.write_fetch_result(
            result(items: [item(canonical_id: "new")], sync_state: { cursor: "new" }, replace_existing_items: true)
          )
        end
      end

      assert_rolled_back_replacement(persistence)
    end
  end

  def test_failed_result_does_not_advance_existing_sync_state
    with_database do |path|
      persistence = Cybort::Persistence.new(path)
      persistence.setup!
      persistence.register_instance(instance)
      persistence.write_fetch_result(result(sync_state: { cursor: "old" }))

      invalid_item = Struct.new(:instance_id, :canonical_id, :urls, :fetched_at,
                                 :remote_created_at, :title, :body, :priority,
                                 :action_item, :info).new(
        "rss", "bad", [], Time.utc(2026, 8, 16, 13), nil, nil, nil, nil, {}
      )
      failed_write = result(items: [invalid_item], sync_state: { cursor: "new" })

      assert_raises(Cybort::ValidationError) { persistence.write_fetch_result(failed_write) }

      assert_equal({ cursor: "old" }, persistence.context_for(instance_id: "rss").fetch(:sync_state))
    end
  end

  private

  def with_persistence_failure(persistence, method_name, failure)
    persistence.singleton_class.define_method(method_name, &failure)
    yield
  ensure
    persistence.singleton_class.send(:remove_method, method_name)
  end

  def assert_rolled_back_replacement(persistence)
    assert_equal ["old"], persistence.items_for(instance_id: "rss").map(&:canonical_id)
    assert_equal({ cursor: "old" }, persistence.context_for(instance_id: "rss").fetch(:sync_state))
    assert_equal 1, persistence.fetch_runs_for(instance_id: "rss").length
  end
end
