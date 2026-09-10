require "test_helper"

class InstallationBackupTest < Minitest::Test
  def test_creates_two_database_snapshots_and_manifest_before_publication
    Dir.mktmpdir do |directory|
      root = File.join(directory, "cybort")
      FileUtils.mkdir_p(root)
      clock = -> { Time.utc(2026, 9, 10, 12, 0, 0) }
      main = Cybort::Persistence.new(File.join(root, "cybort.sqlite3"), clock: clock).setup!
      time_series = Cybort::TimeSeriesPersistence.new(
        File.join(root, "cybort-timeseries.sqlite3"), clock: clock
      ).setup!
      fsyncs = []
      destination = File.join(directory, "backup")

      result = Cybort::InstallationBackup.new(
        root: root, persistence: main, time_series_persistence: time_series,
        clock: clock, fsync: ->(path) { fsyncs << path }
      ).create(destination: destination)

      assert_equal destination, result
      assert_equal %w[cybort-timeseries.sqlite3 cybort.sqlite3 manifest.json].sort,
                   Dir.children(destination).sort
      manifest = JSON.parse(File.read(File.join(destination, "manifest.json")))
      assert_equal 1, manifest.fetch("format_version")
      assert manifest.key?("installation_backup_started_at")
      assert manifest.key?("installation_backup_completed_at")
      assert_equal %w[cybort.sqlite3 cybort-timeseries.sqlite3].sort,
                   manifest.fetch("databases").map { |entry| entry.fetch("filename") }.sort
      manifest.fetch("databases").each do |entry|
        snapshot = File.join(destination, entry.fetch("filename"))
        assert_equal 64, entry.fetch("sha256").length
        assert_equal entry.fetch("sha256"), Digest::SHA256.file(snapshot).hexdigest
        assert_equal 0o600, File.stat(snapshot).mode & 0o777
      end
      assert_equal 0o600, File.stat(File.join(destination, "manifest.json")).mode & 0o777
      assert_equal 0o700, File.stat(destination).mode & 0o777
      assert fsyncs.any? { |path| File.basename(path) == "manifest.json" }
      assert_includes fsyncs, File.dirname(destination)

      reopened_main = Cybort::Persistence.new(File.join(destination, "cybort.sqlite3")).setup!
      reopened_time_series = Cybort::TimeSeriesPersistence.new(
        File.join(destination, "cybort-timeseries.sqlite3")
      ).setup!
      reopened_main.close
      reopened_time_series.close
    ensure
      main&.close
      time_series&.close
    end
  end

  def test_refuses_existing_destination_and_removes_partial_directory
    Dir.mktmpdir do |directory|
      root = File.join(directory, "cybort")
      FileUtils.mkdir_p(root)
      main = Cybort::Persistence.new(File.join(root, "cybort.sqlite3")).setup!
      time_series = Cybort::TimeSeriesPersistence.new(File.join(root, "cybort-timeseries.sqlite3")).setup!
      destination = File.join(directory, "backup")
      FileUtils.mkdir_p(destination)

      error = assert_raises(Cybort::ValidationError) do
        Cybort::InstallationBackup.new(
          root: root, persistence: main, time_series_persistence: time_series
        ).create(destination: destination)
      end
      assert_includes error.message, "destination"
      FileUtils.rm_rf(destination)

      failing = Object.new
      def failing.backup_to(_path)
        raise "injected backup failure"
      end
      assert_raises(RuntimeError) do
        Cybort::InstallationBackup.new(
          root: root, persistence: failing, time_series_persistence: time_series
        ).create(destination: destination)
      end
      refute_path_exists destination
    ensure
      main&.close
      time_series&.close
    end
  end
end
