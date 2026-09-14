require "test_helper"
require "time"

class AppleHealthExportParserTest < Minitest::Test
  def setup
    @root = File.realpath(Dir.mktmpdir)
    @spools = File.join(@root, "spools")
    @parser = Cybort::AppleHealthExportParser.new
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_parses_zero_record_export
    summary = parse_fixture("export_empty.xml")

    assert_equal 0, summary.top_level_record_count
    assert_equal 0, summary.imported_record_count
    assert_equal 0, summary.distinct_series_count
  end

  def test_streams_quantity_and_category_records_into_spool
    summary, artifact = parse_fixture_with_artifact("export_overlap_one.xml")

    assert_equal 2, summary.top_level_record_count
    assert_equal 2, summary.imported_record_count
    assert_equal 2, summary.distinct_series_count
    assert_equal 2, artifact.observation_count
    artifact_path = artifact.path
    FileUtils.rm_f(artifact_path)
  end

  def test_rejects_unsupported_only_export
    error = assert_raises(Cybort::AppleHealthError) { parse_fixture("export_unsupported_only.xml") }

    assert_equal :unsupported_export_schema, error.safe_metadata.fetch(:category)
  end

  def test_accepts_internal_health_data_dtd
    summary = parse_fixture("export_entities.xml")

    assert_equal Time.new(2026, 9, 11, 12, 0, 0, "-0400"), summary.exported_at
    assert_equal 0, summary.top_level_record_count
  end

  def test_rejects_unknown_top_level_wrapper_and_malformed_xml
    schema_error = assert_raises(Cybort::AppleHealthError) { parse_fixture("export_schema_drift.xml") }
    malformed_error = assert_raises(Cybort::AppleHealthError) { parse_fixture("export_malformed.xml") }
    assert_equal :unsupported_export_schema, schema_error.safe_metadata.fetch(:category)
    assert_equal :malformed_xml, malformed_error.safe_metadata.fetch(:category)
  end

  def test_ignores_structural_whitespace_between_top_level_elements
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <HealthData>
        <ExportDate value="2026-09-12 12:00:00 +0000"/>
    XML
    xml << (" \n" * 600_000)
    xml << <<~XML
        <Record type="HKQuantityTypeIdentifierHeartRate" value="72" unit="count/min" creationDate="2026-09-12 11:59:00 +0000" startDate="2026-09-12 11:59:00 +0000" endDate="2026-09-12 12:00:00 +0000"/>
      </HealthData>
    XML

    summary = parse_xml(xml)

    assert_equal 1, summary.imported_record_count
    assert_equal 1, summary.top_level_record_count
  end

  def test_skips_heart_rate_variability_nested_series_as_specialized
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <HealthData>
        <ExportDate value="2026-09-12 12:00:00 +0000"/>
        <Record type="HKQuantityTypeIdentifierHeartRate" value="72" unit="count/min" creationDate="2026-09-12 11:59:00 +0000" startDate="2026-09-12 11:59:00 +0000" endDate="2026-09-12 12:00:00 +0000">
          <HeartRateVariabilityMetadataList>
            <InstantaneousBeatsPerMinute value="72" time="2026-09-12 11:59:30 +0000"/>
          </HeartRateVariabilityMetadataList>
        </Record>
        <Record type="HKQuantityTypeIdentifierHeartRate" value="73" unit="count/min" creationDate="2026-09-12 12:00:00 +0000" startDate="2026-09-12 12:00:00 +0000" endDate="2026-09-12 12:01:00 +0000"/>
      </HealthData>
    XML

    summary = parse_xml(xml)

    assert_equal 2, summary.top_level_record_count
    assert_equal 1, summary.imported_record_count
    assert_equal 1, summary.family_counts.fetch(:specialized)
  end

  def test_ignores_prolog_like_words_in_comments_and_dtd_values
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <!-- SYSTEM PUBLIC ENTITY % are ordinary comment text -->
        <!DOCTYPE HealthData [
        <!ELEMENT HealthData ANY>
        <!ATTLIST HealthData marker CDATA #IMPLIED>
      ]>
      <HealthData>
        <ExportDate value="2026-09-12 12:00:00 +0000" note="SYSTEM PUBLIC ENTITY %"/>
      </HealthData>
    XML

    summary = parse_xml_with_io(ChunkedIO.new(xml, 1))

    assert_equal Time.utc(2026, 9, 12, 12), summary.exported_at
    assert_equal 0, summary.top_level_record_count
  end

  def test_rejects_external_doctype_across_chunk_boundaries
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE HealthData SYSTEM "file:///private/apple-health-secret">
      <HealthData>
        <ExportDate value="2026-09-12 12:00:00 +0000"/>
      </HealthData>
    XML

    error = assert_raises(Cybort::AppleHealthError) do
      parse_xml_with_io(ChunkedIO.new(xml, 1))
    end

    assert_equal :unsafe_xml, error.safe_metadata.fetch(:category)
    refute_includes error.message, "apple-health-secret"
  end

  def test_rejects_entity_declaration_across_chunk_boundaries
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE HealthData [<!ENTITY secret "unsafe">]>
      <HealthData>
        <ExportDate value="2026-09-12 12:00:00 +0000"/>
      </HealthData>
    XML

    error = assert_raises(Cybort::AppleHealthError) do
      parse_xml_with_io(ChunkedIO.new(xml, 2))
    end

    assert_equal :unsafe_xml, error.safe_metadata.fetch(:category)
  end

  def test_ignores_brackets_inside_dtd_comments
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE HealthData [<!-- [ ] [ --><!ELEMENT HealthData ANY>]>
      <HealthData>
        <ExportDate value="2026-09-12 12:00:00 +0000"/>
      </HealthData>
    XML

    summary = parse_xml_with_io(ChunkedIO.new(xml, 1))

    assert_equal Time.utc(2026, 9, 12, 12), summary.exported_at
  end

  def test_rejects_entity_after_a_bracket_bearing_dtd_comment
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE HealthData [<!-- [ ] [ --><!ENTITY secret "unsafe">]>
      <HealthData>
        <ExportDate value="2026-09-12 12:00:00 +0000"/>
      </HealthData>
    XML

    error = assert_raises(Cybort::AppleHealthError) do
      parse_xml_with_io(ChunkedIO.new(xml, 1))
    end

    assert_equal :unsafe_xml, error.safe_metadata.fetch(:category)
  end

  def test_rejects_unmatched_dtd_quote
    xml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE HealthData [<!ATTLIST HealthData marker CDATA "unterminated>]
      <HealthData>
        <ExportDate value="2026-09-12 12:00:00 +0000"/>
      </HealthData>
    XML

    error = assert_raises(Cybort::AppleHealthError) do
      parse_xml_with_io(ChunkedIO.new(xml, 2))
    end

    assert_equal :unsafe_xml, error.safe_metadata.fetch(:category)
  end

  private

  def fixture(name)
    File.expand_path("fixtures/apple_health/#{name}", __dir__)
  end

  def parse_fixture(name)
    factory = Cybort::TimeSeriesSpoolFactory.new(directory: @spools)
    summary = nil
    factory.open(instance_id: "health", import_key: "test-#{name}", import_mode: :append,
                 source_started_at: Time.utc(2026, 9, 13, 12)) do |writer|
      File.open(fixture(name), "rb") { |io| summary = @parser.parse(io, spool_writer: writer) }
    end
    summary
  end

  def parse_xml(xml)
    parse_xml_with_io(StringIO.new(xml))
  end

  def parse_xml_with_io(io)
    factory = Cybort::TimeSeriesSpoolFactory.new(directory: @spools)
    summary = nil
    factory.open(instance_id: "health", import_key: "inline", import_mode: :append,
                 source_started_at: Time.utc(2026, 9, 13, 12)) do |writer|
      summary = @parser.parse(io, spool_writer: writer)
    end
    summary
  end

  def parse_fixture_with_artifact(name)
    factory = Cybort::TimeSeriesSpoolFactory.new(directory: @spools)
    summary = nil
    artifact = nil
    factory.open(instance_id: "health", import_key: "test-#{name}", import_mode: :append,
                source_started_at: Time.utc(2026, 9, 13, 12)) do |writer|
      File.open(fixture(name), "rb") do |io|
        summary = @parser.parse(io, spool_writer: writer)
      end
      artifact = writer.finalize(sync_state: {}, source_finished_at: Time.utc(2026, 9, 13, 12, 1), metadata: {})
    end
    [summary, artifact]
  end

  class ChunkedIO
    def initialize(value, chunk_size)
      @io = StringIO.new(value)
      @chunk_size = chunk_size
    end

    def read(length = nil, outbuf = nil)
      requested = [length || @chunk_size, @chunk_size].min
      chunk = @io.read(requested)
      if outbuf && chunk
        outbuf.replace(chunk)
        outbuf
      else
        chunk
      end
    end

    def eof?
      @io.eof?
    end
  end
end
