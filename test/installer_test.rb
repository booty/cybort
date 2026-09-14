require "test_helper"
require "open3"
require_relative "support/lifecycle_resource"

class InstallerTest < Minitest::Test
  include LifecycleTestSupport

  class TestIO
    def initialize(input)
      @input = StringIO.new(input)
      @output = StringIO.new
    end

    def gets
      @input.gets
    end

    def puts(message = "")
      @output.puts(message)
    end
  end

  def clock
    -> { Time.utc(2026, 8, 16, 12, 34, 56) }
  end

  def write_existing_installation(path)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "cybort.toml"), "schema_version = 1\n")
    persistence = Cybort::Persistence.new(File.join(path, "cybort.sqlite3"))
    persistence.setup!
    persistence.close
    File.write(File.join(path, "marker.txt"), "old data")
  end

  def with_umask(value)
    previous = File.umask(value)
    yield
  ensure
    File.umask(previous) if previous
  end

  def installer(input: "", archives: [])
    io = TestIO.new(input)
    archive = lambda do |location, backup_path|
      archives << [location, backup_path]
      File.write(backup_path, "backup")
    end
    [Cybort::Installer.new(io: io, clock: clock, archive: archive), archives]
  end

  def test_creates_new_installation
    Dir.mktmpdir do |directory|
      path = File.join(directory, "cybort")
      installer_instance, = installer

      assert_equal :created, installer_instance.run(location: path)
      assert_path_exists File.join(path, "cybort.toml")
      assert_path_exists File.join(path, "cybort.sqlite3")
      assert_path_exists File.join(path, "cybort-timeseries.sqlite3")
    end
  end

  def test_keep_choice_does_not_modify_existing_installation
    Dir.mktmpdir do |directory|
      path = File.join(directory, "cybort")
      write_existing_installation(path)
      installer_instance, archives = installer(input: "1\n")

      assert_equal :kept, installer_instance.run(location: path)
      assert_equal "old data", File.read(File.join(path, "marker.txt"))
      assert_empty archives
    end
  end

  def test_backup_and_retain_config_resets_data
    Dir.mktmpdir do |directory|
      path = File.join(directory, "cybort")
      write_existing_installation(path)
      installer_instance, archives = installer(input: "2\n")

      assert_equal :reset_with_config, installer_instance.run(location: path)
      assert_equal "schema_version = 1\n", File.read(File.join(path, "cybort.toml"))
      refute_path_exists File.join(path, "marker.txt")
      assert_path_exists File.join(path, "cybort.sqlite3")
      assert_path_exists File.join(path, "cybort-timeseries.sqlite3")
      assert_equal File.join(directory, "cybort.backup-20260816T123456Z.tar.gz"), archives.first.last
    end
  end

  def test_backup_and_reset_everything_recreates_fresh_config
    Dir.mktmpdir do |directory|
      path = File.join(directory, "cybort")
      write_existing_installation(path)
      installer_instance, archives = installer(input: "3\n")

      assert_equal :reset, installer_instance.run(location: path)
      assert_equal "schema_version = 1\n", File.read(File.join(path, "cybort.toml"))
      assert_path_exists File.join(path, "cybort.sqlite3")
      assert_path_exists File.join(path, "cybort-timeseries.sqlite3")
      assert_equal 1, archives.length
    end
  end

  def test_no_backup_reset_requires_second_confirmation
    Dir.mktmpdir do |directory|
      path = File.join(directory, "cybort")
      write_existing_installation(path)
      installer_instance, archives = installer(input: "4\nNO\n")

      assert_equal :cancelled, installer_instance.run(location: path)
      assert_path_exists File.join(path, "marker.txt")
      assert_empty archives
    end
  end

  def test_confirmed_no_backup_reset_removes_data
    Dir.mktmpdir do |directory|
      path = File.join(directory, "cybort")
      write_existing_installation(path)
      installer_instance, archives = installer(input: "4\nRESET\n")

      assert_equal :reset, installer_instance.run(location: path)
      refute_path_exists File.join(path, "marker.txt")
      assert_equal "schema_version = 1\n", File.read(File.join(path, "cybort.toml"))
      assert_path_exists File.join(path, "cybort.sqlite3")
      assert_path_exists File.join(path, "cybort-timeseries.sqlite3")
      assert_empty archives
    end
  end

  def test_full_reset_recreates_config_when_existing_config_is_missing
    Dir.mktmpdir do |directory|
      path = File.join(directory, "cybort")
      write_existing_installation(path)
      FileUtils.rm_f(File.join(path, "cybort.toml"))
      installer_instance, archives = installer(input: "4\nRESET\n")

      assert_equal :reset, installer_instance.run(location: path)
      assert_equal "schema_version = 1\n", File.read(File.join(path, "cybort.toml"))
      assert_empty archives
    end
  end

  def test_backup_collision_leaves_existing_artifact_unchanged
    Dir.mktmpdir do |directory|
      path = File.join(directory, "cybort")
      write_existing_installation(path)
      backup_path = File.join(directory, "cybort.backup-20260816T123456Z.tar.gz")
      original_bytes = "previous backup bytes\n"
      File.binwrite(backup_path, original_bytes)
      File.chmod(0o644, backup_path)
      original_mode = File.stat(backup_path).mode & 0o777
      installer_instance = Cybort::Installer.new(io: TestIO.new("2\n"), clock: clock)

      assert_raises(Cybort::ValidationError) do
        installer_instance.run(location: path)
      end
      assert_equal original_bytes, File.binread(backup_path)
      assert_equal original_mode, File.stat(backup_path).mode & 0o777
      assert_equal "old data", File.read(File.join(path, "marker.txt"))
    end
  end

  def test_rejects_symlinked_configuration_without_modifying_external_target
    Dir.mktmpdir do |directory|
      path = File.join(directory, "cybort")
      write_existing_installation(path)
      external = File.join(directory, "external.toml")
      external_bytes = "external configuration\n"
      File.binwrite(external, external_bytes)
      File.chmod(0o644, external)
      external_mode = File.stat(external).mode & 0o777
      FileUtils.rm_f(File.join(path, "cybort.toml"))
      File.symlink(external, File.join(path, "cybort.toml"))
      installer_instance = Cybort::Installer.new(io: TestIO.new("2\n"), clock: clock)

      assert_raises(Cybort::ValidationError) do
        installer_instance.run(location: path)
      end
      assert_equal external_bytes, File.binread(external)
      assert_equal external_mode, File.stat(external).mode & 0o777
      assert File.symlink?(File.join(path, "cybort.toml"))
      assert_equal "old data", File.read(File.join(path, "marker.txt"))
    end
  end

  def test_rejects_symlinked_main_database_without_modifying_external_target
    Dir.mktmpdir do |directory|
      path = File.join(directory, "cybort")
      write_existing_installation(path)
      external = File.join(directory, "external.sqlite3")
      external_persistence = Cybort::Persistence.new(external).setup!
      external_persistence.close
      File.chmod(0o644, external)
      external_bytes = File.binread(external)
      external_mode = File.stat(external).mode & 0o777
      FileUtils.rm_f(File.join(path, "cybort.sqlite3"))
      File.symlink(external, File.join(path, "cybort.sqlite3"))
      installer_instance = Cybort::Installer.new(io: TestIO.new("2\n"), clock: clock)

      assert_raises(Cybort::ConfigurationError) do
        installer_instance.run(location: path)
      end
      assert_equal external_bytes, File.binread(external)
      assert_equal external_mode, File.stat(external).mode & 0o777
      assert File.symlink?(File.join(path, "cybort.sqlite3"))
      assert_equal "old data", File.read(File.join(path, "marker.txt"))
    end
  end

  def test_rejects_symlinked_time_series_database_without_modifying_external_target
    Dir.mktmpdir do |directory|
      path = File.join(directory, "cybort")
      write_existing_installation(path)
      external = File.join(directory, "external-timeseries.sqlite3")
      external_persistence = Cybort::TimeSeriesPersistence.new(external).setup!
      external_persistence.close
      File.chmod(0o644, external)
      external_bytes = File.binread(external)
      external_mode = File.stat(external).mode & 0o777
      File.symlink(external, File.join(path, "cybort-timeseries.sqlite3"))
      installer_instance = Cybort::Installer.new(io: TestIO.new("2\n"), clock: clock)

      assert_raises(Cybort::ValidationError) do
        installer_instance.run(location: path)
      end
      assert_equal external_bytes, File.binread(external)
      assert_equal external_mode, File.stat(external).mode & 0o777
      assert File.symlink?(File.join(path, "cybort-timeseries.sqlite3"))
      assert_equal "old data", File.read(File.join(path, "marker.txt"))
    end
  end

  def test_refuses_destructive_choices_for_unrelated_nonempty_directories
    ["2\n", "3\n", "4\nRESET\n"].each do |input|
      Dir.mktmpdir do |directory|
        path = File.join(directory, "unrelated")
        FileUtils.mkdir_p(path)
        marker = File.join(path, "important.txt")
        File.write(marker, "do not delete")
        installer_instance, archives = installer(input: input)

        assert_raises(Cybort::ConfigurationError) do
          installer_instance.run(location: path)
        end
        assert_equal "do not delete", File.read(marker)
        assert_empty archives
      end
    end
  end

  def test_refuses_destructive_choices_for_symlink_to_unrelated_directory
    Dir.mktmpdir do |directory|
      target = File.join(directory, "unrelated-target")
      alias_path = File.join(directory, "unrelated-alias")
      FileUtils.mkdir_p(target)
      marker = File.join(target, "important.txt")
      File.write(marker, "do not delete")
      File.symlink(target, alias_path)
      installer_instance, archives = installer(input: "4\nRESET\n")

      assert_raises(Cybort::ConfigurationError) do
        installer_instance.run(location: alias_path)
      end
      assert_equal "do not delete", File.read(marker)
      assert File.symlink?(alias_path)
      assert_empty archives
    end
  end

  def test_new_installation_repairs_modes_under_permissive_umask
    Dir.mktmpdir do |directory|
      path = File.join(directory, "cybort")
      installer_instance, = installer

      with_umask(0) do
        assert_equal :created, installer_instance.run(location: path)
      end

      assert_equal 0o700, File.stat(path).mode & 0o777
      assert_equal 0o600, File.stat(File.join(path, "cybort.toml")).mode & 0o777
      assert_equal 0o600, File.stat(File.join(path, "cybort.sqlite3")).mode & 0o777
      assert_equal 0o600, File.stat(File.join(path, "cybort-timeseries.sqlite3")).mode & 0o777
    end
  end

  def test_keep_choice_repairs_existing_installation_modes
    Dir.mktmpdir do |directory|
      path = File.join(directory, "cybort")
      write_existing_installation(path)
      File.chmod(0o777, path)
      %w[cybort.toml cybort.sqlite3].each { |name| File.chmod(0o666, File.join(path, name)) }
      installer_instance, = installer(input: "1\n")

      assert_equal :kept, installer_instance.run(location: path)
      assert_equal 0o700, File.stat(path).mode & 0o777
      assert_equal 0o600, File.stat(File.join(path, "cybort.toml")).mode & 0o777
      assert_equal 0o600, File.stat(File.join(path, "cybort.sqlite3")).mode & 0o777
    end
  end

  def test_reset_backup_artifact_is_private_under_permissive_umask
    Dir.mktmpdir do |directory|
      path = File.join(directory, "cybort")
      write_existing_installation(path)
      installer_instance, archives = installer(input: "2\n")

      with_umask(0) do
        assert_equal :reset_with_config, installer_instance.run(location: path)
      end

      assert_equal 0o600, File.stat(archives.first.last).mode & 0o777
    end
  end

  def test_symlink_reset_archives_and_recreates_the_real_target
    Dir.mktmpdir do |directory|
      target = File.join(directory, "cybort-target")
      alias_path = File.join(directory, "cybort-alias")
      write_existing_installation(target)
      File.symlink(target, alias_path)
      canonical_target = File.realpath(target)

      io = TestIO.new("2\n")
      installer_instance = Cybort::Installer.new(io: io, clock: clock)

      assert_equal :reset_with_config, installer_instance.run(location: alias_path)

      backup_path = "#{canonical_target}.backup-20260816T123456Z.tar.gz"
      assert_path_exists backup_path
      assert_equal 0o600, File.stat(backup_path).mode & 0o777
      stdout, stderr, status = Open3.capture3(
        "tar", "-xOzf", backup_path, "#{File.basename(target)}/marker.txt"
      )
      assert status.success?, stderr
      assert_equal "old data", stdout

      refute_path_exists File.join(target, "marker.txt")
      assert_equal "schema_version = 1\n", File.read(File.join(target, "cybort.toml"))
      assert_path_exists File.join(target, "cybort.sqlite3")
      assert_path_exists File.join(target, "cybort-timeseries.sqlite3")
      assert File.symlink?(alias_path)
      assert_equal canonical_target, File.realpath(alias_path)
    end
  end

  def test_symlink_reset_uses_canonical_lock_while_archiving_target
    Dir.mktmpdir do |directory|
      target = File.join(directory, "cybort-target")
      alias_path = File.join(directory, "cybort-alias")
      write_existing_installation(target)
      File.symlink(target, alias_path)
      canonical_target = File.realpath(target)

      alias_lock = Cybort::InstallationLock.new(alias_path)
      target_lock = Cybort::InstallationLock.new(target)
      assert_equal target_lock.path, alias_lock.path

      observed_location = nil
      lock_error = nil
      archive = lambda do |location, backup_path|
        observed_location = location
        lock_error = assert_raises(Cybort::InstallationLock::BusyError) do
          alias_lock.synchronize { flunk "symlink alias acquired the active installer lock" }
        end
        File.write(backup_path, "backup")
      end
      installer_instance = Cybort::Installer.new(io: TestIO.new("2\n"), clock: clock, archive: archive)

      assert_equal :reset_with_config, installer_instance.run(location: alias_path)
      assert_equal canonical_target, observed_location
      assert_instance_of Cybort::InstallationLock::BusyError, lock_error
      assert File.symlink?(alias_path)
      assert_equal canonical_target, File.realpath(alias_path)
    end
  end

  def test_setup_failure_closes_every_initialized_resource_and_preserves_primary_error
    primary = RuntimeError.new("injected time-series setup failure")
    cleanup = RuntimeError.new("injected close failure")
    LifecycleResource.reset!(setup_errors: [nil, primary], close_errors: [cleanup, cleanup])

    Dir.mktmpdir do |directory|
      path = File.join(directory, "cybort")
      installer_instance, = installer

      error = with_cybort_constants(
        Persistence: LifecycleResource, TimeSeriesPersistence: LifecycleResource
      ) do
        assert_raises(RuntimeError) { installer_instance.run(location: path) }
      end

      assert_same primary, error
      assert_equal 2, LifecycleResource.instances.length
      assert LifecycleResource.instances.all?(&:closed)
    end
  end
end
