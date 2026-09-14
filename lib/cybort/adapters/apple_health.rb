module Cybort
  module Adapters
    class AppleHealth < Base
      def self.validate_configuration!(instance)
        options = instance.options || {}
        unless options.keys.map(&:to_sym).sort == [:directory]
          raise ConfigurationError, "apple_health options must contain only directory"
        end
        unless instance.num_items_to_fetch == 1
          raise ConfigurationError, "apple_health num_items_to_fetch must be 1"
        end
        if instance.retention_ttl_minutes || instance.hard_expiry_ttl_minutes
          raise ConfigurationError, "apple_health does not support retention TTL settings"
        end

        directory = options[:directory]
        unless directory.is_a?(String) && directory.valid_encoding? &&
               directory.bytesize.between?(3, 4_096) &&
               (directory.start_with?("/", "~/")) &&
               !directory.match?(/[\x00-\x1f\x7f$`*?\[\]{}]/)
          raise ConfigurationError, "apple_health directory must be an absolute or ~/ path"
        end
        nil
      end

      def initialize(instance:, context:, clock:, monotonic_clock:, spool_factory:,
                     archive_acquirer: nil, zip_inspector: nil, parser_factory: nil,
                     **_unused)
        @instance = instance
        @context = context
        @clock = clock
        @monotonic_clock = monotonic_clock
        @spool_factory = spool_factory
        @archive_acquirer = archive_acquirer
        @zip_inspector = zip_inspector
        @parser_factory = parser_factory
      end

      attr_reader :instance, :context, :clock, :monotonic_clock, :spool_factory

      def fetch(force_fetch: false, fetch_mode: nil, planned_at: nil)
        planned_at ||= clock.call
        fetch_mode ||= force_fetch || !fresh_cache_at?(planned_at) ? :remote : :cached
        started_at = clock.call
        best = nil
        begin
          if fetch_mode == :cached
            return TimeSeriesFetchResult.cached(
              instance_id: instance.id, sync_state: context[:sync_state],
              started_at: started_at, finished_at: clock.call,
              series_count: context.fetch(:series_count, 0),
              observation_count: context.fetch(:observation_count, 0)
            )
          end
          raise ArgumentError, "invalid Apple Health fetch mode" unless fetch_mode == :remote
          validate_normalizer_state!

          paths = archive_acquirer.candidate_paths(directory: instance.options.fetch(:directory))
          candidate_count = paths.length
          best_priority = nil
          paths.each_with_index do |path, index|
            current = nil
            begin
              current = archive_acquirer.acquire(source_path: path, candidate_ordinal: index + 1)
              candidate = zip_inspector.inspect(current)
              priority = candidate_priority(candidate)
              if best.nil? || (priority <=> best_priority) == 1
                archive_acquirer.release(best.acquired_archive) if best
                best = candidate
                best_priority = priority
              else
                archive_acquirer.release(current)
              end
            rescue Exception
              archive_acquirer.release(current) if current
              raise
            end
          end

          unless best
            raise AppleHealthError.new(phase: :directory, category: :missing_export_xml,
                                       counts: { candidate_count: candidate_count })
          end

          if known_import_key?(best)
            return TimeSeriesFetchResult.unchanged(
              instance_id: instance.id, started_at: started_at, finished_at: clock.call,
              series_count: context.fetch(:series_count, 0),
              observation_count: context.fetch(:observation_count, 0),
              metadata: { "candidate_count" => candidate_count, "unchanged" => true }
            )
          end

          import_unseen_candidate(best, candidate_count: candidate_count, started_at: started_at)
        ensure
          @archive_acquirer&.release(best.acquired_archive) if best
        end
      rescue AppleHealthError => error
        TimeSeriesFetchResult.failure(
          instance_id: instance.id, error: error, started_at: started_at || clock.call,
          finished_at: clock.call, metadata: safe_metadata(error)
        )
      rescue StandardError
        error = AppleHealthError.new(phase: :parse, category: :spool_failure)
        TimeSeriesFetchResult.failure(
          instance_id: instance.id, error: error, started_at: started_at || clock.call,
          finished_at: clock.call, metadata: safe_metadata(error)
        )
      end

      private

      def archive_acquirer
        return @archive_acquirer if @archive_acquirer

        temp_directory = @spool_factory.respond_to?(:directory) ? @spool_factory.directory : nil
        raise ArgumentError, "Apple Health archive acquirer is required" unless temp_directory

        @archive_acquirer = AppleHealthArchiveAcquirer.new(temp_directory: temp_directory,
                                                            wall_clock: clock,
                                                            monotonic_clock: monotonic_clock)
      end

      def zip_inspector
        @zip_inspector ||= AppleHealthZipInspector.new(parser_factory: -> { AppleHealthExportParser.new })
      end

      def parser
        factory = @parser_factory || -> { AppleHealthExportParser.new }
        factory.call
      end

      def validate_normalizer_state!
        state = context[:sync_state]
        return if state.nil? || state.empty?

        version = state.is_a?(Hash) && (state["normalizer_version"] || state[:normalizer_version])
        unless version == 1
          raise AppleHealthError.new(phase: :normalize, category: :normalizer_migration_required)
        end
      end

      def safe_metadata(error)
        return {} unless error.respond_to?(:safe_metadata)

        stringify_metadata(error.safe_metadata)
      end

      def stringify_metadata(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, child), copy| copy[key.to_s] = stringify_metadata(child) }
        when Array
          value.map { |child| stringify_metadata(child) }
        when Symbol
          value.to_s
        else
          value
        end
      end

      def candidate_priority(candidate)
        [candidate_seen?(candidate) ? 0 : 1, candidate.exported_at.utc.to_r, archive_sha256(candidate)]
      end

      def select_candidate(candidates)
        Array(candidates).max_by { |candidate| candidate_priority(candidate) }
      end

      def archive_sha256(candidate)
        archive = candidate.respond_to?(:acquired_archive) ? candidate.acquired_archive : candidate
        archive.archive_sha256
      end

      def known_import_key?(candidate)
        import_keys = context.fetch(:import_keys, [])
        import_keys.include?("apple-health-import-v1:#{archive_sha256(candidate)}")
      end

      def candidate_seen?(candidate)
        if candidate.respond_to?(:seen)
          candidate.seen
        else
          known_import_key?(candidate)
        end
      end

      def import_unseen_candidate(candidate, candidate_count:, started_at:)
        archive = candidate.acquired_archive
        File.chmod(0o400, archive.path)
        import_key = "apple-health-import-v1:#{archive.archive_sha256}"
        finished_at = nil
        summary = nil
        stream_result = nil
        artifact = @spool_factory.open(
          instance_id: instance.id, import_key: import_key, import_mode: :append,
          source_started_at: started_at
        ) do |writer|
          stream_result = zip_inspector.with_export_stream(candidate) do |io|
            summary = parser.parse(io, spool_writer: writer)
          end
          finished_at = clock.call
          sync_state = {
            "state_version" => 1,
            "normalizer_version" => 1,
            "last_imported_exported_at" => candidate.exported_at.utc.iso8601(6),
            "last_imported_archive_sha256" => archive.archive_sha256,
            "last_imported_export_xml_sha256" => stream_result.export_xml_sha256,
            "latest_import_key" => import_key
          }
          writer.finalize(
            sync_state: sync_state, source_finished_at: finished_at,
            metadata: artifact_metadata(candidate, stream_result, summary)
          )
        end
        metadata = {
          "candidate_count" => candidate_count,
          "imported" => summary.imported_record_count,
          "duplicate" => summary.duplicate_record_count,
          "supported" => summary.family_counts.values_at(:numeric, :categorical).sum,
          "unsupported" => summary.family_counts.reject { |key, _| %i[numeric categorical].include?(key) }.values.sum
        }
        TimeSeriesFetchResult.success(
          instance_id: instance.id, artifact: artifact, sync_state: artifact.sync_state,
          started_at: started_at, finished_at: finished_at, metadata: metadata,
          source_fetched: true
        )
      end

      def artifact_metadata(candidate, stream_result, summary)
        {
          "normalizer_version" => 1,
          "archive_sha256" => candidate.acquired_archive.archive_sha256,
          "compressed_bytes" => candidate.acquired_archive.compressed_bytes,
          "export_xml_sha256" => stream_result.export_xml_sha256,
          "exported_at" => candidate.exported_at.utc.iso8601(6),
          "export_xml_bytes" => stream_result.export_xml_bytes,
          "top_level_record_count" => summary.top_level_record_count,
          "imported_record_count" => summary.imported_record_count,
          "duplicate_record_count" => summary.duplicate_record_count,
          "distinct_series_count" => summary.distinct_series_count,
          "family_counts" => summary.family_counts.transform_keys(&:to_s),
          "inventory" => stringify_metadata(candidate.inventory || {})
        }
      end
    end
  end
end
