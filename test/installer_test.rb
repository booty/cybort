require "test_helper"

class InstallerTest < Minitest::Test
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
    File.write(File.join(path, "marker.txt"), "old data")
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
      assert_equal File.join(directory, "cybort.backup-20260816T123456Z.tar.gz"), archives.first.last
    end
  end

  def test_backup_and_reset_everything_removes_config
    Dir.mktmpdir do |directory|
      path = File.join(directory, "cybort")
      write_existing_installation(path)
      installer_instance, archives = installer(input: "3\n")

      assert_equal :reset, installer_instance.run(location: path)
      refute_path_exists File.join(path, "cybort.toml")
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
      assert_empty archives
    end
  end
end
