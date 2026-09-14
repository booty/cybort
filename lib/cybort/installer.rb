require "fileutils"
require "open3"
require "sqlite3"

module Cybort
  class Installer
    CONFIG_FILENAME = "cybort.toml"
    MAIN_DATABASE_FILENAME = "cybort.sqlite3"
    TIME_SERIES_DATABASE_FILENAME = "cybort-timeseries.sqlite3"
    DEFAULT_CONFIG = "schema_version = 1\n"
    MAIN_DATABASE_TABLES = %w[adapter_instances fetch_runs items schema_migrations].freeze

    def initialize(io:, clock: -> { Time.now.utc }, archive: method(:archive_installation))
      @io = io
      @clock = clock
      @archive = archive
    end

    def run(location:)
      location = File.expand_path(location)
      operation_root = canonical_operation_root(location)
      InstallationLock.new(operation_root).synchronize do
        run_locked(operation_root)
      end
    end

    private

    def run_locked(location)
      return create_new(location) unless existing_installation?(location)
      unless recognizable_installation?(location)
        raise ConfigurationError,
              "Refusing to reset non-Cybort directory at #{location}; choose an empty directory or an existing Cybort installation"
      end

      repair_existing_installation_permissions!(location)

      @io.puts "Cybort is already initialized at #{location}."
      @io.puts "1) Keep current installation"
      @io.puts "2) Back up and retain configuration while resetting data"
      @io.puts "3) Back up and reset everything"
      @io.puts "4) Reset without backup"
      @io.puts "5) Cancel"

      case @io.gets.to_s.strip
      when "1" then :kept
      when "2" then reset(location, keep_config: true, backup: true)
      when "3" then reset(location, keep_config: false, backup: true)
      when "4" then confirmed_reset(location)
      else :cancelled
      end
    end

    def existing_installation?(location)
      File.directory?(location) && !Dir.children(location).empty?
    end

    def recognizable_installation?(location)
      database_path = File.join(location, MAIN_DATABASE_FILENAME)
      return false unless regular_file?(database_path)

      database = SQLite3::Database.new(
        database_path, flags: SQLite3::Constants::Open::READONLY
      )
      names = database.execute(
        "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
      ).flatten
      return false unless MAIN_DATABASE_TABLES.all? { |name| names.include?(name) }

      versions = database.execute("SELECT version FROM schema_migrations").flatten
      versions.any? { |version| version.to_i.between?(1, Schema::VERSION) }
    rescue SQLite3::Exception, SystemCallError
      false
    ensure
      database&.close
    end

    def regular_file?(path)
      stat = File.lstat(path)
      stat.file? && !stat.symlink?
    rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR
      false
    end

    def repair_existing_installation_permissions!(location)
      InstallationPermissions.ensure_directory!(location)
      InstallationPermissions.ensure_private_file!(File.join(location, CONFIG_FILENAME), allow_missing: true)
      InstallationPermissions.ensure_private_file!(File.join(location, MAIN_DATABASE_FILENAME))
      InstallationPermissions.ensure_private_file!(
        File.join(location, TIME_SERIES_DATABASE_FILENAME), allow_missing: true
      )
    end

    def canonical_operation_root(location)
      # Preserve lexical paths for ordinary directories so archive and output
      # paths retain the spelling supplied by the user. Resolve only a
      # symlinked installation root, allowing reset operations to remove and
      # recreate its real target without unlinking the alias itself.
      return location unless File.symlink?(location)

      File.realpath(location)
    rescue Errno::ENOENT
      # If a symlink target disappears between the symlink check and realpath,
      # retain the lexical path so a new installation follows normal creation
      # semantics.
      location
    end

    def create_new(location)
      InstallationPermissions.create_directory!(location)
      config_path = File.join(location, CONFIG_FILENAME)
      InstallationPermissions.write_private_file!(config_path, DEFAULT_CONFIG) unless File.exist?(config_path)
      initialize_databases(location)
      :created
    end

    def confirmed_reset(location)
      @io.puts "Type RESET to confirm deleting the installation without a backup:"
      return :cancelled unless @io.gets.to_s.strip == "RESET"

      reset(location, keep_config: false, backup: false)
    end

    def reset(location, keep_config:, backup:)
      config_path = File.join(location, CONFIG_FILENAME)
      config = File.binread(config_path) if keep_config && File.exist?(config_path)
      archive_path = backup_path(location) if backup
      if archive_path
        if backup_artifact_exists?(archive_path)
          raise ValidationError, "reset backup destination already exists"
        end

        begin
          @archive.call(location, archive_path)
        rescue Exception
          secure_partial_backup_artifact(archive_path)
          raise
        else
          ensure_private_backup_artifact!(archive_path)
        end
      end
      FileUtils.rm_rf(location)
      InstallationPermissions.create_directory!(location)
      InstallationPermissions.write_private_file!(config_path, config || DEFAULT_CONFIG)
      initialize_databases(location)
      keep_config ? :reset_with_config : :reset
    end

    def initialize_databases(location)
      main = nil
      time_series = nil
      begin
        main = Persistence.new(File.join(location, "cybort.sqlite3"), clock: @clock)
        main.setup!
        time_series = TimeSeriesPersistence.new(
          File.join(location, "cybort-timeseries.sqlite3"), clock: @clock
        )
        time_series.setup!
        nil
      ensure
        active_error = $!
        cleanup_error = nil
        [time_series, main].each do |database|
          next unless database&.respond_to?(:close)

          begin
            database.close
          rescue Exception => error # cleanup must not mask an active setup error
            cleanup_error ||= error
          end
        end
        raise cleanup_error if active_error.nil? && cleanup_error
      end
    end

    def ensure_private_backup_artifact!(path)
      stat = File.lstat(path)
      unless stat.file? && !stat.symlink?
        raise ValidationError, "reset backup must be a private regular file"
      end

      File.chmod(InstallationPermissions::FILE_MODE, path)
    rescue Errno::ENOENT
      raise ValidationError, "reset backup was not created"
    end

    def secure_partial_backup_artifact(path)
      stat = File.lstat(path)
      return unless stat.file? && !stat.symlink?

      File.chmod(InstallationPermissions::FILE_MODE, path)
    rescue Errno::ENOENT
      nil
    end

    def backup_artifact_exists?(path)
      File.exist?(path) || File.symlink?(path)
    end

    def backup_path(location)
      timestamp = @clock.call.utc.strftime("%Y%m%dT%H%M%SZ")
      "#{location}.backup-#{timestamp}.tar.gz"
    end

    def archive_installation(location, backup_path)
      if backup_artifact_exists?(backup_path)
        raise ValidationError, "reset backup destination already exists"
      end

      parent = File.dirname(location)
      basename = File.basename(location)
      File.open(backup_path, File::WRONLY | File::CREAT | File::EXCL, InstallationPermissions::FILE_MODE) do |file|
        file.close
      end
      _stdout, stderr, status = Open3.capture3("tar", "-czf", backup_path, "-C", parent, basename)
      raise SystemCallError.new("tar failed: #{stderr}") unless status.success?
      File.chmod(InstallationPermissions::FILE_MODE, backup_path)
    end
  end
end
