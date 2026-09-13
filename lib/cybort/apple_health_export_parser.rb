require "nokogiri"

module Cybort
  AppleHealthParseSummary = Data.define(
    :exported_at, :export_xml_bytes, :top_level_record_count,
    :imported_record_count, :duplicate_record_count, :distinct_series_count,
    :family_counts
  )

  class AppleHealthExportParser
    RECORD_NAME = "Record"
    EXPORT_DATE_NAME = "ExportDate"
    ROOT_NAME = "HealthData"
    QUANTITY_PREFIX = "HKQuantityTypeIdentifier"
    CATEGORY_PREFIX = "HKCategoryTypeIdentifier"
    MAX_RECORD_ATTRIBUTES = 64
    MAX_METADATA_ENTRIES = 128
    MAX_FIELD_BYTES = 4 * 1024
    MAX_RECORD_BYTES = 64 * 1024
    MAX_PARSER_DEPTH = 64
    MAX_NAME_BYTES = 256
    MAX_NON_RECORD_TEXT_BYTES = 1 * 1024 * 1024
    MAX_PRE_EXPORT_BYTES = 8 * 1024 * 1024
    MAX_DTD_DECLARATIONS = 10_000
    MAX_DTD_BYTES = 1 * 1024 * 1024
    MAX_DISTINCT_SERIES = 100_000
    ALLOWED_TOP_LEVEL = %w[
      ExportDate Me Record Correlation Workout ActivitySummary ClinicalRecord
      Electrocardiogram Audiogram VisionPrescription WorkoutRoute ClinicalDocument
    ].freeze
    UNSUPPORTED_TOP_LEVEL_FAMILIES = {
      "Workout" => :workout, "ActivitySummary" => :activity_summary,
      "Correlation" => :correlation, "ClinicalRecord" => :clinical_record,
      "Electrocardiogram" => :electrocardiogram, "Audiogram" => :audiogram,
      "VisionPrescription" => :vision_prescription, "WorkoutRoute" => :workout_route,
      "ClinicalDocument" => :clinical_document
    }.freeze
    SPECIALIZED_RECORD_CHILDREN = %w[
      HeartRateMotionContext WorkoutEvent WorkoutStatistics InstantaneousBeats
      Electrocardiogram Audiogram ClinicalRecord
    ].freeze

    def probe(io)
      reader = CountingIO.new(io)
      handler = Handler.new(mode: :probe)
      parse_reader(reader, handler)
    rescue ProbeComplete
      handler.probe_result
    end

    def parse(io, spool_writer:)
      reader = CountingIO.new(io)
      handler = Handler.new(mode: :parse, spool_writer: spool_writer)
      parse_reader(reader, handler)
      handler.finish!
      AppleHealthParseSummary.new(
        exported_at: handler.exported_at,
        export_xml_bytes: reader.bytes_read,
        top_level_record_count: handler.top_level_record_count,
        imported_record_count: handler.imported_record_count,
        duplicate_record_count: handler.duplicate_record_count,
        distinct_series_count: handler.distinct_series_count,
        family_counts: handler.family_counts.dup.freeze
      )
    rescue AppleHealthError
      raise
    rescue Nokogiri::XML::SyntaxError, EncodingError, ArgumentError
      raise AppleHealthError.new(phase: :parse, category: :malformed_xml)
    end

    private

    def parse_reader(reader, handler)
      parser = Nokogiri::XML::SAX::Parser.new(handler)
      parser.parse_io(PrologGuard.new(reader)) do |context|
        context.recovery = false
        context.replace_entities = false
      end
      handler.finish_probe! if handler.probe_mode?
      handler
    rescue AppleHealthError
      raise
    rescue ProbeComplete
      raise
    rescue PrologGuard::GuardError => error
      raise AppleHealthError.new(
        phase: :parse, category: error.category, limit_name: error.limit_name
      )
    rescue Nokogiri::XML::SyntaxError, EncodingError
      raise AppleHealthError.new(phase: :parse, category: :malformed_xml)
    rescue StandardError
      raise AppleHealthError.new(phase: :parse, category: :malformed_xml)
    end

    class CountingIO
      attr_reader :bytes_read

      def initialize(io)
        @io = io
        @bytes_read = 0
      end

      def read(length = nil, outbuf = nil)
        chunk = if length.nil?
                   @io.read
                 elsif outbuf.nil?
                   @io.read(length)
                 else
                   @io.read(length, outbuf)
                 end
        @bytes_read += chunk.bytesize if chunk
        chunk
      end

      def eof?
        @io.eof?
      end
    end

    class PrologGuard
      GuardError = Class.new(StandardError) do
        attr_reader :category, :limit_name

        def initialize(category, limit_name = nil)
          @category = category
          @limit_name = limit_name
        end
      end

      def initialize(io)
        @io = io
        @before_export_date = true
        @buffer = +"".b
        @doctype_seen = false
        @dtd_declaration_count = 0
        @dtd_bytes = 0
      end

      def read(length = nil, outbuf = nil)
        chunk = if length.nil?
                   @io.read
                 elsif outbuf.nil?
                   @io.read(length)
                 else
                   @io.read(length, outbuf)
                 end
        inspect_chunk(chunk) if chunk && !chunk.empty?
        chunk
      end

      def eof?
        @io.eof?
      end

      private

      def inspect_chunk(chunk)
        return unless @before_export_date

        @buffer << chunk
        if @buffer.bytesize > MAX_PRE_EXPORT_BYTES
          raise GuardError.new(:record_resource_limit, :pre_export_date_bytes)
        end
        reject_forbidden_prolog!
        if export_date_marker?
          @before_export_date = false
          @buffer.clear
        end
      end

      def reject_forbidden_prolog!
        return unless @before_export_date

        if @buffer.scan(/<!DOCTYPE\b/i).length > 1
          raise GuardError.new(:unsafe_xml)
        end
        raise GuardError.new(:unsafe_xml) if @buffer.match?(/<!DOCTYPE\s+(?!HealthData\b)/i)
        raise GuardError.new(:unsafe_xml) if @buffer.match?(/\b(?:SYSTEM|PUBLIC|ENTITY)\b|%/i)
        raise GuardError.new(:unsafe_xml) if @buffer.match?(/<\?xml-stylesheet\b|<\?xinclude\b/i)
        doctype = @buffer.match(/<!DOCTYPE\s+HealthData(?:\s*\[[\s\S]*?\]\s*)?>/im)
        return unless doctype

        return if @doctype_seen

        body = doctype[0]
        @doctype_seen = true
        declarations = body.scan(/<!\s*([A-Za-z][A-Za-z0-9_-]*)/)
        declarations = declarations.reject { |declaration| declaration.fetch(0).casecmp?("DOCTYPE") }
        @dtd_declaration_count += declarations.length
        @dtd_bytes += body.bytesize
        if @dtd_declaration_count > MAX_DTD_DECLARATIONS
          raise GuardError.new(:record_resource_limit, :dtd_declarations)
        end
        if @dtd_bytes > MAX_DTD_BYTES
          raise GuardError.new(:record_resource_limit, :dtd_bytes)
        end
        declarations.each do |declaration|
          next if %w[DOCTYPE ELEMENT ATTLIST].include?(declaration.fetch(0).upcase)

          raise GuardError.new(:unsafe_xml)
        end
      end

      def export_date_marker?
        index = 0
        length = @buffer.bytesize
        while index < length
          if starts_with_at?("<!--", index)
            closing = @buffer.index("-->", index + 4)
            return false unless closing
            index = closing + 3
          elsif starts_with_at?("<![CDATA[", index)
            closing = @buffer.index("]]>", index + 9)
            return false unless closing
            index = closing + 3
          elsif starts_with_at?("<?", index)
            closing = @buffer.index("?>", index + 2)
            return false unless closing
            index = closing + 2
          elsif starts_with_at?("<!DOCTYPE", index) || starts_with_at?("<!doctype", index)
            closing = doctype_end(index)
            return false unless closing
            index = closing + 1
          elsif [34, 39].include?(@buffer.getbyte(index))
            quote = @buffer.getbyte(index)
            closing = index + 1
            closing += 1 while closing < length && @buffer.getbyte(closing) != quote
            return false if closing >= length
            index = closing + 1
          elsif starts_with_at?("<ExportDate", index)
            following = @buffer.getbyte(index + 11)
            return true if following.nil? || [9, 10, 13, 32, 47, 62].include?(following)
            index += 1
          else
            index += 1
          end
        end
        false
      end

      def starts_with_at?(text, index)
        @buffer.byteslice(index, text.bytesize) == text
      end

      def doctype_end(index)
        cursor = index + 2
        bracket_depth = 0
        quote = nil
        while cursor < @buffer.bytesize
          byte = @buffer.getbyte(cursor)
          if quote
            quote = nil if byte == quote
          elsif byte == 34 || byte == 39
            quote = byte
          elsif byte == 91
            bracket_depth += 1
          elsif byte == 93
            bracket_depth -= 1 if bracket_depth.positive?
          elsif byte == 62 && bracket_depth.zero?
            return cursor
          end
          cursor += 1
        end
        nil
      end
    end

    class ProbeComplete < StandardError; end
    private_constant :ProbeComplete

    class Handler < Nokogiri::XML::SAX::Document
      attr_reader :exported_at, :top_level_record_count, :imported_record_count,
                  :duplicate_record_count, :distinct_series_count, :family_counts

      def initialize(mode:, spool_writer: nil)
        @mode = mode
        @spool_writer = spool_writer
        @depth = 0
        @root_seen = false
        @root_closed = false
        @document_started = false
        @document_finished = false
        @xml_declaration_seen = false
        @export_date_count = 0
        @record = nil
        @series_keys = {}
        @family_counts = Hash.new(0)
        @top_level_record_count = 0
        @imported_record_count = 0
        @duplicate_record_count = 0
        @distinct_series_count = 0
        @non_record_text_bytes = 0
        @unsupported_depth = 0
      end

      def probe_mode?
        @mode == :probe
      end

      def start_document
        @document_started = true
      end

      def end_document
        @document_finished = true
      end

      def xmldecl(version, encoding, _standalone)
        raise_error(:invalid_export_root) if @xml_declaration_seen
        @xml_declaration_seen = true
        raise_error(:malformed_xml) unless version.to_s == "1.0" && encoding.to_s.upcase == "UTF-8"
      end

      def start_element(name, attrs = [])
        name = name.to_s
        validate_name!(name)
        @depth += 1
        raise_error(:record_resource_limit, :parser_depth) if @depth > AppleHealthExportParser::MAX_PARSER_DEPTH
        if @depth == 1
          raise_error(:invalid_export_root) unless name == ROOT_NAME
          raise_error(:invalid_export_root) if @root_seen || @root_closed
          @root_seen = true
          return
        end
        if @depth == 2
          start_top_level(name, attrs)
        elsif @record
          start_record_child(name, attrs)
        end
      end

      def start_element_namespace(name, attrs = [], prefix = nil, uri = nil, namespaces = nil)
        raise_error(:unsupported_export_schema) unless prefix.to_s.empty? && uri.to_s.empty? && Array(namespaces).empty?
        start_element(name, attrs)
      end

      def end_element(name)
        validate_name!(name.to_s)
        @unsupported_depth -= 1 if @unsupported_depth.positive?
        if @record && name.to_s == RECORD_NAME && @depth == @record.fetch(:depth)
          finish_record
        end
        @root_closed = true if @depth == 1 && name.to_s == ROOT_NAME
        @depth -= 1
      end

      def characters(text)
        account_text_bytes!(text)
      end

      def cdata_block(text)
        account_text_bytes!(text)
      end

      def processing_instruction(_name, _content)
        raise_error(:unsafe_xml)
      end

      def reference(name)
        raise_error(:unsafe_xml) unless %w[amp apos gt lt quot].include?(name.to_s)
      end

      def external_subset(*_args)
        raise_error(:unsafe_xml)
      end

      def warning(*_args)
        raise_error(:malformed_xml)
      end

      def error(*_args)
        raise_error(:malformed_xml)
      end

      def fatal_error(*_args)
        raise_error(:malformed_xml)
      end

      def finish_probe!
        raise_error(:invalid_export_root) unless @root_seen && @export_date_count == 1
        raise ProbeComplete
      end

      def probe_result
        { exported_at: @exported_at }
      end

      def finish!
        raise_error(:invalid_export_root) unless @document_started && @document_finished && @root_seen && @root_closed
        raise_error(:invalid_export_root) unless @xml_declaration_seen
        raise_error(:invalid_export_root) unless @export_date_count == 1
        raise_error(:unsupported_export_schema) if @top_level_record_count.positive? && @imported_record_count.zero?
        self
      end

      private

      def start_top_level(name, attrs)
        if name == EXPORT_DATE_NAME
          parse_export_date(attrs)
          raise ProbeComplete if probe_mode?
        elsif name == RECORD_NAME
          raise_error(:invalid_export_root) unless @export_date_count == 1
          @top_level_record_count += 1
          @record = { depth: @depth, attributes: {}, metadata: [], invalid: false,
                      unsupported: false, bytes: name.bytesize }
          @record[:attributes] = attribute_hash(attrs, record: @record)
        elsif !ALLOWED_TOP_LEVEL.include?(name)
          raise_error(:unsupported_export_schema)
        else
          family = UNSUPPORTED_TOP_LEVEL_FAMILIES[name]
          @family_counts[family] += 1 if family
        end
      end

      def start_record_child(name, attrs)
        if @unsupported_depth.positive?
          @unsupported_depth += 1
          return
        end
        if @depth == @record.fetch(:depth) + 1 && name == "MetadataEntry"
          @record[:metadata_count] = @record.fetch(:metadata_count, 0) + 1
          raise_error(:record_resource_limit, :metadata_entries) if @record.fetch(:metadata_count) > AppleHealthExportParser::MAX_METADATA_ENTRIES
          account_record_bytes!(name.bytesize)
          pairs = attribute_hash(attrs, record: @record)
          key = pairs["key"]
          value = pairs["value"]
          raise_error(:invalid_record) unless key && value
          @record.fetch(:metadata) << [key, value]
        elsif @depth == @record.fetch(:depth) + 1 && SPECIALIZED_RECORD_CHILDREN.include?(name)
          @record[:unsupported] = true
          @family_counts[:specialized] += 1
          @unsupported_depth = 1
        else
          raise_error(:unsupported_export_schema)
        end
      end

      def finish_record
        record = @record
        @record = nil
        return if record.fetch(:invalid)
        return if record.fetch(:unsupported)

        attributes = record.fetch(:attributes)
        type = attributes["type"]
        value_type = value_type_for(type)
        if value_type.nil?
          @family_counts[:unsupported] += 1
          return
        end
        @family_counts[value_type] += 1
        attributes["value_type"] = value_type
        normalized = AppleHealthCanonical.normalize_record(
          attributes: attributes, metadata_entries: record.fetch(:metadata)
        )
        begin
          @spool_writer.register_series(
            series_key: normalized.series_key, metric_key: normalized.metric_key,
            value_type: normalized.value_type, canonical_unit: normalized.canonical_unit,
            dimensions: normalized.dimensions
          )
          status = @spool_writer.add_observation(
            series_key: normalized.series_key, source_record_key: normalized.source_record_key,
            observed_at: normalized.observed_at, ended_at: normalized.ended_at,
            numeric_value: normalized.numeric_value, categorical_value: normalized.categorical_value,
            metadata: normalized.metadata
          )
        rescue StandardError
          raise_error(:spool_failure)
        end
        if status == :duplicate
          @duplicate_record_count += 1
        else
          @imported_record_count += 1
        end
        unless @series_keys.key?(normalized.series_key)
          raise_error(:record_resource_limit, :distinct_series) if @distinct_series_count >= AppleHealthExportParser::MAX_DISTINCT_SERIES
          @series_keys[normalized.series_key] = true
          @distinct_series_count += 1
        end
      rescue AppleHealthError
        raise
      rescue AppleHealthCanonical::InvalidTimestampError
        raise_error(:invalid_timestamp)
      rescue ArgumentError, KeyError, TypeError
        raise_error(:invalid_record)
      end

      def parse_export_date(attrs)
        @export_date_count += 1
        raise_error(:invalid_export_root) unless @export_date_count == 1
        raise_error(:invalid_export_root) unless @xml_declaration_seen
        values = attribute_hash(attrs)
        value = values["value"]
        raise_error(:invalid_export_root) unless value
        @exported_at = AppleHealthCanonical.parse_timestamp(value, field: :export_date).time
      rescue AppleHealthCanonical::InvalidTimestampError
        raise_error(:invalid_export_root)
      end

      def value_type_for(type)
        return :numeric if type.is_a?(String) && type.start_with?(AppleHealthExportParser::QUANTITY_PREFIX)
        return :categorical if type.is_a?(String) && type.start_with?(AppleHealthExportParser::CATEGORY_PREFIX)

        nil
      end

      def attribute_hash(attrs, record: nil)
        if record && attrs.length > AppleHealthExportParser::MAX_RECORD_ATTRIBUTES
          raise_error(:record_resource_limit, :record_attributes)
        end
        attrs.each_with_object({}) do |attribute, result|
          key, value = if attribute.is_a?(Array) && attribute.length == 2
                         attribute
                       elsif attribute.respond_to?(:localname)
                         [attribute.localname, attribute.value]
                       else
                         [nil, nil]
                       end
          raise_error(record ? :invalid_record : :invalid_export_root) unless key && value
          key = key.to_s
          value = value.to_s
          validate_name!(key)
          if value.bytesize > AppleHealthExportParser::MAX_FIELD_BYTES
            raise_error(:record_resource_limit, :field_bytes) if record
            raise_error(:invalid_export_root)
          end
          account_record_bytes!(key.bytesize + value.bytesize) if record
          raise_error(:invalid_record) if record && result.key?(key)
          result[key] = begin
            AppleHealthCanonical.normalized_string(value, key, AppleHealthExportParser::MAX_FIELD_BYTES)
          rescue ArgumentError
            raise_error(record ? :invalid_record : :invalid_export_root)
          end
        end
      end

      def validate_name!(name)
        valid = name.is_a?(String) && name.valid_encoding? && !name.empty? &&
                name.bytesize <= AppleHealthExportParser::MAX_NAME_BYTES &&
                !name.match?(/[\x00-\x1f\x7f]/)
        return if valid

        raise_error(:record_resource_limit, :name_bytes)
      end

      def account_record_bytes!(bytes)
        @record[:bytes] += bytes
        raise_error(:record_resource_limit, :record_bytes) if @record[:bytes] > AppleHealthExportParser::MAX_RECORD_BYTES
      end

      def account_text_bytes!(text)
        bytes = text.to_s.bytesize
        if @record && @unsupported_depth.zero?
          account_record_bytes!(bytes)
        elsif @record.nil?
          @non_record_text_bytes += bytes
          raise_error(:record_resource_limit, :non_record_text_bytes) if @non_record_text_bytes > AppleHealthExportParser::MAX_NON_RECORD_TEXT_BYTES
        end
      end

      def raise_error(category, limit_name = nil)
        phase = category == :invalid_record ? :normalize : :parse
        raise AppleHealthError.new(phase: phase, category: category, limit_name: limit_name)
      end
    end
  end
end
