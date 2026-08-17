require "test_helper"

class PersistenceTest < Minitest::Test
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

  def item(instance_id: "rss", canonical_id: "entry-1", title: "Article")
    Cybort::Item.new(
      instance_id: instance_id,
      canonical_id: canonical_id,
      urls: ["https://example.test/#{canonical_id}"],
      fetched_at: Time.utc(2026, 8, 16, 12),
      remote_created_at: Time.utc(2026, 8, 16, 11),
      title: title,
      body: "Body",
      priority: 50,
      action_item: false,
      info: { source: "test" }
    )
  end

  def result(instance_id: "rss", items: [item(instance_id: instance_id)], sync_state: { cursor: "next" })
    Cybort::FetchResult.success(
      instance_id: instance_id,
      items: items,
      sync_state: sync_state,
      started_at: Time.utc(2026, 8, 16, 12),
      finished_at: Time.utc(2026, 8, 16, 12, 1),
      metadata: { status: 200 },
      source_fetched: true
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
end

