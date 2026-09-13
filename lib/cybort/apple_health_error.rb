module Cybort
  class AppleHealthError < SourceError
    PHASES = %i[directory acquisition zip probe parse normalize spool persistence acknowledgement].freeze
    CATEGORIES = %i[
      directory_unavailable directory_unsafe too_many_archives archive_size_limit
      archive_changed_during_acquisition archive_acquisition_timeout invalid_zip
      encrypted_zip unsupported_compression zip_resource_limit missing_export_xml
      duplicate_export_xml invalid_export_root unsafe_xml malformed_xml
      unsupported_export_schema invalid_record record_resource_limit
      invalid_timestamp spool_failure time_series_persistence_failure
      receipt_acknowledgement_pending normalizer_migration_required
    ].freeze
    LIMIT_NAMES = %i[
      archive_count compressed_bytes entry_count entry_name_bytes
      total_uncompressed_bytes export_xml_bytes expansion_ratio distinct_series
      record_attributes metadata_entries field_bytes record_bytes parser_depth
      dtd_declarations dtd_bytes non_record_text_bytes pre_export_date_bytes
    ].freeze
    COUNT_KEYS = %i[
      candidate_count entry_count supported_record_count unsupported_record_count
      imported_record_count duplicate_record_count distinct_series_count
      compressed_bytes uncompressed_bytes export_xml_bytes
    ].freeze

    attr_reader :safe_metadata

    def initialize(phase:, category:, candidate_ordinal: nil, limit_name: nil, counts: {})
      phase = phase.to_sym if phase.respond_to?(:to_sym)
      category = category.to_sym if category.respond_to?(:to_sym)
      raise ArgumentError, "unsupported Apple Health error phase" unless PHASES.include?(phase)
      raise ArgumentError, "unsupported Apple Health error category" unless CATEGORIES.include?(category)
      unless candidate_ordinal.nil? || (candidate_ordinal.is_a?(Integer) && candidate_ordinal >= 0)
        raise ArgumentError, "candidate ordinal must be a nonnegative integer"
      end
      limit_name = limit_name.to_sym if limit_name.respond_to?(:to_sym)
      raise ArgumentError, "unsupported Apple Health limit" if limit_name && !LIMIT_NAMES.include?(limit_name)

      normalized_counts = normalize_counts(counts)
      @safe_metadata = { source: "apple_health", phase: phase, category: category }
      @safe_metadata[:candidate_ordinal] = candidate_ordinal unless candidate_ordinal.nil?
      @safe_metadata[:limit_name] = limit_name unless limit_name.nil?
      @safe_metadata[:counts] = normalized_counts unless normalized_counts.empty?
      @safe_metadata.freeze

      super("Apple Health #{phase} failed (#{category})")
    end

    private

    def normalize_counts(counts)
      return {}.freeze unless counts.is_a?(Hash)

      counts.each_with_object({}) do |(key, value), normalized|
        next unless normalized.length < 32

        key = key.to_sym if key.respond_to?(:to_sym)
        next unless COUNT_KEYS.include?(key)
        next unless value.is_a?(Integer) && value >= 0

        normalized[key] = value
      end.freeze
    end
  end
end
