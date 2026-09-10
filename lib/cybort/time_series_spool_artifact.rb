module Cybort
  class TimeSeriesSpoolArtifact
    IMPORT_MODES = %i[append snapshot].freeze
    DIGEST_PATTERN = /\A[0-9a-f]{64}\z/.freeze

    attr_reader :path, :instance_id, :import_key, :import_mode, :digest,
                :series_count, :observation_count, :sync_state,
                :source_started_at, :source_finished_at, :metadata

    def initialize(path:, instance_id:, import_key:, import_mode:, digest:, series_count:,
                   observation_count:, sync_state:, source_started_at:, source_finished_at:, metadata:)
      validate_path!(path)
      @path = path.dup.freeze
      @instance_id = validate_identifier(instance_id, "instance_id", 256)
      @import_key = validate_identifier(import_key, "import_key", 256)
      raise ArgumentError, "invalid import mode" unless IMPORT_MODES.include?(import_mode)
      @import_mode = import_mode
      raise ArgumentError, "invalid digest" unless digest.is_a?(String) && digest.match?(DIGEST_PATTERN)
      @digest = digest.dup.freeze
      @series_count = validate_count(series_count, "series_count")
      @observation_count = validate_count(observation_count, "observation_count")
      @sync_state = TimeSeriesJSON.validate_metadata!(sync_state)
      @source_started_at = validate_time(source_started_at, "source_started_at")
      @source_finished_at = validate_time(source_finished_at, "source_finished_at")
      raise ArgumentError, "source_finished_at precedes source_started_at" if @source_finished_at < @source_started_at
      @metadata = TimeSeriesJSON.validate_metadata!(metadata)
      freeze
    end

    private

    def validate_path!(path)
      raise ArgumentError, "spool path must be absolute" unless path.is_a?(String) && path.start_with?(File::SEPARATOR)
      stat = File.lstat(path)
      raise ArgumentError, "spool path must be a regular file" unless stat.file?
      raise ArgumentError, "spool path permissions are too broad" unless (stat.mode & 0o777 & ~0o600).zero?
    rescue Errno::ENOENT
      raise ArgumentError, "spool path must exist"
    end

    def validate_identifier(value, label, max_bytes)
      value = value.dup.force_encoding(Encoding::UTF_8) if value.is_a?(String)
      unless value.is_a?(String) && value.valid_encoding? && !value.strip.empty? && value.bytesize <= max_bytes && !value.match?(/[\x00-\x1f\x7f]/)
        raise ArgumentError, "invalid #{label}"
      end
      value.freeze
    end

    def validate_count(value, label)
      raise ArgumentError, "#{label} must be a nonnegative integer" unless value.is_a?(Integer) && value >= 0
      value
    end

    def validate_time(value, label)
      raise ArgumentError, "#{label} must be a Time" unless value.is_a?(Time)
      value.dup.freeze
    end
  end
end
