require "digest"
require "fileutils"
require "securerandom"
require "sqlite3"

module Cybort
  # A disposable, adapter-facing SQLite database for large time-series imports.
  # This class intentionally exposes domain operations only; canonical SQL is
  # owned by the later time-series persistence implementation.
  class TimeSeriesSpoolFactory
    SPOOL_PREFIX = "cybort-time-series-spool-"

    def initialize(directory:, clock: -> { Time.now.utc })
      @directory = File.expand_path(directory.to_s)
      @clock = clock
      raise ArgumentError, "clock must be callable" unless @clock.respond_to?(:call)

      prepare_directory!
      cleanup_orphans!
    end

    def open(instance_id:, import_key:, import_mode:, source_started_at:)
      validate_identifier!(instance_id, "instance_id", 256)
      validate_identifier!(import_key, "import_key", 256)
      raise ArgumentError, "invalid import mode" unless TimeSeriesSpoolArtifact::IMPORT_MODES.include?(import_mode)
      validate_time!(source_started_at, "source_started_at")

      path = new_path
      writer = TimeSeriesSpoolWriter.new(
        path: path,
        instance_id: instance_id,
        import_key: import_key,
        import_mode: import_mode,
        source_started_at: source_started_at,
        clock: @clock
      )
      return writer unless block_given?

      begin
        yield writer
      rescue Exception # rubocop:disable Lint/RescueException -- cleanup must include shutdown exceptions
        writer.abort
        raise
      ensure
        writer.abort unless writer.closed?
      end
    rescue Exception # rubocop:disable Lint/RescueException -- remove partially-created spool on shutdown
      FileUtils.rm_f(path) if path
      FileUtils.rm_f("#{path}-journal") if path
      raise
    end

    # Called at startup while the installation-wide lock is held. Only direct
    # regular files are eligible; symlinks and directories are left alone.
    def cleanup_orphans!
      Dir.each_child(@directory) do |name|
        next unless name.start_with?(SPOOL_PREFIX)

        path = File.join(@directory, name)
        begin
          stat = File.lstat(path)
          FileUtils.rm_f(path) if stat.file? && !stat.symlink?
        rescue Errno::ENOENT
          next
        end
      end
      self
    end

    private

    def prepare_directory!
      if File.exist?(@directory) || File.symlink?(@directory)
        stat = File.lstat(@directory)
        raise ArgumentError, "spool directory must be a directory" unless stat.directory? && !stat.symlink?
      else
        FileUtils.mkdir_p(@directory)
      end
      File.chmod(0o700, @directory)
    rescue Errno::EACCES, Errno::ENOTDIR
      raise ArgumentError, "spool directory is not usable"
    end

    def new_path
      loop do
        path = File.join(@directory, "#{SPOOL_PREFIX}#{SecureRandom.hex(16)}.sqlite3")
        begin
          File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.close }
          return path
        rescue Errno::EEXIST
          next
        end
      end
    end

    def validate_identifier!(value, label, max_bytes)
      value = value.dup.force_encoding(Encoding::UTF_8) if value.is_a?(String)
      valid = value.is_a?(String) && value.valid_encoding? && !value.strip.empty? &&
              value.bytesize <= max_bytes && !value.match?(/[\x00-\x1f\x7f]/)
      raise ArgumentError, "invalid #{label}" unless valid
      value
    end

    def validate_time!(value, label)
      raise ArgumentError, "#{label} must be a Time" unless value.is_a?(Time)
    end
  end

  class TimeSeriesSpoolWriter
    BATCH_SIZE = 10_000

    SCHEMA = <<~SQL
      CREATE TABLE spool_series (
        series_key TEXT PRIMARY KEY,
        metric_key TEXT NOT NULL,
        value_type TEXT NOT NULL CHECK (value_type IN ('numeric', 'categorical')),
        canonical_unit TEXT,
        dimensions_json TEXT NOT NULL
      );

      CREATE TABLE spool_observations (
        series_key TEXT NOT NULL REFERENCES spool_series(series_key),
        source_record_key TEXT NOT NULL,
        observed_at_us INTEGER NOT NULL,
        ended_at_us INTEGER,
        numeric_value REAL,
        categorical_value TEXT,
        metadata_json TEXT NOT NULL,
        PRIMARY KEY (series_key, source_record_key),
        CHECK (ended_at_us IS NULL OR ended_at_us >= observed_at_us),
        CHECK ((numeric_value IS NOT NULL) <> (categorical_value IS NOT NULL))
      );

      CREATE TABLE spool_manifest (
        singleton_id INTEGER PRIMARY KEY CHECK (singleton_id = 1),
        instance_id TEXT NOT NULL,
        import_key TEXT NOT NULL,
        import_mode TEXT NOT NULL CHECK (import_mode IN ('append', 'snapshot')),
        series_count INTEGER NOT NULL,
        observation_count INTEGER NOT NULL,
        sync_state_json TEXT,
        source_started_at_us INTEGER NOT NULL,
        source_finished_at_us INTEGER NOT NULL,
        metadata_json TEXT NOT NULL
      );
    SQL
    private_constant :SCHEMA

    attr_reader :path

    def initialize(path:, instance_id:, import_key:, import_mode:, source_started_at:, clock:)
      @path = path
      @instance_id = validate_identifier(instance_id, "instance_id", 256)
      @import_key = validate_identifier(import_key, "import_key", 256)
      raise ArgumentError, "invalid import mode" unless TimeSeriesSpoolArtifact::IMPORT_MODES.include?(import_mode)
      @import_mode = import_mode
      @source_started_at = validate_time(source_started_at, "source_started_at")
      @clock = clock
      @database = nil
      @statements = []
      @series_definitions = {}
      @series_count = 0
      @observation_count = 0
      @batch_writes = 0
      @batch_series_keys = []
      @batch_observation_count = 0
      @in_batch = false
      @closed = false
      open_database!
    rescue Exception # rubocop:disable Lint/RescueException -- rollback and close on shutdown exceptions
      close_database
      FileUtils.rm_f(@path)
      FileUtils.rm_f("#{@path}-journal")
      raise
    end

    def register_series(series_key:, metric_key:, value_type:, canonical_unit:, dimensions:)
      ensure_open!
      definition = normalize_series_definition(
        series_key: series_key,
        metric_key: metric_key,
        value_type: value_type,
        canonical_unit: canonical_unit,
        dimensions: dimensions
      )
      existing = @series_definitions[definition.fetch(:series_key)]
      if existing
        raise ArgumentError, "series definition does not match" unless existing == definition
        return nil
      end

      write_started = false
      begin_batch
      write_started = true
      execute_statement(@insert_series, [
        definition.fetch(:series_key), definition.fetch(:metric_key), definition.fetch(:value_type),
        definition.fetch(:canonical_unit), definition.fetch(:dimensions_json)
      ])
      @series_definitions[definition.fetch(:series_key)] = definition.freeze
      @batch_series_keys << definition.fetch(:series_key)
      @series_count += 1
      count_batch_write
      nil
    rescue SQLite3::ConstraintException => error
      rollback_batch if write_started
      raise ArgumentError, "duplicate series key: #{error.message}"
    rescue Exception # rubocop:disable Lint/RescueException -- rollback and close on shutdown exceptions
      rollback_batch if write_started
      raise
    end

    def add_observation(series_key:, source_record_key:, observed_at:, ended_at: nil,
                        numeric_value: nil, categorical_value: nil, metadata:)
      ensure_open!
      series_key = validate_identifier(series_key, "series_key", 256)
      source_record_key = validate_identifier(source_record_key, "source_record_key", 512)
      observed_at = validate_time(observed_at, "observed_at")
      ended_at = validate_time(ended_at, "ended_at") unless ended_at.nil?
      if ended_at && ended_at < observed_at
        raise ArgumentError, "ended_at precedes observed_at"
      end
      metadata = TimeSeriesJSON.validate_metadata!(metadata)
      definition = @series_definitions[series_key]
      raise ArgumentError, "unknown series" unless definition

      numeric = validate_numeric(numeric_value)
      categorical = validate_categorical(categorical_value)
      if (numeric.nil?) == (categorical.nil?)
        raise ArgumentError, "exactly one observation value is required"
      end
      if definition.fetch(:value_type) == "numeric"
        raise ArgumentError, "numeric series require numeric_value" if numeric.nil? || !categorical.nil?
      elsif categorical.nil? || !numeric.nil?
        raise ArgumentError, "categorical series require categorical_value"
      end

      write_started = false
      begin_batch
      write_started = true
      execute_statement(@insert_observation, [
        series_key, source_record_key, utc_microseconds(observed_at),
        ended_at && utc_microseconds(ended_at), numeric, categorical, JSON.generate(metadata)
      ])
      @observation_count += 1
      @batch_observation_count += 1
      count_batch_write
      nil
    rescue SQLite3::ConstraintException => error
      rollback_batch if write_started
      raise ArgumentError, "duplicate source record key or observation constraint: #{error.message}"
    rescue Exception # rubocop:disable Lint/RescueException -- finalized files must not leak on shutdown exceptions
      rollback_batch if write_started
      raise
    end

    def finalize(sync_state:, source_finished_at:, metadata:)
      ensure_open!
      source_finished_at = validate_time(source_finished_at, "source_finished_at")
      raise ArgumentError, "source_finished_at precedes source_started_at" if source_finished_at < @source_started_at
      sync_state = TimeSeriesJSON.validate_metadata!(sync_state)
      metadata = TimeSeriesJSON.validate_metadata!(metadata)

      begin
        commit_batch
        execute_manifest(sync_state: sync_state, source_finished_at: source_finished_at, metadata: metadata)
        validate_manifest!(sync_state: sync_state, source_finished_at: source_finished_at, metadata: metadata)
        close_database
        FileUtils.rm_f("#{@path}-journal")
        File.chmod(0o400, @path)
        digest = stream_digest(@path)
        artifact = TimeSeriesSpoolArtifact.new(
          path: @path,
          instance_id: @instance_id,
          import_key: @import_key,
          import_mode: @import_mode,
          digest: digest,
          series_count: @series_count,
          observation_count: @observation_count,
          sync_state: sync_state,
          source_started_at: @source_started_at,
          source_finished_at: source_finished_at,
          metadata: metadata
        )
        @closed = true
        @finalized = true
        artifact
      rescue Exception # rubocop:disable Lint/RescueException -- finalized files must not leak on shutdown exceptions
        abort
        raise
      end
    end

    def abort
      return nil if @closed && !@finalized
      return nil if @finalized

      rollback_batch
      close_database
      FileUtils.rm_f(@path)
      FileUtils.rm_f("#{@path}-journal")
      @closed = true
      nil
    end

    def closed?
      @closed
    end

    def finalized?
      @finalized == true
    end

    def self.utc_microseconds(time)
      (time.to_r * 1_000_000).floor
    end

    private

    def utc_microseconds(time)
      self.class.utc_microseconds(time)
    end

    def open_database!
      @database = SQLite3::Database.new(@path)
      @database.busy_timeout(5_000)
      @database.execute("PRAGMA foreign_keys = ON")
      @database.execute("PRAGMA journal_mode = DELETE")
      @database.execute("PRAGMA synchronous = NORMAL")
      @database.execute_batch(SCHEMA)
      File.chmod(0o600, @path)
      @insert_series = prepare(<<~SQL)
        INSERT INTO spool_series (series_key, metric_key, value_type, canonical_unit, dimensions_json)
        VALUES (?, ?, ?, ?, ?)
      SQL
      @insert_observation = prepare(<<~SQL)
        INSERT INTO spool_observations (
          series_key, source_record_key, observed_at_us, ended_at_us,
          numeric_value, categorical_value, metadata_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
      SQL
      @insert_manifest = prepare(<<~SQL)
        INSERT INTO spool_manifest (
          singleton_id, instance_id, import_key, import_mode, series_count,
          observation_count, sync_state_json, source_started_at_us,
          source_finished_at_us, metadata_json
        ) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
    end

    def prepare(sql)
      statement = @database.prepare(sql)
      @statements << statement
      statement
    end

    def execute_statement(statement, binds)
      result = statement.execute(*binds)
      result.close if result.respond_to?(:close)
      nil
    end

    def begin_batch
      return if @in_batch

      @database.execute("BEGIN")
      @in_batch = true
    end

    def count_batch_write
      @batch_writes += 1
      commit_batch if @batch_writes >= BATCH_SIZE
    end

    def commit_batch
      return unless @in_batch

      @database.execute("COMMIT")
      @in_batch = false
      @batch_writes = 0
      @batch_series_keys.clear
      @batch_observation_count = 0
    end

    def rollback_batch
      return unless @database && @in_batch

      @database.execute("ROLLBACK")
      @batch_series_keys.each { |series_key| @series_definitions.delete(series_key) }
      @series_count -= @batch_series_keys.length
      @observation_count -= @batch_observation_count
      @in_batch = false
      @batch_writes = 0
      @batch_series_keys.clear
      @batch_observation_count = 0
    rescue SQLite3::Exception
      @in_batch = false
      @batch_writes = 0
      @batch_series_keys.clear
      @batch_observation_count = 0
    end

    def execute_manifest(sync_state:, source_finished_at:, metadata:)
      @database.transaction do
        execute_statement(@insert_manifest, [
          @instance_id, @import_key, @import_mode.to_s, @series_count, @observation_count,
          JSON.generate(sync_state), utc_microseconds(@source_started_at),
          utc_microseconds(source_finished_at), JSON.generate(metadata)
        ])
      end
    end

    def validate_manifest!(sync_state:, source_finished_at:, metadata:)
      row = @database.get_first_row(
        "SELECT instance_id, import_key, import_mode, series_count, observation_count,
                sync_state_json, source_started_at_us, source_finished_at_us, metadata_json
           FROM spool_manifest WHERE singleton_id = 1"
      )
      expected = [
        @instance_id, @import_key, @import_mode.to_s, @series_count, @observation_count,
        JSON.generate(sync_state), utc_microseconds(@source_started_at),
        utc_microseconds(source_finished_at), JSON.generate(metadata)
      ]
      raise ArgumentError, "spool manifest is invalid" unless row == expected
    end

    def close_database
      @statements.each { |statement| statement.close rescue nil }
      @statements.clear
      @database&.close
      @database = nil
    end

    def stream_digest(path)
      digest = Digest::SHA256.new
      File.open(path, "rb") do |file|
        while (chunk = file.read(1024 * 1024))
          digest.update(chunk)
        end
      end
      digest.hexdigest
    end

    def normalize_series_definition(series_key:, metric_key:, value_type:, canonical_unit:, dimensions:)
      series_key = validate_identifier(series_key, "series_key", 256)
      metric_key = validate_identifier(metric_key, "metric_key", 128)
      raise ArgumentError, "invalid value_type" unless %i[numeric categorical].include?(value_type)
      if value_type == :categorical
        raise ArgumentError, "categorical series cannot have a canonical unit" unless canonical_unit.nil?
      else
        canonical_unit = validate_identifier(canonical_unit, "canonical_unit", 64)
      end
      dimensions = TimeSeriesJSON.validate_dimensions!(dimensions)
      {
        series_key: series_key,
        metric_key: metric_key,
        value_type: value_type.to_s,
        canonical_unit: canonical_unit,
        dimensions: dimensions,
        dimensions_json: JSON.generate(dimensions)
      }
    end

    def validate_numeric(value)
      return nil if value.nil?
      valid = (value.is_a?(Integer) || value.is_a?(Float)) && (!value.respond_to?(:finite?) || value.finite?)
      raise ArgumentError, "numeric_value must be finite" unless valid
      value
    end

    def validate_categorical(value)
      return nil if value.nil?
      value = value.dup.force_encoding(Encoding::UTF_8) if value.is_a?(String)
      valid = value.is_a?(String) && value.valid_encoding? && !value.strip.empty? && value.bytesize <= 1_024
      raise ArgumentError, "categorical_value must be a nonblank UTF-8 string" unless valid
      value
    end

    def validate_identifier(value, label, max_bytes)
      value = value.dup.force_encoding(Encoding::UTF_8) if value.is_a?(String)
      valid = value.is_a?(String) && value.valid_encoding? && !value.strip.empty? &&
              value.bytesize <= max_bytes && !value.match?(/[\x00-\x1f\x7f]/)
      raise ArgumentError, "invalid #{label}" unless valid
      value.freeze
    end

    def validate_time(value, label)
      raise ArgumentError, "#{label} must be a Time" unless value.is_a?(Time)
      value
    end

    def ensure_open!
      raise ArgumentError, "spool writer is finalized or closed" if @closed
    end
  end
end
