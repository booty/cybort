#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"
require "sqlite3"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "cybort"

module Cybort
  module TimeSeriesBenchmark
    DEFAULT_OBSERVATIONS = 1_500_000
    INSTANCE_ID = "synthetic-benchmark"
    IMPORT_KEY = "synthetic-import-1"
    SERIES_KEY = "synthetic-temperature"
    METRIC_KEY = "temperature"
    CANONICAL_UNIT = "Cel"
    OBSERVATION_START = Time.utc(2026, 1, 1)
    RANGE_LIMIT = 1_000

    ValidationError = Class.new(StandardError)

    module_function

    def run(argv)
      options = parse_options(argv)
      output_root = prepare_output!(options.fetch(:output))
      canonical_path = File.join(output_root, "cybort-timeseries.sqlite3")
      spool_directory = File.join(output_root, "spools")
      FileUtils.mkdir_p(spool_directory)
      File.chmod(0o700, spool_directory)

      observations = options.fetch(:observations)
      source_finished_at = OBSERVATION_START + [observations - 1, 1].max
      persistence = nil
      reader = nil
      spool_writer = nil
      artifact = nil
      spool_duration_seconds = nil
      import_duration_seconds = nil

      begin
        commit_time = source_finished_at + 1
        clock = -> { commit_time }
        persistence = TimeSeriesPersistence.new(canonical_path, clock: clock)
        persistence.setup!

        factory = TimeSeriesSpoolFactory.new(directory: spool_directory, clock: clock)
        spool_started = monotonic_time
        spool_writer = factory.open(
          instance_id: INSTANCE_ID,
          import_key: IMPORT_KEY,
          import_mode: :append,
          source_started_at: OBSERVATION_START
        )
        spool_writer.register_series(
          series_key: SERIES_KEY,
          metric_key: METRIC_KEY,
          value_type: :numeric,
          canonical_unit: CANONICAL_UNIT,
          dimensions: { "fixture" => "synthetic" }
        )

        observations.times do |index|
          spool_writer.add_observation(
            series_key: SERIES_KEY,
            source_record_key: format("observation-%08d", index),
            observed_at: OBSERVATION_START + index,
            numeric_value: ((index * 37) % 100_000) / 100.0,
            metadata: {}
          )
        end
        artifact = spool_writer.finalize(
          sync_state: { "cursor" => IMPORT_KEY },
          source_finished_at: source_finished_at,
          metadata: { "synthetic" => true }
        )
        spool_duration_seconds = elapsed_seconds(spool_started)

        spool_bytes = File.size(artifact.path)
        import_started = monotonic_time
        receipt = persistence.import(artifact)
        import_duration_seconds = elapsed_seconds(import_started)
        unless receipt.is_a?(TimeSeriesImportReceipt)
          raise "time-series persistence returned an invalid receipt"
        end

        canonical_bytes = File.size(canonical_path)
        canonical_wal_bytes = file_size_or_zero("#{canonical_path}-wal")

        persistence.close
        persistence = nil
        reader = TimeSeriesReader.new(canonical_path)
        series = reader.series_for(instance_id: INSTANCE_ID, limit: 1).fetch(0)
        query_results = run_queries(reader, canonical_path, series.id, observations)
        sqlite_version = query_results.delete(:sqlite_version)
        rss = rss_measurements

        summary = {
          observations: observations,
          series: artifact.series_count,
          imported_observations: receipt.imported_observation_count,
          stored_observations: receipt.stored_observation_count,
          spool_digest_sha256: artifact.digest,
          spool_construction_seconds: spool_duration_seconds,
          canonical_import_seconds: import_duration_seconds,
          peak_rss_bytes: rss.fetch(:peak_rss_bytes),
          peak_rss_measurement_kind: rss.fetch(:peak_rss_measurement_kind),
          current_rss_bytes: rss.fetch(:current_rss_bytes),
          current_rss_measurement_kind: rss.fetch(:current_rss_measurement_kind),
          sizes_bytes: {
            spool: spool_bytes,
            canonical: canonical_bytes,
            canonical_wal: canonical_wal_bytes
          },
          query_results: query_results.fetch(:results),
          query_plans: query_results.fetch(:plans),
          ruby_version: RUBY_VERSION,
          sqlite_version: sqlite_version,
          schema_version: TimeSeriesSchema::VERSION
        }
        puts JSON.generate(summary)
        0
      ensure
        spool_writer.abort unless spool_writer.nil? || spool_writer.closed?
        FileUtils.rm_f(artifact.path) if artifact
        reader&.close
        persistence&.close
      end
    end

    def parse_options(argv)
      options = { observations: DEFAULT_OBSERVATIONS, output: nil }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: benchmark_time_series.rb --output DIRECTORY [--observations COUNT]"
        opts.on("--observations COUNT", Integer, "Synthetic observation count (default: #{DEFAULT_OBSERVATIONS})") do |count|
          options[:observations] = count
        end
        opts.on("--output DIRECTORY", "Empty directory for benchmark databases and temporary spools") do |directory|
          options[:output] = directory
        end
        opts.on("--help", "Show this help") do
          puts opts
          exit 0
        end
      end
      parser.parse!(argv)
      raise ValidationError, "--output is required" unless options[:output]
      raise ValidationError, "--observations must be positive" unless options[:observations].positive?
      raise ValidationError, "unexpected arguments" unless argv.empty?

      options
    end

    def prepare_output!(directory)
      root = File.expand_path(directory.to_s)
      if File.exist?(root) || File.symlink?(root)
        stat = File.lstat(root)
        raise ValidationError, "output must be a directory" unless stat.directory? && !stat.symlink?
        raise ValidationError, "output directory must be empty" unless Dir.empty?(root)
      else
        FileUtils.mkdir_p(root)
      end
      File.chmod(0o700, root)
      root
    rescue Errno::EACCES, Errno::ENOTDIR
      raise ValidationError, "output directory is not usable"
    end

    def run_queries(reader, canonical_path, series_id, observations)
      late_start_offset = [observations - RANGE_LIMIT, 0].max
      late_end_offset = [observations - 1, 0].max
      windows = [
        {
          name: "early_window",
          started_at: OBSERVATION_START,
          ended_at: OBSERVATION_START + [RANGE_LIMIT - 1, late_end_offset].min,
          order: :ascending,
          direction: "ASC",
          limit: 100
        },
        {
          name: "late_window",
          started_at: OBSERVATION_START + late_start_offset,
          ended_at: OBSERVATION_START + late_end_offset,
          order: :descending,
          direction: "DESC",
          limit: RANGE_LIMIT
        }
      ]
      results = []
      plans = []
      database = open_read_only_database(canonical_path)
      begin
        sqlite_version = database.get_first_value("SELECT sqlite_version()")
        windows.each do |window|
          started = monotonic_time
          rows = reader.observations_for(
            series_ids: [series_id],
            started_at: window.fetch(:started_at),
            ended_at: window.fetch(:ended_at),
            limit: window.fetch(:limit),
            order: window.fetch(:order)
          )
          results << {
            "name" => window.fetch(:name),
            "rows" => rows.length,
            "limit" => window.fetch(:limit),
            "duration_seconds" => elapsed_seconds(started)
          }

          plan_rows = database.execute(
            explain_sql(window.fetch(:direction)),
            [series_id, TimeSeriesSchema.microseconds(window.fetch(:started_at)),
             TimeSeriesSchema.microseconds(window.fetch(:ended_at)), window.fetch(:limit)]
          )
          plans << {
            "name" => window.fetch(:name),
            "details" => plan_rows.map { |row| row.fetch(3).to_s.byteslice(0, 256) }
          }
        end
        { results: results, plans: plans, sqlite_version: sqlite_version }
      ensure
        database.close
      end
    end

    def explain_sql(direction)
      <<~SQL
        EXPLAIN QUERY PLAN
        SELECT * FROM observations
        WHERE series_id IN (?)
          AND observed_at_us >= ? AND observed_at_us <= ?
        ORDER BY observed_at_us #{direction}, series_id #{direction}, source_record_key #{direction}
        LIMIT ?
      SQL
    end

    def open_read_only_database(path)
      database = SQLite3::Database.new(
        TimeSeriesSchema.file_uri(path),
        flags: SQLite3::Constants::Open::READONLY | SQLite3::Constants::Open::URI
      )
      database.busy_timeout(5_000)
      database.execute("PRAGMA query_only = ON")
      database.execute("PRAGMA foreign_keys = ON")
      database
    rescue Exception
      database&.close
      raise
    end

    def file_size_or_zero(path)
      File.file?(path) ? File.size(path) : 0
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_seconds(started)
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end

    def rss_measurements
      peak = if (bytes = getrusage_rss_bytes)
        { bytes: bytes, kind: "getrusage_maxrss" }
      elsif (bytes = proc_peak_rss_bytes)
        { bytes: bytes, kind: "proc_vmhwm" }
      end
      current = if (bytes = ps_rss_bytes)
        { bytes: bytes, kind: "ps_rss_current" }
      end
      {
        peak_rss_bytes: peak&.fetch(:bytes),
        peak_rss_measurement_kind: peak&.fetch(:kind),
        current_rss_bytes: current&.fetch(:bytes),
        current_rss_measurement_kind: current&.fetch(:kind)
      }
    end

    # Returns a best-effort resident-set high-water measurement in bytes.
    # getrusage is preferred when Ruby exposes it; Linux /proc supplies a true
    # high-water mark. Measurement is optional, so an unavailable or malformed
    # value is nil and must not make the benchmark fail or add unbounded output.
    def getrusage_rss_bytes
      return unless Process.respond_to?(:getrusage)

      raw = Process.getrusage.maxrss
      return unless raw.is_a?(Numeric) && raw.finite? && raw >= 0

      RUBY_PLATFORM.include?("darwin") ? raw.to_i : raw.to_i * 1024
    rescue StandardError, NotImplementedError
      nil
    end

    def proc_peak_rss_bytes
      return unless File.file?("/proc/self/status")

      File.foreach("/proc/self/status") do |line|
        next unless line.start_with?("VmHWM:")

        value, unit = line.split
        return value.to_i * 1024 if value&.match?(/\A\d+\z/) && unit == "kB"
      end
      nil
    rescue StandardError
      nil
    end

    def ps_rss_bytes
      # ps reports current RSS, not a process high-water mark. Keep it separate
      # from peak_rss_bytes so the summary never labels a point measurement as a
      # peak.
      output, status = Open3.capture2("ps", "-o", "rss=", "-p", Process.pid.to_s)
      return unless status.success?

      rss_kib = output.each_line.map(&:strip).find { |line| line.match?(/\A\d+\z/) }
      rss_kib ? rss_kib.to_i * 1024 : nil
    rescue StandardError
      nil
    end
  end
end

exit_code = begin
  Cybort::TimeSeriesBenchmark.run(ARGV)
rescue OptionParser::ParseError, Cybort::TimeSeriesBenchmark::ValidationError
  warn "time-series benchmark validation failed"
  2
rescue StandardError => error
  warn "time-series benchmark failed (#{error.class})"
  1
end
exit(exit_code)
