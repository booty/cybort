module Cybort
  class TimeSeriesImportReceipt
    IMPORT_MODES = %i[append snapshot].freeze
    DIGEST_PATTERN = /\A[0-9a-f]{64}\z/.freeze

    attr_reader :instance_id, :import_key, :artifact_digest, :import_mode,
                :source_started_at, :source_finished_at, :committed_at,
                :acknowledged_at, :imported_series_count,
                :imported_observation_count, :stored_series_count,
                :stored_observation_count, :sync_state, :metadata

    def initialize(instance_id:, import_key:, artifact_digest:, import_mode:,
                   source_started_at:, source_finished_at:, committed_at:,
                   imported_series_count:, imported_observation_count:,
                   stored_series_count:, stored_observation_count:, sync_state:,
                   metadata:, acknowledged_at: nil)
      @instance_id = identifier(instance_id, "instance_id", 256)
      @import_key = identifier(import_key, "import_key", 256)
      unless artifact_digest.is_a?(String) && artifact_digest.match?(DIGEST_PATTERN)
        raise ArgumentError, "invalid artifact digest"
      end
      @artifact_digest = artifact_digest.dup.freeze
      unless IMPORT_MODES.include?(import_mode)
        raise ArgumentError, "invalid import mode"
      end
      @import_mode = import_mode
      @source_started_at = time(source_started_at, "source_started_at")
      @source_finished_at = time(source_finished_at, "source_finished_at")
      @committed_at = time(committed_at, "committed_at")
      @acknowledged_at = acknowledged_at.nil? ? nil : time(acknowledged_at, "acknowledged_at")
      raise ArgumentError, "source_finished_at precedes source_started_at" if @source_finished_at < @source_started_at
      unless [imported_series_count, imported_observation_count,
              stored_series_count, stored_observation_count].all? { |count| count.is_a?(Integer) && count >= 0 }
        raise ArgumentError, "counts must be nonnegative integers"
      end
      @imported_series_count = imported_series_count
      @imported_observation_count = imported_observation_count
      @stored_series_count = stored_series_count
      @stored_observation_count = stored_observation_count
      @sync_state = sync_state.nil? ? nil : TimeSeriesJSON.validate_metadata!(sync_state)
      @metadata = TimeSeriesJSON.validate_metadata!(metadata)
      freeze
    end

    alias digest artifact_digest

    def self.from_row(row)
      new(
        instance_id: row.fetch("adapter_instance_id"), import_key: row.fetch("import_key"),
        artifact_digest: row.fetch("artifact_digest"), import_mode: row.fetch("import_mode").to_sym,
        source_started_at: TimeSeriesSchema.utc_time(row.fetch("source_started_at_us")),
        source_finished_at: TimeSeriesSchema.utc_time(row.fetch("source_finished_at_us")),
        committed_at: TimeSeriesSchema.utc_time(row.fetch("committed_at_us")),
        acknowledged_at: TimeSeriesSchema.utc_time(row.fetch("acknowledged_at_us")),
        imported_series_count: row.fetch("imported_series_count"),
        imported_observation_count: row.fetch("imported_observation_count"),
        stored_series_count: row.fetch("stored_series_count"),
        stored_observation_count: row.fetch("stored_observation_count"),
        sync_state: row["sync_state_json"] && JSON.parse(row.fetch("sync_state_json")),
        metadata: JSON.parse(row.fetch("metadata_json"))
      )
    end

    private

    def identifier(value, label, max_bytes)
      value = value.dup.force_encoding(Encoding::UTF_8) if value.is_a?(String)
      valid = value.is_a?(String) && value.valid_encoding? && !value.strip.empty? &&
              value.bytesize <= max_bytes && !value.match?(/[\x00-\x1f\x7f]/)
      raise ArgumentError, "invalid #{label}" unless valid
      value.freeze
    end

    def time(value, label)
      raise ArgumentError, "#{label} must be a Time" unless value.is_a?(Time)
      value.dup.utc.freeze
    end
  end
end
