#!/usr/bin/env ruby
# frozen_string_literal: true

require "cgi"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "time"
require "zip"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "cybort"

module Cybort
  module AppleHealthBenchmark
    DEFAULT_RECORDS = 1_500_000
    DEFAULT_OVERLAP_PERCENT = 99
    INSTANCE_ID = "apple-health-benchmark"
    OBSERVATION_START = Time.utc(2026, 1, 1)
    EXPORT_DATES = [Time.utc(2026, 9, 12, 12), Time.utc(2026, 9, 13, 12)].freeze
    RANGE_LIMIT = 1_000
    SERIES = [
      { type: "HKQuantityTypeIdentifierHeartRate", unit: "count/min", category: false },
      { type: "HKQuantityTypeIdentifierStepCount", unit: "count", category: false },
      { type: "HKQuantityTypeIdentifierBodyMass", unit: "kg", category: false },
      { type: "HKCategoryTypeIdentifierSleepAnalysis", unit: nil, category: true }
    ].freeze

    module_function

    def run(argv)
      options = parse_options(argv)
      output_root = prepare_output!(options.fetch(:output))
      source_directory = File.join(output_root, "source-archives")
      private_directory = File.join(output_root, "private-copies")
      spool_directory = File.join(output_root, "spools")
      [source_directory, private_directory, spool_directory].each do |directory|
        FileUtils.mkdir_p(directory)
        File.chmod(0o700, directory)
      end

      first_archive_path = File.join(source_directory, "export-01.zip")
      second_archive_path = File.join(source_directory, "export-02.zip")
      first_generation = measure { write_archive(first_archive_path, records: options.fetch(:records), mode: :first, overlap_percent: options.fetch(:overlap_percent)) }
      second_generation = measure { write_archive(second_archive_path, records: options.fetch(:records), mode: :second, overlap_percent: options.fetch(:overlap_percent)) }

      canonical_path = File.join(output_root, "cybort-timeseries.sqlite3")
      clock = -> { Time.utc(2026, 9, 13, 13) }
      persistence = TimeSeriesPersistence.new(canonical_path, clock: clock)
      persistence.setup!
      spool_factory = TimeSeriesSpoolFactory.new(directory: spool_directory, clock: clock)
      acquirer = AppleHealthArchiveAcquirer.new(temp_directory: private_directory, timeout_seconds: 600)
      inspector = AppleHealthZipInspector.new(parser_factory: -> { AppleHealthExportParser.new })

      first = import_archive(
        first_archive_path, archive_acquirer: acquirer, inspector: inspector,
        spool_factory: spool_factory, persistence: persistence, clock: clock,
        label: "first"
      )
      reader = TimeSeriesReader.new(canonical_path)
      first_series = reader.series_for(instance_id: INSTANCE_ID, limit: SERIES.length)
      stable_count = (options.fetch(:records) * options.fetch(:overlap_percent) / 100.0).ceil
      sample_limit = [stable_count, 3].min
      first_samples = sample_ingestion_times(
        reader, first_series.map(&:id), records: options.fetch(:records),
        sample_limit: sample_limit
      )

      second = import_archive(
        second_archive_path, archive_acquirer: acquirer, inspector: inspector,
        spool_factory: spool_factory, persistence: persistence, clock: clock,
        label: "second"
      )
      second_samples = sample_ingestion_times(
        reader, first_series.map(&:id), records: options.fetch(:records),
        sample_limit: sample_limit
      )
      overlap_stability = compare_ingestion_times(first_samples, second_samples)
      final_context = reader.context_for(instance_id: INSTANCE_ID)
      query_measurements = run_queries(
        reader, canonical_path, first_series.map(&:id), records: options.fetch(:records)
      )
      sqlite_version = query_measurements.delete(:sqlite_version)
      sizes = {
        "first_archive" => File.size(first_archive_path),
        "second_archive" => File.size(second_archive_path),
        "first_archive_copy" => first.fetch(:archive_copy_bytes),
        "second_archive_copy" => second.fetch(:archive_copy_bytes),
        "first_spool" => first.fetch(:spool_bytes),
        "second_spool" => second.fetch(:spool_bytes),
        "database" => file_size_or_zero(canonical_path),
        "wal" => file_size_or_zero("#{canonical_path}-wal")
      }

      summary = {
        "records" => options.fetch(:records),
        "overlap_percent" => options.fetch(:overlap_percent),
        "series_cardinality" => final_context.fetch(:series_count),
        "first_archive" => archive_summary(first),
        "second_archive" => archive_summary(second),
        "first_import" => import_summary(first),
        "second_import" => import_summary(second).merge(
          "overlap_sample_count" => overlap_stability.fetch(:sample_count),
          "overlap_ingested_at_stable" => overlap_stability.fetch(:stable)
        ).merge(synthetic_case_summary(
          records: options.fetch(:records), overlap_percent: options.fetch(:overlap_percent)
        )),
        "durations_seconds" => {
          "first_archive_generation" => first_generation,
          "second_archive_generation" => second_generation,
          "first_archive_copy" => first.fetch(:durations).fetch(:archive_copy),
          "second_archive_copy" => second.fetch(:durations).fetch(:archive_copy),
          "first_zip_probe" => first.fetch(:durations).fetch(:zip_probe),
          "second_zip_probe" => second.fetch(:durations).fetch(:zip_probe),
          "first_zip_stream_sax_spool" => first.fetch(:durations).fetch(:zip_stream_sax_spool),
          "second_zip_stream_sax_spool" => second.fetch(:durations).fetch(:zip_stream_sax_spool),
          "first_canonical_import" => first.fetch(:durations).fetch(:canonical_import),
          "second_canonical_import" => second.fetch(:durations).fetch(:canonical_import)
        },
        "sizes_bytes" => sizes,
        "distinct_series" => final_context.fetch(:series_count),
        "stored_observations" => final_context.fetch(:observation_count),
        "queries" => query_measurements.fetch(:results),
        "query_plans" => query_measurements.fetch(:plans),
        "rss_bytes" => rss_measurement.fetch(:bytes),
        "rss_measurement_kind" => rss_measurement.fetch(:kind),
        "current_rss_bytes" => current_rss_measurement.fetch(:bytes),
        "current_rss_measurement_kind" => current_rss_measurement.fetch(:kind),
        "ruby_version" => RUBY_VERSION,
        "sqlite_version" => sqlite_version,
        "rubyzip_version" => gem_version("rubyzip"),
        "nokogiri_version" => gem_version("nokogiri"),
        "schema_version" => TimeSeriesSchema::VERSION
      }
      puts JSON.generate(summary)
      0
    ensure
      reader&.close
      persistence&.close
      acquirer&.cleanup_orphans!
    end

    def parse_options(argv)
      options = { records: DEFAULT_RECORDS, overlap_percent: DEFAULT_OVERLAP_PERCENT, output: nil }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: benchmark_apple_health.rb --output DIRECTORY [--records COUNT] [--overlap-percent PERCENT]"
        opts.on("--records COUNT", Integer, "Synthetic record count (default: #{DEFAULT_RECORDS})") do |count|
          options[:records] = count
        end
        opts.on("--overlap-percent PERCENT", Integer, "Stable first-archive identity percentage (default: #{DEFAULT_OVERLAP_PERCENT})") do |percent|
          options[:overlap_percent] = percent
        end
        opts.on("--output DIRECTORY", "Empty directory for benchmark archives, database, and spools") do |directory|
          options[:output] = directory
        end
        opts.on("--help", "Show this help") do
          puts opts
          exit 0
        end
      end
      parser.parse!(argv)
      raise ArgumentError, "--output is required" unless options[:output]
      raise ArgumentError, "--records must be at least 4" unless options.fetch(:records) >= 4
      unless (0..100).cover?(options.fetch(:overlap_percent))
        raise ArgumentError, "--overlap-percent must be between 0 and 100"
      end
      raise ArgumentError, "unexpected arguments" unless argv.empty?

      options
    end

    def prepare_output!(directory)
      root = File.expand_path(directory.to_s)
      if File.exist?(root) || File.symlink?(root)
        stat = File.lstat(root)
        raise ArgumentError, "output must be a directory" unless stat.directory? && !stat.symlink?
        raise ArgumentError, "output directory must be empty" unless Dir.empty?(root)
      else
        FileUtils.mkdir_p(root)
      end
      File.chmod(0o700, root)
      root
    rescue Errno::EACCES, Errno::ENOTDIR
      raise ArgumentError, "output directory is not usable"
    end

    def write_archive(path, records:, mode:, overlap_percent:)
      stable_count = (records * overlap_percent / 100.0).ceil
      Zip::File.open(path, create: true) do |zip|
        zip.get_output_stream("export.xml") do |io|
          io.write(xml_header(EXPORT_DATES.fetch(mode == :first ? 0 : 1)))
          if mode == :first
            records.times { |index| write_record(io, index) }
          else
            stable_count.times { |index| write_record(io, index) }
            corrected_index = stable_count < records ? stable_count : nil
            write_record(io, corrected_index, variant: :corrected) if corrected_index
            write_record(io, 0, variant: :duplicate) if stable_count.positive?
            write_record(io, records + 1, variant: :inserted)
          end
          io.write("</HealthData>\n")
        end
      end
      File.chmod(0o600, path)
      path
    end

    def xml_header(exported_at)
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <HealthData>
          <ExportDate value="#{xml_escape(exported_at.strftime("%Y-%m-%d %H:%M:%S +0000"))}"/>
      XML
    end

    def write_record(io, index, variant: :normal)
      definition = SERIES.fetch(index % SERIES.length)
      start_time = OBSERVATION_START + index
      attributes = {
        "type" => definition.fetch(:type),
        "value" => record_value(definition, index, variant),
        "creationDate" => start_time.strftime("%Y-%m-%d %H:%M:%S +0000"),
        "startDate" => start_time.strftime("%Y-%m-%d %H:%M:%S +0000"),
        "endDate" => (start_time + 1).strftime("%Y-%m-%d %H:%M:%S +0000"),
        "sourceName" => "Cybort Benchmark",
        "sourceVersion" => "1.0",
        "device" => "Synthetic Device"
      }
      attributes["unit"] = definition.fetch(:unit) unless definition.fetch(:category)
      encoded = attributes.map { |key, value| "#{key}=\"#{xml_escape(value)}\"" }.join(" ")
      # Keep inter-record text empty.  The production parser intentionally
      # bounds cumulative non-record text, so millions of records should not
      # spend that budget on synthetic indentation/newlines.
      io.write("<Record #{encoded}/>")
    end

    def record_value(definition, index, variant)
      if definition.fetch(:category)
        variant == :corrected ? "HKCategoryValueSleepAnalysisAwake" : "HKCategoryValueSleepAnalysisAsleep"
      else
        value = ((index * 37) % 100_000) / 100.0
        value += 1.0 if variant == :corrected
        format("%.2f", value)
      end
    end

    def xml_escape(value)
      CGI.escapeHTML(value.to_s)
    end

    def import_archive(source_path, archive_acquirer:, inspector:, spool_factory:, persistence:, clock:, label:)
      durations = {}
      copy_started = monotonic_time
      acquired = archive_acquirer.acquire(source_path: source_path, candidate_ordinal: label == "first" ? 1 : 2)
      durations[:archive_copy] = elapsed_seconds(copy_started)
      candidate = nil
      artifact = nil
      parse_summary = nil
      stream_result = nil
      begin
        probe_started = monotonic_time
        candidate = inspector.inspect(acquired)
        durations[:zip_probe] = elapsed_seconds(probe_started)
        import_key = "apple-health-import-v1:#{acquired.archive_sha256}"
        source_started_at = clock.call
        stream_started = monotonic_time
        artifact = spool_factory.open(
          instance_id: INSTANCE_ID, import_key: import_key, import_mode: :append,
          source_started_at: source_started_at
        ) do |writer|
          stream_result = inspector.with_export_stream(candidate) do |io|
            parse_summary = AppleHealthExportParser.new.parse(io, spool_writer: writer)
          end
          finished_at = clock.call
          writer.finalize(
            sync_state: {
              "state_version" => 1, "normalizer_version" => 1,
              "latest_import_key" => import_key
            },
            source_finished_at: finished_at,
            metadata: {
              "benchmark" => true, "label" => label,
              "archive_sha256" => acquired.archive_sha256,
              "export_xml_sha256" => stream_result.export_xml_sha256,
              "exported_at" => candidate.exported_at.utc.iso8601(6),
              "export_xml_bytes" => stream_result.export_xml_bytes,
              "top_level_record_count" => parse_summary.top_level_record_count,
              "imported_record_count" => parse_summary.imported_record_count,
              "duplicate_record_count" => parse_summary.duplicate_record_count,
              "distinct_series_count" => parse_summary.distinct_series_count,
              "family_counts" => parse_summary.family_counts.transform_keys(&:to_s)
            }
          )
        end
        durations[:zip_stream_sax_spool] = elapsed_seconds(stream_started)
        spool_bytes = File.size(artifact.path)
        import_started = monotonic_time
        receipt = persistence.import(artifact)
        durations[:canonical_import] = elapsed_seconds(import_started)
        {
          acquired: acquired, candidate: candidate, artifact: artifact, receipt: receipt,
          parse_summary: parse_summary, stream_result: stream_result,
          archive_copy_bytes: acquired.compressed_bytes, spool_bytes: spool_bytes,
          durations: durations
        }
      ensure
        FileUtils.rm_f(artifact.path) if artifact&.path
        archive_acquirer.release(acquired) if acquired
      end
    end

    def archive_summary(result)
      {
        "sha256" => result.fetch(:acquired).archive_sha256,
        "compressed_bytes" => result.fetch(:acquired).compressed_bytes,
        "exported_at" => result.fetch(:candidate).exported_at.utc.iso8601(6),
        "export_xml_sha256" => result.fetch(:stream_result).export_xml_sha256,
        "export_xml_bytes" => result.fetch(:stream_result).export_xml_bytes,
        "top_level_record_count" => result.fetch(:parse_summary).top_level_record_count,
        "imported_record_count" => result.fetch(:parse_summary).imported_record_count,
        "duplicate_record_count" => result.fetch(:parse_summary).duplicate_record_count,
        "distinct_series_count" => result.fetch(:parse_summary).distinct_series_count,
        "family_counts" => result.fetch(:parse_summary).family_counts.transform_keys(&:to_s)
      }
    end

    def import_summary(result)
      receipt = result.fetch(:receipt)
      {
        "imported" => receipt.imported_observation_count,
        "inserted" => receipt.inserted_observation_count,
        "duplicate" => receipt.duplicate_observation_count,
        "unchanged" => receipt.unchanged_observation_count,
        "changed" => receipt.changed_observation_count,
        "deleted" => receipt.deleted_observation_count,
        "stored_series" => receipt.stored_series_count,
        "stored_observations" => receipt.stored_observation_count
      }
    end

    def synthetic_case_summary(records:, overlap_percent:)
      stable_count = (records * overlap_percent / 100.0).ceil
      {
        "stable_records" => stable_count,
        "corrected_records" => stable_count < records ? 1 : 0,
        "omitted_records" => [records - stable_count - 1, 0].max,
        "duplicate_records" => stable_count.positive? ? 1 : 0,
        "inserted_records" => 1
      }
    end

    def sample_ingestion_times(reader, series_ids, records:, sample_limit:)
      return {} if sample_limit.zero?

      rows = reader.observations_for(
        series_ids: series_ids, started_at: OBSERVATION_START,
        ended_at: OBSERVATION_START + [records - 1, 0].max,
        limit: sample_limit, order: :ascending
      )
      rows.to_h { |row| [row.source_record_key, row.ingested_at] }
    end

    def compare_ingestion_times(before, after)
      shared = before.keys & after.keys
      { sample_count: shared.length, stable: shared.any? && shared.all? { |key| before.fetch(key) == after.fetch(key) } }
    end

    def run_queries(reader, canonical_path, series_ids, records:)
      windows = [
        {
          "name" => "early_window", started_at: OBSERVATION_START,
          ended_at: OBSERVATION_START + [RANGE_LIMIT - 1, records - 1].min,
          order: :ascending, direction: "ASC", limit: 100
        },
        {
          "name" => "late_window", started_at: OBSERVATION_START + [records - RANGE_LIMIT, 0].max,
          ended_at: OBSERVATION_START + [records - 1, 0].max,
          order: :descending, direction: "DESC", limit: RANGE_LIMIT
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
            series_ids: series_ids, started_at: window.fetch(:started_at),
            ended_at: window.fetch(:ended_at), limit: window.fetch(:limit), order: window.fetch(:order)
          )
          results << {
            "name" => window.fetch("name"), "rows" => rows.length,
            "limit" => window.fetch(:limit), "duration_seconds" => elapsed_seconds(started)
          }
          plan_rows = database.execute(
            explain_sql(series_ids.length, window.fetch(:direction)),
            series_ids + [TimeSeriesSchema.microseconds(window.fetch(:started_at)),
                          TimeSeriesSchema.microseconds(window.fetch(:ended_at)), window.fetch(:limit)]
          )
          details = plan_rows.map { |row| row.fetch(3).to_s.byteslice(0, 256) }
          plans << {
            "name" => window.fetch("name"), "rows" => plan_rows.map { |row| row.map(&:to_s) },
            "details" => details,
            "uses_series_time_index" => details.any? { |detail| detail.include?("idx_observations_series_time") }
          }
        end
        { results: results, plans: plans, sqlite_version: sqlite_version }
      ensure
        database.close
      end
    end

    def explain_sql(series_count, direction)
      <<~SQL
        EXPLAIN QUERY PLAN
        SELECT * FROM observations
        WHERE series_id IN (#{(["?"] * series_count).join(", ")})
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
    rescue Exception # rubocop:disable Lint/RescueException -- close a partially opened read-only handle
      database&.close
      raise
    end

    def measure
      started = monotonic_time
      yield
      elapsed_seconds(started)
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_seconds(started)
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end

    def file_size_or_zero(path)
      File.file?(path) ? File.size(path) : 0
    end

    def gem_version(name)
      Gem.loaded_specs[name]&.version&.to_s || "unavailable"
    end

    def rss_measurement
      if Process.respond_to?(:getrusage)
        raw = Process.getrusage.maxrss
        return { bytes: darwin_platform? ? raw.to_i : raw.to_i * 1024, kind: "getrusage_maxrss" } if raw.is_a?(Numeric) && raw.finite? && raw >= 0
      end
      if File.file?("/proc/self/status")
        File.foreach("/proc/self/status") do |line|
          next unless line.start_with?("VmHWM:")

          value, unit = line.split
          return { bytes: value.to_i * 1024, kind: "proc_vmhwm" } if value&.match?("\\A\\d+\\z") && unit == "kB"
        end
      end
      { bytes: nil, kind: "unavailable" }
    rescue StandardError, NotImplementedError
      { bytes: nil, kind: "unavailable" }
    end

    def current_rss_measurement
      output, status = Open3.capture2("ps", "-o", "rss=", "-p", Process.pid.to_s)
      return { bytes: output.to_i * 1024, kind: "ps_rss_current" } if status.success? && output.match?("\\A\\s*\\d+\\s*\\z")

      { bytes: nil, kind: "unavailable" }
    rescue StandardError
      { bytes: nil, kind: "unavailable" }
    end

    def darwin_platform?
      RUBY_PLATFORM.include?("darwin")
    end
  end
end

exit_code = begin
  Cybort::AppleHealthBenchmark.run(ARGV)
rescue OptionParser::ParseError, ArgumentError
  warn "Apple Health benchmark validation failed"
  2
rescue StandardError => error
  warn "Apple Health benchmark failed (#{error.class}: #{error.message})"
  1
end
exit(exit_code)
