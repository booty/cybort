require "digest"
require "fileutils"
require "sqlite3"

module Cybort
  class TimeSeriesPersistence
    CLEANUP_FAILURE_LIMIT = 8
    CLEANUP_FAILURE_FIELD_BYTES = 128

    SPOOL_COLUMNS = {
      "spool_series" => %w[series_key metric_key value_type canonical_unit dimensions_json],
      "spool_observations" => %w[series_key source_record_key observed_at_us ended_at_us numeric_value categorical_value metadata_json],
      "spool_manifest" => %w[singleton_id instance_id import_key import_mode series_count observation_count sync_state_json source_started_at_us source_finished_at_us metadata_json]
    }.freeze
    private_constant :SPOOL_COLUMNS

    def initialize(path, clock: -> { Time.now.utc })
      @owner_thread = Thread.current
      @path = File.expand_path(path.to_s)
      @clock = clock
      @database = SQLite3::Database.new(
        @path, flags: SQLite3::Constants::Open::READWRITE |
                      SQLite3::Constants::Open::CREATE | SQLite3::Constants::Open::URI
      )
      File.chmod(0o600, @path)
      @database.results_as_hash = true
      @database.busy_timeout(5_000)
      # Canonicalize bounded, flat dimensions during the set-oriented upsert.
      # Sorting keys makes an object's insertion order irrelevant to its history.
      @database.create_function("cybort_normalized_dimensions", 1) do |function, encoded|
        dimensions = TimeSeriesJSON.validate_dimensions!(JSON.parse(encoded))
        function.result = JSON.generate(dimensions.sort.to_h)
      end
    rescue Exception # close partially initialized handles, including on shutdown
      @database&.close
      raise
    end

    def setup!
      ensure_owner!
      @database.execute("PRAGMA foreign_keys = ON")
      @database.execute("PRAGMA journal_mode = WAL")
      @database.transaction { TimeSeriesSchema.apply(@database) }
      self
    end

    def close
      ensure_owner!
      @database.close unless @database.closed?
      nil
    end

    def import(artifact)
      ensure_owner!
      validate_artifact!(artifact)
      attached = false
      active_error = nil
      begin
        @database.transaction(:immediate) do
          existing = receipt_for(artifact.instance_id, artifact.import_key)
          if existing
            raise ArgumentError, "import key already has a different digest" unless existing.artifact_digest == artifact.digest
            next existing
          end

          @database.execute("ATTACH DATABASE ? AS incoming", [TimeSeriesSchema.file_uri(artifact.path, immutable: true)])
          attached = true
          validate_existing_series!(artifact.instance_id)
          committed_at_us = TimeSeriesSchema.microseconds(@clock.call)
          upsert_series(artifact.instance_id, committed_at_us)
          upsert_observations(artifact.instance_id, committed_at_us)
          replace_snapshot(artifact.instance_id) if artifact.import_mode == :snapshot
          record_import(artifact, committed_at_us)
          receipt_for(artifact.instance_id, artifact.import_key)
        end
      rescue Exception => error # detach must also run for interrupts and shutdown
        active_error = error
        raise
      ensure
        if attached
          begin
            @database.execute("DETACH DATABASE incoming")
          rescue Exception => cleanup_error
            if active_error
              # Keep source/SQL error identity and expose only bounded, body-free
              # cleanup context. Cleanup must never hide the primary failure.
              attach_cleanup_failure(active_error, cleanup_error, phase: "detach_incoming")
            else
              raise
            end
          end
        end
      end
    end

    def mark_acknowledged(receipt)
      ensure_owner!
      raise ArgumentError, "expected an import receipt" unless receipt.is_a?(TimeSeriesImportReceipt)
      @database.transaction(:immediate) do
        stored = receipt_for(receipt.instance_id, receipt.import_key)
        unless stored && stored.artifact_digest == receipt.artifact_digest
          raise ArgumentError, "receipt does not match a stored import"
        end
        next stored if stored.acknowledged_at

        @database.execute(<<~SQL, [TimeSeriesSchema.microseconds(@clock.call), receipt.instance_id, receipt.import_key])
          UPDATE time_series_imports SET acknowledged_at_us = ?
          WHERE adapter_instance_id = ? AND import_key = ? AND acknowledged_at_us IS NULL
        SQL
        receipt_for(receipt.instance_id, receipt.import_key)
      end
    end

    def delete_instance(instance_id:)
      ensure_owner!
      @database.transaction(:immediate) do
        changed = false
        %w[series time_series_imports time_series_instance_state].each do |table|
          @database.execute("DELETE FROM #{table} WHERE adapter_instance_id = ?", [instance_id])
          changed = true if @database.changes.positive?
        end
        changed
      end
    end

    def instance_present?(instance_id:)
      ensure_owner!
      !@database.get_first_value(<<~SQL, [instance_id, instance_id, instance_id]).nil?
        SELECT 1 FROM (
          SELECT adapter_instance_id FROM series WHERE adapter_instance_id = ?
          UNION ALL
          SELECT adapter_instance_id FROM time_series_imports WHERE adapter_instance_id = ?
          UNION ALL
          SELECT adapter_instance_id FROM time_series_instance_state WHERE adapter_instance_id = ?
        ) LIMIT 1
      SQL
    end

    def backup_to(path)
      ensure_owner!
      destination = File.expand_path(path.to_s)
      raise ValidationError, "backup destination already exists" if File.exist?(destination) || File.symlink?(destination)
      FileUtils.mkdir_p(File.dirname(destination))
      @database.execute("VACUUM INTO ?", [destination])
      File.chmod(0o600, destination)
      destination
    end

    private

    def ensure_owner!
      raise RuntimeError, "time-series persistence must be used on its owner thread" unless Thread.current.equal?(@owner_thread)
    end

    def receipt_for(instance_id, import_key)
      row = @database.get_first_row(
        "SELECT * FROM time_series_imports WHERE adapter_instance_id = ? AND import_key = ?",
        [instance_id, import_key]
      )
      row && TimeSeriesImportReceipt.from_row(row)
    end

    def validate_artifact!(artifact)
      raise ArgumentError, "expected a finalized spool artifact" unless artifact.is_a?(TimeSeriesSpoolArtifact)
      stat = File.lstat(artifact.path)
      unless stat.file? && (stat.mode & 0o177).zero?
        raise ArgumentError, "spool must be a private regular file"
      end
      digest = Digest::SHA256.file(artifact.path).hexdigest
      raise ArgumentError, "spool digest does not match" unless digest == artifact.digest

      incoming = SQLite3::Database.new(
        TimeSeriesSchema.file_uri(artifact.path, immutable: true),
        flags: SQLite3::Constants::Open::READONLY | SQLite3::Constants::Open::URI
      )
      incoming.results_as_hash = true
      incoming.busy_timeout(5_000)
      incoming.execute("PRAGMA query_only = ON")
      objects = incoming.execute("SELECT name, type FROM sqlite_master WHERE type <> 'index' ORDER BY name")
      unless objects.map { |row| [row.fetch("name"), row.fetch("type")] } == SPOOL_COLUMNS.keys.sort.map { |name| [name, "table"] }
        raise ArgumentError, "invalid spool tables"
      end
      SPOOL_COLUMNS.each do |table, columns|
        actual = incoming.execute("PRAGMA table_info(#{table})").map { |row| row.fetch("name") }
        raise ArgumentError, "invalid spool columns" unless actual.sort == columns.sort
      end
      validate_manifest!(incoming, artifact)
      validate_spool_rows!(incoming)
      nil
    rescue SQLite3::Exception, JSON::ParserError, Errno::ENOENT, Errno::EACCES
      raise ArgumentError, "invalid or unreadable spool artifact"
    ensure
      incoming&.close
    end

    def validate_manifest!(incoming, artifact)
      expected = {
        "singleton_id" => 1, "instance_id" => artifact.instance_id,
        "import_key" => artifact.import_key, "import_mode" => artifact.import_mode.to_s,
        "series_count" => artifact.series_count, "observation_count" => artifact.observation_count,
        "sync_state_json" => JSON.generate(artifact.sync_state),
        "source_started_at_us" => TimeSeriesSchema.microseconds(artifact.source_started_at),
        "source_finished_at_us" => TimeSeriesSchema.microseconds(artifact.source_finished_at),
        "metadata_json" => JSON.generate(artifact.metadata)
      }
      rows = incoming.execute("SELECT * FROM spool_manifest LIMIT 2")
      raise ArgumentError, "invalid spool manifest" unless rows == [expected]
      unless incoming.get_first_value("SELECT COUNT(*) FROM spool_series") == artifact.series_count &&
             incoming.get_first_value("SELECT COUNT(*) FROM spool_observations") == artifact.observation_count
        raise ArgumentError, "invalid spool counts"
      end
    end

    def validate_spool_rows!(incoming)
      incoming.execute("SELECT * FROM spool_series") do |row|
        identifier!(row["series_key"], 256)
        identifier!(row["metric_key"], 128)
        case row["value_type"]
        when "numeric"
          identifier!(row["canonical_unit"], 64)
        when "categorical"
          raise ArgumentError, "categorical series has a unit" unless row["canonical_unit"].nil?
        else
          raise ArgumentError, "invalid spool value type"
        end
        TimeSeriesJSON.validate_dimensions!(JSON.parse(row.fetch("dimensions_json")))
      end
      duplicates = incoming.get_first_value(<<~SQL)
        SELECT 1 FROM spool_series GROUP BY series_key HAVING COUNT(*) > 1 LIMIT 1
      SQL
      duplicates ||= incoming.get_first_value(<<~SQL)
        SELECT 1 FROM spool_observations
        GROUP BY series_key, source_record_key HAVING COUNT(*) > 1 LIMIT 1
      SQL
      raise ArgumentError, "duplicate spool identity" if duplicates

      incoming.execute(<<~SQL) do |row|
        SELECT observation.*, series.value_type
        FROM spool_observations AS observation
        LEFT JOIN spool_series AS series ON series.series_key = observation.series_key
      SQL
        identifier!(row["source_record_key"], 512)
        start_us = row["observed_at_us"]
        end_us = row["ended_at_us"]
        unless start_us.is_a?(Integer) && (end_us.nil? || (end_us.is_a?(Integer) && end_us >= start_us))
          raise ArgumentError, "invalid spool observation timestamps"
        end
        numeric = row["numeric_value"]
        categorical = row["categorical_value"]
        case row["value_type"]
        when "numeric"
          unless (numeric.is_a?(Float) || numeric.is_a?(Integer)) && numeric.finite? && categorical.nil?
            raise ArgumentError, "observation does not match numeric series"
          end
        when "categorical"
          unless numeric.nil? && categorical.is_a?(String) && categorical.dup.force_encoding(Encoding::UTF_8).valid_encoding? &&
                 !categorical.strip.empty? && categorical.bytesize <= 1_024
            raise ArgumentError, "observation does not match categorical series"
          end
        else
          raise ArgumentError, "observation references an unknown series"
        end
        TimeSeriesJSON.validate_metadata!(JSON.parse(row.fetch("metadata_json")))
      end
    end

    def identifier!(value, maximum_bytes)
      unless value.is_a?(String) && value.dup.force_encoding(Encoding::UTF_8).valid_encoding? &&
             !value.strip.empty? && value.bytesize <= maximum_bytes && !value.match?(/[\x00-\x1f\x7f]/)
        raise ArgumentError, "invalid spool identifier"
      end
    end

    def validate_existing_series!(instance_id)
      mismatch = @database.get_first_value(<<~SQL, [instance_id])
        SELECT 1 FROM incoming.spool_series AS spool
        JOIN series AS stored ON stored.series_key = spool.series_key
        WHERE stored.adapter_instance_id = ?
          AND (stored.metric_key IS NOT spool.metric_key
            OR stored.value_type IS NOT spool.value_type
            OR stored.canonical_unit IS NOT spool.canonical_unit)
        LIMIT 1
      SQL
      raise ArgumentError, "series metric, value type and unit are immutable" if mismatch
    end

    def upsert_series(instance_id, committed_at_us)
      @database.execute(<<~SQL, [instance_id, committed_at_us, committed_at_us])
        INSERT INTO series (adapter_instance_id, series_key, metric_key, value_type,
                            canonical_unit, dimensions_json, created_at_us, updated_at_us)
        SELECT ?, series_key, metric_key, value_type, canonical_unit,
               cybort_normalized_dimensions(dimensions_json), ?, ?
        FROM incoming.spool_series WHERE true
        ON CONFLICT (adapter_instance_id, series_key) DO UPDATE SET
          dimensions_json = excluded.dimensions_json,
          updated_at_us = excluded.updated_at_us
        WHERE series.dimensions_json IS NOT excluded.dimensions_json
      SQL
    end

    def upsert_observations(instance_id, committed_at_us)
      @database.execute(<<~SQL, [committed_at_us, instance_id])
        INSERT INTO observations (series_id, source_record_key, observed_at_us, ended_at_us,
                                  numeric_value, categorical_value, ingested_at_us, metadata_json)
        SELECT stored.id, spool.source_record_key, spool.observed_at_us, spool.ended_at_us,
               spool.numeric_value, spool.categorical_value, ?, spool.metadata_json
        FROM incoming.spool_observations AS spool
        JOIN series AS stored ON stored.series_key = spool.series_key AND stored.adapter_instance_id = ?
        WHERE true
        ON CONFLICT (series_id, source_record_key) DO UPDATE SET
          observed_at_us = excluded.observed_at_us, ended_at_us = excluded.ended_at_us,
          numeric_value = excluded.numeric_value, categorical_value = excluded.categorical_value,
          ingested_at_us = excluded.ingested_at_us, metadata_json = excluded.metadata_json
      SQL
    end

    def replace_snapshot(instance_id)
      @database.execute(<<~SQL, [instance_id])
        DELETE FROM observations
        WHERE series_id IN (SELECT id FROM series WHERE adapter_instance_id = ?)
          AND NOT EXISTS (
            SELECT 1 FROM incoming.spool_observations AS spool
            JOIN series AS stored ON stored.series_key = spool.series_key
            WHERE stored.id = observations.series_id
              AND spool.source_record_key = observations.source_record_key
          )
      SQL
      @database.execute(<<~SQL, [instance_id])
        DELETE FROM series WHERE adapter_instance_id = ?
          AND NOT EXISTS (SELECT 1 FROM incoming.spool_series AS spool WHERE spool.series_key = series.series_key)
      SQL
    end

    def record_import(artifact, committed_at_us)
      stored_series_count = @database.get_first_value("SELECT COUNT(*) FROM series WHERE adapter_instance_id = ?", [artifact.instance_id])
      stored_observation_count = @database.get_first_value(<<~SQL, [artifact.instance_id])
        SELECT COUNT(*) FROM observations
        JOIN series ON series.id = observations.series_id WHERE series.adapter_instance_id = ?
      SQL
      @database.execute(<<~SQL, [artifact.instance_id, artifact.import_key, stored_series_count, stored_observation_count, committed_at_us])
        INSERT INTO time_series_instance_state (adapter_instance_id, latest_import_key,
          stored_series_count, stored_observation_count, updated_at_us) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT (adapter_instance_id) DO UPDATE SET
          latest_import_key = excluded.latest_import_key,
          stored_series_count = excluded.stored_series_count,
          stored_observation_count = excluded.stored_observation_count,
          updated_at_us = excluded.updated_at_us
      SQL
      binds = [artifact.instance_id, artifact.import_key, artifact.digest, artifact.import_mode.to_s,
               TimeSeriesSchema.microseconds(artifact.source_started_at), TimeSeriesSchema.microseconds(artifact.source_finished_at),
               committed_at_us, artifact.series_count, artifact.observation_count, stored_series_count,
               stored_observation_count, JSON.generate(artifact.sync_state), JSON.generate(artifact.metadata)]
      @database.execute(<<~SQL, binds)
        INSERT INTO time_series_imports (adapter_instance_id, import_key, artifact_digest, import_mode,
          source_started_at_us, source_finished_at_us, committed_at_us, imported_series_count,
          imported_observation_count, stored_series_count, stored_observation_count, sync_state_json, metadata_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
    end

    def attach_cleanup_failure(error, cleanup_error, phase:)
      existing = begin
        error.respond_to?(:cleanup_failures) ? error.cleanup_failures : []
      rescue Exception
        []
      end
      details = cleanup_failure_details(cleanup_error, phase: phase)
      failures = bounded_cleanup_failures(Array(existing) + details)
      begin
        error.instance_variable_set(:@cleanup_failures, failures)
        error.define_singleton_method(:cleanup_failures) { @cleanup_failures }
      rescue Exception # rubocop:disable Lint/RescueException -- preserve the active error if it cannot be annotated
        nil
      end
    end

    def cleanup_failure_details(error, phase:)
      [{
        phase: cleanup_failure_field(phase),
        error_class: cleanup_failure_field(error.class.name.to_s)
      }.freeze]
    end

    def bounded_cleanup_failures(failures)
      failures.first(CLEANUP_FAILURE_LIMIT).filter_map do |failure|
        next unless failure.respond_to?(:key?)

        phase = cleanup_failure_field(failure[:phase] || failure["phase"])
        error_class = cleanup_failure_field(failure[:error_class] || failure["error_class"])
        next unless phase && error_class

        { phase: phase, error_class: error_class }.freeze
      end.freeze
    end

    def cleanup_failure_field(value)
      return unless value.is_a?(String)

      field = value.dup.force_encoding(Encoding::UTF_8)
      return unless field.valid_encoding?

      bounded = +""
      field.each_char do |character|
        candidate = bounded + character
        break if candidate.bytesize > CLEANUP_FAILURE_FIELD_BYTES

        bounded << character
      end
      bounded.freeze
    end
  end
end
