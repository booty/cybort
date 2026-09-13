require "test_helper"
require_relative "support/apple_health_fixture"
require "time"

class AppleHealthZipTest < Minitest::Test
  def setup
    @root = File.realpath(Dir.mktmpdir)
    @archive_path = File.join(@root, "export.zip")
    @export_xml = File.binread(File.expand_path("fixtures/apple_health/export_basic.xml", __dir__))
    @parser_factory = lambda do
      Object.new.tap do |parser|
        parser.define_singleton_method(:probe) do |io|
          io.read
          { exported_at: Time.iso8601("2026-09-11T12:00:00-04:00") }
        end
      end
    end
    @inspector = Cybort::AppleHealthZipInspector.new(parser_factory: @parser_factory)
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_invents_a_bounded_inventory_and_probes_only_export_xml
    Cybort::AppleHealthFixture.write_zip(
      path: @archive_path, export_xml: @export_xml, wrapper: "apple_health_export",
      entries: { "electrocardiograms/ecg.csv" => "CRC_SENTINEL" }
    )

    candidate = @inspector.inspect(acquired(@archive_path))

    assert_equal "apple_health_export/export.xml", candidate.export_entry_name
    assert_equal Time.iso8601("2026-09-11T12:00:00-04:00"), candidate.exported_at
    assert_equal 2, candidate.inventory.fetch(:entry_count)
    assert_equal 1, candidate.inventory.fetch(:family_counts).fetch(:electrocardiogram)
  end

  def test_streams_export_xml_and_reports_checksum_and_size
    Cybort::AppleHealthFixture.write_zip(
      path: @archive_path, export_xml: @export_xml, entries: {}
    )
    candidate = @inspector.inspect(acquired(@archive_path))

    result = @inspector.with_export_stream(candidate) { |io| io.read }

    assert_equal @export_xml, result.payload
    assert_equal Digest::SHA256.hexdigest(@export_xml), result.export_xml_sha256
    assert_equal @export_xml.bytesize, result.export_xml_bytes
  end

  def test_rejects_missing_export_xml_without_exposing_entry_names
    Zip::File.open(@archive_path, create: true) do |zip|
      zip.get_output_stream("other.xml") { |io| io.write("not export") }
    end

    error = assert_raises(Cybort::AppleHealthError) { @inspector.inspect(acquired(@archive_path)) }
    assert_equal :missing_export_xml, error.safe_metadata.fetch(:category)
    refute_includes error.message, "other.xml"
  end

  def test_rejects_duplicate_normalized_export_xml_entries
    Cybort::AppleHealthFixture.write_zip(
      path: @archive_path, export_xml: @export_xml,
      entries: [["e\u0301.csv", "one"], ["é.csv", "two"]]
    )

    error = assert_raises(Cybort::AppleHealthError) { @inspector.inspect(acquired(@archive_path)) }
    assert_equal :invalid_zip, error.safe_metadata.fetch(:category)
  end

  def test_rejects_an_export_body_that_starts_with_zip_magic
    nested = "PK\x03\x04not-an-xml-document".b
    Cybort::AppleHealthFixture.write_zip(path: @archive_path, export_xml: nested, entries: {})

    error = assert_raises(Cybort::AppleHealthError) { @inspector.inspect(acquired(@archive_path)) }
    assert_equal :invalid_zip, error.safe_metadata.fetch(:category)
  end

  private

  def acquired(path)
    Cybort::AppleHealthAcquiredArchive.new(
      path: path,
      archive_sha256: Digest::SHA256.file(path).hexdigest,
      compressed_bytes: File.size(path),
      source_started_at: Time.utc(2026, 9, 13, 12)
    )
  end
end
