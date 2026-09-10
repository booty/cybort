require "sqlite3"

module Cybort
  class TimeSeriesReader
    Series = Data.define(:id, :adapter_instance_id, :series_key, :metric_key,
                         :value_type, :canonical_unit, :dimensions, :created_at, :updated_at)
    Observation = Data.define(:series_id, :source_record_key, :observed_at, :ended_at,
                              :numeric_value, :categorical_value, :ingested_at, :metadata)

    def initialize(path)
      @database = SQLite3::Database.new(
        TimeSeriesSchema.file_uri(path),
        flags: SQLite3::Constants::Open::READONLY | SQLite3::Constants::Open::URI
      )
      @database.results_as_hash = true
      @database.busy_timeout(5_000)
      @database.execute("PRAGMA query_only = ON")
      @database.execute("PRAGMA foreign_keys = ON")
    rescue Exception # release a partially configured connection, including on shutdown
      @database&.close
      raise
    end

    def close
      @database.close unless @database.closed?
      nil
    end

    def context_for(instance_id:)
      row = @database.get_first_row(<<~SQL, [instance_id])
        SELECT state.stored_series_count, state.stored_observation_count,
               receipt.sync_state_json
        FROM time_series_instance_state AS state
        JOIN time_series_imports AS receipt
          ON receipt.adapter_instance_id = state.adapter_instance_id
         AND receipt.import_key = state.latest_import_key
        WHERE state.adapter_instance_id = ?
      SQL
      TimeSeriesJSON.deep_freeze(
        series_count: row ? row.fetch("stored_series_count") : 0,
        observation_count: row ? row.fetch("stored_observation_count") : 0,
        sync_state: row && row["sync_state_json"] && JSON.parse(row.fetch("sync_state_json"))
      )
    end

    def series_for(instance_id: nil, metric_key: nil, after_id: nil, limit:)
      validate_limit!(limit, 1_000)
      raise ArgumentError, "after_id must be a nonnegative integer" unless after_id.nil? || (after_id.is_a?(Integer) && after_id >= 0)
      predicates = []
      binds = []
      { "adapter_instance_id = ?" => instance_id, "metric_key = ?" => metric_key,
        "id > ?" => after_id }.each do |predicate, value|
        next if value.nil?
        predicates << predicate
        binds << value
      end
      sql = +"SELECT * FROM series"
      sql << " WHERE #{predicates.join(' AND ')}" unless predicates.empty?
      sql << " ORDER BY id ASC LIMIT ?"
      @database.execute(sql, binds + [limit]).map { |row| series_from_row(row) }.freeze
    end

    # This is a closed window on observation start times, including intervals
    # whose start is in the window; it is not an interval-overlap query.
    def observations_for(series_ids:, started_at:, ended_at:, limit:, order: :ascending)
      validate_limit!(limit, 10_000)
      unless series_ids.is_a?(Array) && series_ids.all? { |id| id.is_a?(Integer) && (1...2**63).cover?(id) }
        raise ArgumentError, "series_ids must contain integer database IDs"
      end
      ids = series_ids.uniq
      raise ArgumentError, "provide 1 through 500 series IDs" unless (1..500).cover?(ids.length)
      start_us = TimeSeriesSchema.microseconds(started_at)
      end_us = TimeSeriesSchema.microseconds(ended_at)
      raise ArgumentError, "ended_at precedes started_at" if ended_at < started_at
      direction = { ascending: "ASC", descending: "DESC" }[order]
      raise ArgumentError, "invalid observation order" unless direction
      sql = <<~SQL
        SELECT * FROM observations
        WHERE series_id IN (#{(['?'] * ids.length).join(', ')})
          AND observed_at_us >= ? AND observed_at_us <= ?
        ORDER BY observed_at_us #{direction}, series_id #{direction}, source_record_key #{direction}
        LIMIT ?
      SQL
      @database.execute(sql, ids + [start_us, end_us, limit]).map { |row| observation_from_row(row) }.freeze
    end

    def pending_receipts
      @database.execute(<<~SQL).map { |row| TimeSeriesImportReceipt.from_row(row) }.freeze
        SELECT * FROM time_series_imports WHERE acknowledged_at_us IS NULL
        ORDER BY adapter_instance_id ASC, source_finished_at_us ASC, import_key ASC
      SQL
    end

    private

    def validate_limit!(limit, maximum)
      raise ArgumentError, "invalid query limit" unless limit.is_a?(Integer) && (1..maximum).cover?(limit)
    end

    def series_from_row(row)
      Series.new(
        id: row.fetch("id"), adapter_instance_id: row.fetch("adapter_instance_id").freeze,
        series_key: row.fetch("series_key").freeze, metric_key: row.fetch("metric_key").freeze,
        value_type: row.fetch("value_type").to_sym, canonical_unit: row["canonical_unit"]&.freeze,
        dimensions: TimeSeriesJSON.validate_dimensions!(JSON.parse(row.fetch("dimensions_json"))),
        created_at: TimeSeriesSchema.utc_time(row.fetch("created_at_us")),
        updated_at: TimeSeriesSchema.utc_time(row.fetch("updated_at_us"))
      )
    end

    def observation_from_row(row)
      Observation.new(
        series_id: row.fetch("series_id"), source_record_key: row.fetch("source_record_key").freeze,
        observed_at: TimeSeriesSchema.utc_time(row.fetch("observed_at_us")),
        ended_at: TimeSeriesSchema.utc_time(row.fetch("ended_at_us")),
        numeric_value: row["numeric_value"], categorical_value: row["categorical_value"]&.freeze,
        ingested_at: TimeSeriesSchema.utc_time(row.fetch("ingested_at_us")),
        metadata: TimeSeriesJSON.validate_metadata!(JSON.parse(row.fetch("metadata_json")))
      )
    end
  end
end
