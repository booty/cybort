module Cybort
  module Schema
    VERSION = 1

    DDL = <<~SQL
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version INTEGER PRIMARY KEY
      );

      CREATE TABLE IF NOT EXISTS adapter_instances (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        adapter TEXT NOT NULL,
        last_successful_fetch TEXT,
        sync_state_json TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS items (
        instance_id TEXT NOT NULL REFERENCES adapter_instances(id),
        canonical_id TEXT NOT NULL,
        urls_json TEXT NOT NULL,
        fetched_at TEXT NOT NULL,
        remote_created_at TEXT,
        title TEXT NOT NULL,
        body TEXT,
        priority INTEGER,
        action_item INTEGER,
        info_json TEXT NOT NULL,
        PRIMARY KEY (instance_id, canonical_id)
      );

      CREATE TABLE IF NOT EXISTS fetch_runs (
        id INTEGER PRIMARY KEY,
        instance_id TEXT NOT NULL REFERENCES adapter_instances(id),
        status TEXT NOT NULL,
        started_at TEXT NOT NULL,
        finished_at TEXT NOT NULL,
        item_count INTEGER NOT NULL,
        error_message TEXT,
        metadata_json TEXT NOT NULL
      );
    SQL

    def self.apply(database)
      database.execute_batch(DDL)
      database.execute("INSERT OR IGNORE INTO schema_migrations (version) VALUES (?)", [VERSION])
    end
  end
end
