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

  def test_setup_creates_schema_and_is_idempotent
    with_database do |path|
      persistence = Cybort::Persistence.new(path)

      persistence.setup!
      persistence.setup!

      assert_equal ["adapter_instances", "fetch_runs", "items", "schema_migrations"], persistence.table_names
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
      persistence.define_singleton_method(:insert_fetch_run) do |_result, _status|
        raise "fetch history unavailable"
      end
      begin
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
      ensure
        persistence.singleton_class.send(:remove_method, :insert_fetch_run)
      end

      assert_equal ["old"], persistence.items_for(instance_id: "rss").map(&:canonical_id)
      refute_includes persistence.items_for(instance_id: "rss").map(&:canonical_id), "new"
      assert_equal({ cursor: "old" }, persistence.context_for(instance_id: "rss").fetch(:sync_state))
      assert_equal 1, persistence.fetch_runs_for(instance_id: "rss").length
    end
  end

  def test_upsert_failure_after_replacement_rolls_back_the_delete
    with_database do |path|
      persistence = Cybort::Persistence.new(path)
      persistence.setup!
      persistence.register_instance(instance)
      persistence.write_fetch_result(result(items: [item(canonical_id: "old")], sync_state: { cursor: "old" }))
      persistence.define_singleton_method(:upsert_item) { |_item| raise "upsert unavailable" }

      begin
        assert_raises(RuntimeError) do
          persistence.write_fetch_result(
            result(items: [item(canonical_id: "new")], sync_state: { cursor: "new" }, replace_existing_items: true)
          )
        end
      ensure
        persistence.singleton_class.send(:remove_method, :upsert_item)
      end

      assert_equal ["old"], persistence.items_for(instance_id: "rss").map(&:canonical_id)
      assert_equal({ cursor: "old" }, persistence.context_for(instance_id: "rss").fetch(:sync_state))
      assert_equal 1, persistence.fetch_runs_for(instance_id: "rss").length
    end
  end

  def test_state_update_failure_after_replacement_rolls_back_the_delete
    with_database do |path|
      persistence = Cybort::Persistence.new(path)
      persistence.setup!
      persistence.register_instance(instance)
      persistence.write_fetch_result(result(items: [item(canonical_id: "old")], sync_state: { cursor: "old" }))
      persistence.define_singleton_method(:update_instance_state) do |_result, last_successful_fetch:, updated_at:|
        raise "state unavailable"
      end

      begin
        assert_raises(RuntimeError) do
          persistence.write_fetch_result(
            result(items: [item(canonical_id: "new")], sync_state: { cursor: "new" }, replace_existing_items: true)
          )
        end
      ensure
        persistence.singleton_class.send(:remove_method, :update_instance_state)
      end

      assert_equal ["old"], persistence.items_for(instance_id: "rss").map(&:canonical_id)
      assert_equal({ cursor: "old" }, persistence.context_for(instance_id: "rss").fetch(:sync_state))
      assert_equal 1, persistence.fetch_runs_for(instance_id: "rss").length
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
end
