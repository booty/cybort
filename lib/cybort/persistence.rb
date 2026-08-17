require "json"
require "sqlite3"
require "time"

module Cybort
  class Persistence
    def initialize(path, clock: -> { Time.now.utc })
      @database = SQLite3::Database.new(path.to_s)
      @database.busy_timeout(5_000)
      @clock = clock
    end

    def setup!
      @database.execute("PRAGMA foreign_keys = ON")
      @database.execute("PRAGMA journal_mode = WAL")
      @database.transaction { Schema.apply(@database) }
      self
    end

    def table_names
      query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").map { |row| row.fetch("name") }
    end

    def register_instance(instance)
      now = timestamp(@clock.call)
      @database.execute(
        <<~SQL,
          INSERT INTO adapter_instances (id, name, adapter, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            adapter = excluded.adapter,
            updated_at = excluded.updated_at
        SQL
        [instance.id, instance.name, instance.adapter, now, now]
      )
    end

    def instance_record(instance_id)
      query("SELECT * FROM adapter_instances WHERE id = ?", instance_id).first
    end

    def instance_count
      @database.get_first_value("SELECT COUNT(*) FROM adapter_instances")
    end

    def context_for(instance_id:)
      record = instance_record(instance_id)
      {
        items: items_for(instance_id: instance_id),
        last_successful_fetch: record && parse_time(record["last_successful_fetch"]),
        sync_state: record && parse_json(record["sync_state_json"])
      }
    end

    def items_for(instance_id: nil, limit: nil)
      sql = +"SELECT * FROM items"
      binds = []
      if instance_id
        sql << " WHERE instance_id = ?"
        binds << instance_id
      end
      sql << " ORDER BY COALESCE(remote_created_at, fetched_at) DESC"
      if limit
        sql << " LIMIT ?"
        binds << Integer(limit)
      end
      query(sql, *binds).map { |row| item_from_row(row) }
    end

    def fetch_runs_for(instance_id:)
      query("SELECT * FROM fetch_runs WHERE instance_id = ? ORDER BY id", instance_id)
    end

    def write_fetch_result(result)
      raise ValidationError, "cannot persist a failed fetch result" unless result.success?

      @database.transaction do
        result.items.each { |item| validate_item!(item, result.instance_id) }
        result.items.each { |item| upsert_item(item) }
        update_instance_state(result)
        insert_fetch_run(result, "successful")
      end
    end

    def record_fetch_failure(result)
      raise ValidationError, "cannot record a successful result as a failure" unless result.failure?

      @database.transaction { insert_fetch_run(result, "failed") }
    end

    private

    def upsert_item(item)
      @database.execute(
        <<~SQL,
          INSERT INTO items (
            instance_id, canonical_id, urls_json, fetched_at, remote_created_at,
            title, body, priority, action_item, info_json
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(instance_id, canonical_id) DO UPDATE SET
            urls_json = excluded.urls_json,
            fetched_at = excluded.fetched_at,
            remote_created_at = excluded.remote_created_at,
            title = excluded.title,
            body = excluded.body,
            priority = excluded.priority,
            action_item = excluded.action_item,
            info_json = excluded.info_json
        SQL
        [
          item.instance_id,
          item.canonical_id,
          JSON.generate(item.urls),
          timestamp(item.fetched_at),
          item.remote_created_at && timestamp(item.remote_created_at),
          item.title,
          item.body,
          item.priority,
          item.action_item.nil? ? nil : (item.action_item ? 1 : 0),
          JSON.generate(item.info)
        ]
      )
    end

    def update_instance_state(result)
      changes = @database.execute(
        <<~SQL,
          UPDATE adapter_instances
          SET last_successful_fetch = ?, sync_state_json = ?, updated_at = ?
          WHERE id = ?
        SQL
        [timestamp(result.finished_at),
         result.sync_state.nil? ? nil : JSON.generate(result.sync_state),
         timestamp(@clock.call),
         result.instance_id]
      )
      raise ValidationError, "unknown adapter instance: #{result.instance_id}" if changes == 0
    end

    def insert_fetch_run(result, status)
      @database.execute(
        <<~SQL,
          INSERT INTO fetch_runs (
            instance_id, status, started_at, finished_at, item_count,
            error_message, metadata_json
          ) VALUES (?, ?, ?, ?, ?, ?, ?)
        SQL
        [
          result.instance_id,
          status,
          timestamp(result.started_at),
          timestamp(result.finished_at),
          result.items.length,
          result.error && "#{result.error.class}: #{result.error.message}",
          JSON.generate(result.metadata || {})
        ]
      )
    end

    def validate_item!(item, instance_id)
      required = %i[instance_id canonical_id fetched_at title]
      missing = required.select { |field| !item.respond_to?(field) || item.public_send(field).nil? }
      raise ValidationError, "item missing required fields: #{missing.join(", ")}" unless missing.empty?
      raise ValidationError, "item belongs to the wrong adapter instance" unless item.instance_id == instance_id
    end

    def query(sql, *binds)
      columns, *rows = @database.execute2(sql, binds)
      rows.map { |row| columns.zip(row).to_h }
    end

    def item_from_row(row)
      Item.new(
        instance_id: row.fetch("instance_id"),
        canonical_id: row.fetch("canonical_id"),
        urls: parse_json(row.fetch("urls_json")) || [],
        fetched_at: parse_time(row.fetch("fetched_at")),
        remote_created_at: parse_time(row["remote_created_at"]),
        title: row.fetch("title"),
        body: row["body"],
        priority: row["priority"],
        action_item: row["action_item"].nil? ? nil : row["action_item"] == 1,
        info: parse_json(row.fetch("info_json")) || {}
      )
    end

    def parse_json(value)
      value && JSON.parse(value, symbolize_names: true)
    end

    def parse_time(value)
      value && Time.iso8601(value)
    end

    def timestamp(value)
      value.utc.iso8601(6)
    end
  end
end
