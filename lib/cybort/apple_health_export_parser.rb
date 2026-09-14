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
    SAFE_DTD_DECLARATION_NAMES = %w[DOCTYPE ELEMENT ATTLIST].freeze
    QUOTE_BYTES = [34, 39].freeze
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
      HeartRateMotionContext HeartRateVariabilityMetadataList WorkoutEvent WorkoutStatistics InstantaneousBeats
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
      guard = PrologGuard.new(reader)
      handler.prolog_guard = guard
      parser.parse_io(guard) do |context|
        context.recovery = false
        context.replace_entities = false
      end
      raise_guard_error(guard.guard_error) if guard.guard_error
      handler.finish_probe! if handler.probe_mode?
      handler
    rescue AppleHealthError
      raise_guard_error(guard.guard_error) if guard&.guard_error
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

    def raise_guard_error(error)
      raise AppleHealthError.new(
        phase: :parse, category: error.category, limit_name: error.limit_name
      )
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
      attr_reader :guard_error

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
        @pre_export_bytes = 0
        @doctype_seen = false
        @dtd_declaration_count = 0
        @dtd_bytes = 0
        reset_markup
      end

      def read(length = nil, outbuf = nil)
        chunk = if length.nil?
                   @io.read
                 else
                   read_up_to(length)
                 end
        inspect_chunk(chunk) if chunk && !chunk.empty?
        finish! if chunk.nil?
        if outbuf && chunk
          outbuf.replace(chunk)
          outbuf
        else
          chunk
        end
      rescue GuardError => error
        # Nokogiri treats exceptions raised by an IO callback as a generic
        # parser error and may swallow the original exception. Retain the
        # typed guard failure so parse_reader can restore the safe category.
        @guard_error ||= error
        nil
      end

      def eof?
        @io.eof?
      end

      private

      def read_up_to(length)
        result = +"".b
        while result.bytesize < length
          chunk = @io.read(length - result.bytesize)
          break if chunk.nil? || chunk.empty?

          result << chunk
        end
        result.empty? ? nil : result
      end

      def inspect_chunk(chunk)
        return unless @before_export_date

        chunk.each_byte do |byte|
          @pre_export_bytes += 1
          if @pre_export_bytes > MAX_PRE_EXPORT_BYTES
            raise GuardError.new(:record_resource_limit, :pre_export_date_bytes)
          end

          inspect_byte(byte)
          break unless @before_export_date
        end
      end

      def inspect_byte(byte)
        if @markup_state.nil?
          start_markup if byte == 60 # <
          return
        end

        @markup << byte.chr
        case @markup_state
        when :unknown
          classify_markup
        when :bang
          classify_bang_markup
        when :comment
          reset_markup if @markup.end_with?("-->")
        when :cdata
          reset_markup if @markup.end_with?("]]>")
        when :processing_instruction
          reset_markup if @markup.end_with?("?>")
        when :doctype
          inspect_doctype_byte(byte)
        when :declaration
          finish_declaration if declaration_closed?
        when :tag
          inspect_tag_byte(byte)
        end
      end

      def start_markup
        @markup = +"<".b
        @markup_state = :unknown
        @tag_name = +"".b
        @tag_quote = nil
        @doctype_bracket_depth = 0
        @doctype_quote = nil
        @doctype_comment = false
        @doctype_marker = +"".b
      end

      def reset_markup
        @markup = nil
        @markup_state = nil
        @tag_name = nil
        @tag_quote = nil
        @doctype_bracket_depth = 0
        @doctype_quote = nil
        @doctype_comment = false
        @doctype_marker = nil
      end

      def classify_markup
        return unless @markup.bytesize >= 2

        case @markup.getbyte(1)
        when 33 # !
          @markup_state = :bang
          classify_bang_markup
        when 63 # ?
          @markup_state = :processing_instruction
        else
          @markup_state = :tag
          @tag_name = @markup.getbyte(1).chr
        end
      end

      def classify_bang_markup
        if @markup.start_with?("<!--")
          @markup_state = :comment
        elsif @markup.start_with?("<![CDATA[")
          @markup_state = :cdata
        elsif @markup.downcase.start_with?("<!doctype")
          raise GuardError.new(:unsafe_xml) if @doctype_seen

          @doctype_seen = true
          @markup_state = :doctype
          @dtd_bytes += @markup.bytesize
        elsif possible_markup_prefix?("<!--") || possible_markup_prefix?("<![CDATA[") ||
              possible_markup_prefix?("<!DOCTYPE")
          # Keep collecting until the markup kind is unambiguous. This is
          # deliberately scoped to markup beginning with "<!"; text and
          # attribute values are never inspected as prolog declarations.
        else
          @markup_state = :declaration
          finish_declaration if declaration_closed?
        end
      end

      def possible_markup_prefix?(token)
        token.downcase.start_with?(@markup.downcase)
      end

      def inspect_doctype_byte(byte)
        account_dtd_byte!

        if @doctype_comment
          append_doctype_marker(byte)
          if @doctype_marker.end_with?("-->")
            @doctype_comment = false
            @doctype_marker.clear
          end
          return
        end

        if @doctype_quote
          @doctype_quote = nil if byte == @doctype_quote
          @doctype_marker.clear
          return
        end

        if QUOTE_BYTES.include?(byte)
          @doctype_quote = byte
          @doctype_marker.clear
        else
          append_doctype_marker(byte)
          if @doctype_marker.end_with?("<!--")
            @doctype_comment = true
            @doctype_marker.clear
            return
          end
        end

        unless @doctype_quote
          if byte == 91 # [
            @doctype_bracket_depth += 1
          elsif byte == 93 # ]
            @doctype_bracket_depth -= 1 if @doctype_bracket_depth.positive?
          elsif byte == 62 && @doctype_bracket_depth.zero? # >
            validate_doctype!(@markup)
            reset_markup
            return
          end
        end
      end

      def append_doctype_marker(byte)
        @doctype_marker << byte.chr
        @doctype_marker = @doctype_marker.byteslice(-4, 4) if @doctype_marker.bytesize > 4
      end

      def account_dtd_byte!
        @dtd_bytes += 1
        raise GuardError.new(:record_resource_limit, :dtd_bytes) if @dtd_bytes > MAX_DTD_BYTES
      end

      def finish!
        return unless @markup_state == :doctype

        # A DOCTYPE that never reached its closing delimiter is unsafe even if
        # Nokogiri later reports it as merely malformed. In particular, do not
        # let an unfinished quote or comment suppress DTD validation.
        raise GuardError.new(:unsafe_xml)
      end

      def inspect_tag_byte(byte)
        if @tag_quote
          @tag_quote = nil if byte == @tag_quote
          return
        end
        if QUOTE_BYTES.include?(byte)
          @tag_quote = byte
          return
        end

        if @tag_name && @tag_name.bytesize.positive? && @tag_name.bytesize < MAX_NAME_BYTES &&
           ![9, 10, 13, 32, 47, 62].include?(byte)
          @tag_name << byte.chr
          return
        end

        if @tag_name == EXPORT_DATE_NAME && [9, 10, 13, 32, 47, 62].include?(byte)
          @before_export_date = false
          reset_markup
          return
        end
        reset_markup if byte == 62 # >
      end

      def declaration_closed?
        @markup.end_with?(">")
      end

      def finish_declaration
        return unless declaration_closed?
        raise GuardError.new(:unsafe_xml) if @markup.match?(/\A<!\s*ENTITY\b/i)

        reset_markup
      end

      def validate_doctype!(body)
        clean = strip_quoted_and_comments(body)
        match = clean.match(/\A<!DOCTYPE\s+([A-Za-z_:][A-Za-z0-9_.:-]*)([\s\S]*)>\z/i)
        raise GuardError.new(:unsafe_xml) unless match && match[1].casecmp?(ROOT_NAME)
        raise GuardError.new(:unsafe_xml) if clean.match?(/\b(?:SYSTEM|PUBLIC|ENTITY)\b|%/i)

        declarations = clean.scan(/<!\s*([A-Za-z][A-Za-z0-9_-]*)/)
        declarations = declarations.reject { |declaration| declaration.fetch(0).casecmp?("DOCTYPE") }
        @dtd_declaration_count += declarations.length
        if @dtd_declaration_count > MAX_DTD_DECLARATIONS
          raise GuardError.new(:record_resource_limit, :dtd_declarations)
        end
        declarations.each do |declaration|
          next if SAFE_DTD_DECLARATION_NAMES.include?(declaration.fetch(0).upcase)

          raise GuardError.new(:unsafe_xml)
        end
      end

      def strip_quoted_and_comments(body)
        result = +"".b
        index = 0
        quote = nil
        while index < body.bytesize
          if quote
            quote = nil if body.getbyte(index) == quote
            result << 32
            index += 1
          elsif body.byteslice(index, 4) == "<!--"
            closing = body.index("-->", index + 4)
            raise GuardError.new(:unsafe_xml) unless closing

            (closing + 3 - index).times { result << 32 }
            index = closing + 3
          elsif QUOTE_BYTES.include?(body.getbyte(index))
            quote = body.getbyte(index)
            result << 32
            index += 1
          else
            result << body.getbyte(index)
            index += 1
          end
        end
        result.force_encoding(Encoding::UTF_8)
      end
    end

    class ProbeComplete < StandardError; end
    private_constant :ProbeComplete

    class Handler < Nokogiri::XML::SAX::Document
      attr_reader :exported_at, :top_level_record_count, :imported_record_count,
                  :duplicate_record_count, :distinct_series_count, :family_counts
      attr_writer :prolog_guard

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
        raise_parser_error(:malformed_xml)
      end

      def error(*_args)
        raise_parser_error(:malformed_xml)
      end

      def fatal_error(*_args)
        raise_parser_error(:malformed_xml)
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
          # Apple exports pretty-print a small amount of indentation around
          # every top-level element. Bound meaningful free text here without
          # rejecting that structural whitespace at Apple-scale record counts.
          @non_record_text_bytes += text.each_byte.count do |byte|
            byte != 9 && byte != 10 && byte != 13 && byte != 32
          end
          raise_error(:record_resource_limit, :non_record_text_bytes) if @non_record_text_bytes > AppleHealthExportParser::MAX_NON_RECORD_TEXT_BYTES
        end
      end

      def raise_error(category, limit_name = nil)
        phase = category == :invalid_record ? :normalize : :parse
        raise AppleHealthError.new(phase: phase, category: category, limit_name: limit_name)
      end

      def raise_parser_error(category)
        guard_error = @prolog_guard&.guard_error
        if guard_error
          raise_error(guard_error.category, guard_error.limit_name)
        else
          raise_error(category)
        end
      end
    end
  end
end
