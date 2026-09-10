require "json"
require "fileutils"
require "set"
require "sqlite3"
require "time"

module Cybort
  class Persistence
    def initialize(path, clock: -> { Time.now.utc })
      @owner_thread = Thread.current
      @path = File.expand_path(path.to_s)
      @database = SQLite3::Database.new(@path)
      @database.busy_timeout(5_000)
      @clock = clock
    end

    def setup!
      ensure_owner!
      @database.execute("PRAGMA foreign_keys = ON")
      @database.execute("PRAGMA journal_mode = WAL")
      @database.transaction { Schema.apply(@database) }
      self
    end

    def close
      ensure_owner!
      @database.close unless @database.closed?
      nil
    end

    def table_names
      ensure_owner!
      query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").map { |row| row.fetch("name") }
    end

    def register_instance(instance)
      ensure_owner!
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
      ensure_owner!
      query("SELECT * FROM adapter_instances WHERE id = ?", instance_id).first
    end

    def instance_count
      ensure_owner!
      @database.get_first_value("SELECT COUNT(*) FROM adapter_instances")
    end

    def context_for(instance_id:)
      ensure_owner!
      record = instance_record(instance_id)
      items = items_for(instance_id: instance_id)
      {
        items: items,
        item_ids: items.map(&:canonical_id).to_set,
        last_successful_fetch: record && parse_time(record["last_successful_fetch"]),
        sync_state: record && parse_json(record["sync_state_json"])
      }
    end

    def planning_context_for(instance_id:)
      ensure_owner!
      record = instance_record(instance_id)
      {
        items: [],
        item_ids: canonical_ids_for(instance_id: instance_id),
        last_successful_fetch: record && parse_time(record["last_successful_fetch"]),
        sync_state: record && parse_json(record["sync_state_json"])
      }
    end

    def expire_items(instance_id:, hard_expiry_ttl_minutes:)
      ensure_owner!
      unless hard_expiry_ttl_minutes.is_a?(Integer) && hard_expiry_ttl_minutes.positive?
        raise ValidationError, "hard_expiry_ttl_minutes must be a positive integer"
      end

      cutoff = @clock.call - (hard_expiry_ttl_minutes * 60)
      @database.transaction do
        @database.execute(
          "DELETE FROM items WHERE instance_id = ? AND fetched_at <= ?",
          [instance_id, timestamp(cutoff)]
        )
        @database.changes
      end
    end

    def delete_instance(instance_id:)
      ensure_owner!
      @database.transaction do
        next false unless instance_record(instance_id)

        @database.execute("DELETE FROM fetch_runs WHERE instance_id = ?", [instance_id])
        @database.execute("DELETE FROM items WHERE instance_id = ?", [instance_id])
        # Keep this explicit even though the acknowledgement foreign key
        # cascades, so instance deletion documents and enforces its ordering.
        @database.execute("DELETE FROM time_series_acknowledgements WHERE instance_id = ?", [instance_id])
        @database.execute("DELETE FROM adapter_instances WHERE id = ?", [instance_id])
        true
      end
    end

    def backup_to(path)
      ensure_owner!
      destination = File.expand_path(path.to_s)
      raise ValidationError, "backup destination already exists" if File.exist?(destination)

      FileUtils.mkdir_p(File.dirname(destination))
      @database.execute("VACUUM INTO ?", [destination])
      destination
    end

    def items_for(instance_id: nil, limit: nil)
      ensure_owner!
      sql = +"SELECT * FROM items"
      binds = []
      if instance_id
        sql << " WHERE instance_id = ?"
        binds << instance_id
      end
      sql << " ORDER BY COALESCE(remote_created_at, fetched_at) DESC, instance_id ASC, canonical_id ASC"
      if limit
        sql << " LIMIT ?"
        binds << Integer(limit)
      end
      query(sql, *binds).map { |row| item_from_row(row) }
    end

    def fetch_runs_for(instance_id:)
      ensure_owner!
      query("SELECT * FROM fetch_runs WHERE instance_id = ? ORDER BY id", instance_id)
    end

    def acknowledge_time_series_import(receipt)
      ensure_owner!
      unless receipt.is_a?(TimeSeriesImportReceipt)
        raise ArgumentError, "expected a time-series import receipt"
      end

      persistence_now = @clock.call
      successful_fetch_at = [receipt.source_finished_at, persistence_now].min

      @database.transaction do
        acknowledged = @database.get_first_value(
          <<~SQL,
            SELECT 1 FROM time_series_acknowledgements
            WHERE instance_id = ? AND import_key = ?
          SQL
          [receipt.instance_id, receipt.import_key]
        )
        next false if acknowledged

        update_time_series_instance_state(
          receipt,
          last_successful_fetch: successful_fetch_at,
          updated_at: persistence_now
        )
        insert_time_series_fetch_run(receipt, finished_at: successful_fetch_at)
        @database.execute(
          <<~SQL,
            INSERT INTO time_series_acknowledgements (instance_id, import_key, acknowledged_at)
            VALUES (?, ?, ?)
          SQL
          [receipt.instance_id, receipt.import_key, timestamp(persistence_now)]
        )
        true
      end
    end

    def time_series_import_acknowledged?(instance_id:, import_key:)
      ensure_owner!
      !@database.get_first_value(
        <<~SQL,
          SELECT 1 FROM time_series_acknowledgements
          WHERE instance_id = ? AND import_key = ?
        SQL
        [instance_id, import_key]
      ).nil?
    end

    def begin_time_series_purge(instance_id:)
      ensure_owner!
      requested_at = timestamp(@clock.call)
      @database.transaction do
        @database.execute(
          <<~SQL,
            INSERT OR IGNORE INTO time_series_purge_intents (instance_id, requested_at)
            VALUES (?, ?)
          SQL
          [instance_id, requested_at]
        )
        @database.changes.positive?
      end
    end

    def pending_time_series_purges
      ensure_owner!
      query(<<~SQL)
        SELECT instance_id, requested_at
        FROM time_series_purge_intents
        ORDER BY instance_id ASC
      SQL
    end

    def finish_time_series_purge(instance_id:)
      ensure_owner!
      @database.transaction do
        deleted = false
        [
          "DELETE FROM fetch_runs WHERE instance_id = ?",
          "DELETE FROM items WHERE instance_id = ?",
          "DELETE FROM time_series_acknowledgements WHERE instance_id = ?",
          "DELETE FROM adapter_instances WHERE id = ?",
          "DELETE FROM time_series_purge_intents WHERE instance_id = ?"
        ].each do |sql|
          @database.execute(sql, [instance_id])
          deleted ||= @database.changes.positive?
        end
        deleted
      end
    end

    def write_fetch_result(result, retention_ttl_minutes: nil)
      ensure_owner!
      raise ValidationError, "cannot persist a failed fetch result" unless result.success?
      replacement = result.replace_existing_items
      unless replacement == true || replacement == false
        raise ValidationError, "replace_existing_items must be true or false"
      end
      if replacement && !result.source_fetched
        raise ValidationError, "replacement requires a remote fetch result"
      end
      unless retention_ttl_minutes.nil? ||
             (retention_ttl_minutes.is_a?(Integer) && retention_ttl_minutes.positive?)
        raise ValidationError, "retention_ttl_minutes must be a positive integer"
      end

      persistence_now = @clock.call
      successful_fetch_at = [result.finished_at, persistence_now].min
      pruned_count = 0

      @database.transaction do
        result.items.each { |item| validate_item!(item, result.instance_id) }
        duplicate_ids = result.items.group_by(&:canonical_id).select { |_id, items| items.length > 1 }.keys
        unless duplicate_ids.empty?
          raise ValidationError, "duplicate item canonical_id: #{duplicate_ids.sort.join(", ")}"
        end
        @database.execute(
          "DELETE FROM items WHERE instance_id = ?",
          [result.instance_id]
        ) if replacement
        result.items.each { |item| upsert_item(item) }
        if retention_ttl_minutes
          cutoff = successful_fetch_at - (retention_ttl_minutes * 60)
          pruned_count = prune_expired_items(instance_id: result.instance_id, cutoff: cutoff)
        end
        update_instance_state(
          result,
          last_successful_fetch: successful_fetch_at,
          updated_at: persistence_now
        )
        insert_fetch_run(result, "successful")
      end
      pruned_count
    end

    def record_fetch_failure(result)
      ensure_owner!
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

    def prune_expired_items(instance_id:, cutoff:)
      # Both values compared here pass through #timestamp, whose fixed-width UTC
      # ISO 8601 representation makes SQLite TEXT ordering chronological.
      @database.execute(
        "DELETE FROM items WHERE instance_id = ? AND fetched_at <= ?",
        [instance_id, timestamp(cutoff)]
      )
      @database.changes
    end

    def update_instance_state(result, last_successful_fetch:, updated_at:)
      changes = @database.execute(
        <<~SQL,
          UPDATE adapter_instances
          SET last_successful_fetch = ?, sync_state_json = ?, updated_at = ?
          WHERE id = ?
        SQL
        [timestamp(last_successful_fetch),
         result.sync_state.nil? ? nil : JSON.generate(result.sync_state),
         timestamp(updated_at),
         result.instance_id]
      )
      raise ValidationError, "unknown adapter instance: #{result.instance_id}" if changes == 0
    end

    def update_time_series_instance_state(receipt, last_successful_fetch:, updated_at:)
      unless @database.get_first_value(
               "SELECT 1 FROM adapter_instances WHERE id = ?", [receipt.instance_id]
             )
        raise ValidationError, "unknown adapter instance: #{receipt.instance_id}"
      end

      @database.execute(
        <<~SQL,
          UPDATE adapter_instances
          SET last_successful_fetch = ?, sync_state_json = ?, updated_at = ?
          WHERE id = ?
        SQL
        [timestamp(last_successful_fetch),
         receipt.sync_state.nil? ? nil : JSON.generate(receipt.sync_state),
         timestamp(updated_at),
         receipt.instance_id]
      )
    end

    def insert_time_series_fetch_run(receipt, finished_at:)
      metadata = receipt.metadata.merge("result_kind" => "time_series")
      @database.execute(
        <<~SQL,
          INSERT INTO fetch_runs (
            instance_id, status, started_at, finished_at, item_count,
            error_message, metadata_json
          ) VALUES (?, ?, ?, ?, ?, ?, ?)
        SQL
        [
          receipt.instance_id,
          "successful",
          timestamp(receipt.source_started_at),
          timestamp(finished_at),
          receipt.imported_observation_count,
          nil,
          JSON.generate(metadata)
        ]
      )
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

    def canonical_ids_for(instance_id:)
      query("SELECT canonical_id FROM items WHERE instance_id = ?", instance_id)
        .map { |row| row.fetch("canonical_id") }
        .to_set
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

    def ensure_owner!
      raise RuntimeError, "persistence must be used on its owner thread" unless Thread.current.equal?(@owner_thread)
    end
  end
end
