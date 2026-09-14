require "test_helper"
require "open3"
require "rbconfig"

class AppleHealthSystemTest < Minitest::Test
  def test_streaming_benchmark_contract_and_indexed_queries
    Dir.mktmpdir do |directory|
      output_directory = File.join(directory, "benchmark-output")
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, File.expand_path("../../script/benchmark_apple_health.rb", __dir__),
        "--records", "1000", "--overlap-percent", "99", "--output", output_directory
      )

      assert status.success?, stderr
      lines = stdout.lines
      assert_equal 1, lines.length
      summary = JSON.parse(lines.fetch(0))
      assert_equal 1000, summary.fetch("records")
      assert_equal 99, summary.fetch("overlap_percent")
      assert_kind_of Integer, summary.fetch("series_cardinality")
      assert_kind_of Integer, summary.fetch("stored_observations")
      assert_kind_of Hash, summary.fetch("first_archive")
      assert_kind_of Hash, summary.fetch("second_archive")
      assert_kind_of Hash, summary.fetch("first_import")
      assert_kind_of Hash, summary.fetch("second_import")
      assert_kind_of Hash, summary.fetch("durations_seconds")
      assert_kind_of Hash, summary.fetch("sizes_bytes")
      assert_kind_of Array, summary.fetch("queries")
      assert_kind_of Array, summary.fetch("query_plans")
      assert_kind_of String, summary.fetch("ruby_version")
      assert_kind_of String, summary.fetch("sqlite_version")
      assert_kind_of String, summary.fetch("rubyzip_version")
      assert_kind_of String, summary.fetch("nokogiri_version")
      assert_kind_of Integer, summary.fetch("schema_version")
      assert_includes %w[getrusage_maxrss proc_vmhwm unavailable], summary.fetch("rss_measurement_kind")
      assert_includes %w[ps_rss_current unavailable], summary.fetch("current_rss_measurement_kind")
      assert_equal 0, summary.dig("second_import", "deleted")
      assert_equal 0, summary.dig("second_import", "changed")
      assert_equal true, summary.dig("second_import", "overlap_ingested_at_stable")
      assert_operator summary.dig("second_import", "overlap_sample_count"), :>, 0
      assert_operator summary.dig("second_import", "duplicate"), :>, 0
      assert(summary.fetch("query_plans").all? { |plan| plan.fetch("uses_series_time_index") })

      script = File.read(File.expand_path("../../script/benchmark_apple_health.rb", __dir__))
      assert_includes script, 'get_output_stream("export.xml")'
      refute_match(/records\s*=\s*\[\]/, script)
      assert File.file?(File.join(output_directory, "cybort-timeseries.sqlite3"))
    end
  end
end
