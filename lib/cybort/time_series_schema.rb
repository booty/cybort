module Cybort
  module TimeSeriesSchema
    VERSION = 1

    DDL = <<~SQL
      CREATE TABLE IF NOT EXISTS time_series_schema_migrations (
        version INTEGER PRIMARY KEY
      );

      CREATE TABLE IF NOT EXISTS series (
        id INTEGER PRIMARY KEY,
        adapter_instance_id TEXT NOT NULL,
        series_key TEXT NOT NULL,
        metric_key TEXT NOT NULL,
        value_type TEXT NOT NULL CHECK (value_type IN ('numeric', 'categorical')),
        canonical_unit TEXT,
        dimensions_json TEXT NOT NULL,
        created_at_us INTEGER NOT NULL,
        updated_at_us INTEGER NOT NULL,
        UNIQUE (adapter_instance_id, series_key),
        CHECK ((value_type = 'numeric' AND canonical_unit IS NOT NULL) OR
               (value_type = 'categorical' AND canonical_unit IS NULL))
      );

      CREATE TABLE IF NOT EXISTS observations (
        series_id INTEGER NOT NULL REFERENCES series(id) ON DELETE CASCADE,
        source_record_key TEXT NOT NULL,
        observed_at_us INTEGER NOT NULL,
        ended_at_us INTEGER,
        numeric_value REAL,
        categorical_value TEXT,
        ingested_at_us INTEGER NOT NULL,
        metadata_json TEXT NOT NULL,
        PRIMARY KEY (series_id, source_record_key),
        CHECK (ended_at_us IS NULL OR ended_at_us >= observed_at_us),
        CHECK ((numeric_value IS NOT NULL) <> (categorical_value IS NOT NULL))
      );

      CREATE INDEX IF NOT EXISTS idx_observations_series_time
        ON observations (series_id, observed_at_us, source_record_key);

      CREATE INDEX IF NOT EXISTS idx_observations_time_series
        ON observations (observed_at_us, series_id, source_record_key);

      CREATE TABLE IF NOT EXISTS time_series_instance_state (
        adapter_instance_id TEXT PRIMARY KEY,
        latest_import_key TEXT NOT NULL,
        stored_series_count INTEGER NOT NULL,
        stored_observation_count INTEGER NOT NULL,
        updated_at_us INTEGER NOT NULL
      );

      CREATE TABLE IF NOT EXISTS time_series_imports (
        adapter_instance_id TEXT NOT NULL,
        import_key TEXT NOT NULL,
        artifact_digest TEXT NOT NULL,
        import_mode TEXT NOT NULL CHECK (import_mode IN ('append', 'snapshot')),
        source_started_at_us INTEGER NOT NULL,
        source_finished_at_us INTEGER NOT NULL,
        committed_at_us INTEGER NOT NULL,
        imported_series_count INTEGER NOT NULL,
        imported_observation_count INTEGER NOT NULL,
        stored_series_count INTEGER NOT NULL,
        stored_observation_count INTEGER NOT NULL,
        sync_state_json TEXT,
        metadata_json TEXT NOT NULL,
        acknowledged_at_us INTEGER,
        PRIMARY KEY (adapter_instance_id, import_key)
      );
    SQL

    module_function

    # Escape pathname bytes, including URI metacharacters; bind the completed
    # URI as a value whenever attaching a database.
    def file_uri(path, immutable: false)
      escaped = File.expand_path(path.to_s).b.bytes.map do |byte|
        character = byte.chr
        character.match?(/[A-Za-z0-9_.~\/-]/) ? character : format("%%%02X", byte)
      end.join
      "file:#{escaped}?mode=ro#{'&immutable=1' if immutable}"
    end

    def microseconds(time)
      raise ArgumentError, "timestamp must be a Time" unless time.is_a?(Time)
      value = (time.to_r * 1_000_000).floor
      raise ArgumentError, "timestamp is outside SQLite integer range" unless (-(2**63)...2**63).cover?(value)
      value
    end

    def utc_time(value)
      value.nil? ? nil : Time.at(Rational(value, 1_000_000)).utc.freeze
    end

    def apply(database)
      database.execute_batch(DDL)
      database.execute("INSERT OR IGNORE INTO time_series_schema_migrations (version) VALUES (?)", [VERSION])
    end
  end
end
