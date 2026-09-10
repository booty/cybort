require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"

module Cybort
  # Publishes an adjacent, self-describing backup of both canonical SQLite
  # stores. The persistence services perform SQLite-native snapshots; this
  # class only controls their destination, durability, and publication order.
  class InstallationBackup
    FORMAT_VERSION = 1
    DATABASE_FILENAMES = %w[cybort.sqlite3 cybort-timeseries.sqlite3].freeze

    def initialize(root:, persistence: nil, time_series_persistence: nil,
                   clock: -> { Time.now.utc }, lock: nil, fsync: method(:fsync_path))
      @root = File.expand_path(root.to_s)
      @persistence = persistence
      @time_series_persistence = time_series_persistence
      @clock = clock
      @lock = lock || InstallationLock.new(@root)
      @fsync = fsync
      raise ArgumentError, "fsync must be callable" unless @fsync.respond_to?(:call)
    end

    def create(destination:)
      destination = File.expand_path(destination.to_s)
      @lock.synchronize do
        create_locked(destination)
      end
    end

    private

    def create_locked(destination)
      refuse_existing_destination!(destination)
      FileUtils.mkdir_p(File.dirname(destination))
      temporary = temporary_directory(destination)
      owned_services = []
      begin
        started_at = timestamp
        persistence, owned = persistence_for(
          @persistence, File.join(@root, "cybort.sqlite3"), Persistence
        )
        owned_services << persistence if owned
        time_series_persistence, owned = persistence_for(
          @time_series_persistence, File.join(@root, "cybort-timeseries.sqlite3"), TimeSeriesPersistence
        )
        owned_services << time_series_persistence if owned

        databases = DATABASE_FILENAMES.map do |filename|
          service = filename == "cybort.sqlite3" ? persistence : time_series_persistence
          snapshot_started_at = timestamp
          service.backup_to(File.join(temporary, filename))
          snapshot_completed_at = timestamp
          snapshot_path = File.join(temporary, filename)
          File.chmod(0o600, snapshot_path)
          fsync(snapshot_path)
          {
            "filename" => filename,
            "snapshot_started_at" => snapshot_started_at,
            "snapshot_completed_at" => snapshot_completed_at,
            "sha256" => Digest::SHA256.file(snapshot_path).hexdigest
          }
        end

        manifest = {
          "format_version" => FORMAT_VERSION,
          "installation_backup_started_at" => started_at,
          "installation_backup_completed_at" => timestamp,
          "databases" => databases
        }
        manifest_path = File.join(temporary, "manifest.json")
        File.open(manifest_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(JSON.generate(manifest))
          file.write("\n")
          file.flush
          file.fsync
        end
        File.chmod(0o600, manifest_path)
        # The callback is intentionally invoked for the manifest too; tests and
        # alternate filesystems can observe that all publication inputs were
        # synced before the directory rename.
        fsync(manifest_path)
        fsync(temporary)
        File.rename(temporary, destination)
        fsync(File.dirname(destination))
        temporary = nil
        destination
      ensure
        owned_services.reverse_each do |service|
          begin
            service.close if service.respond_to?(:close)
          rescue StandardError
            nil
          end
        end
        FileUtils.rm_rf(temporary) if temporary && File.exist?(temporary)
      end
    end

    def persistence_for(existing, path, klass)
      return [existing, false] if existing

      service = klass.new(path, clock: @clock)
      service.setup! if service.respond_to?(:setup!)
      [service, true]
    end

    def refuse_existing_destination!(destination)
      if File.exist?(destination) || File.symlink?(destination)
        raise ValidationError, "backup destination already exists"
      end
    end

    def temporary_directory(destination)
      parent = File.dirname(destination)
      basename = File.basename(destination)
      temporary = File.join(parent, ".#{basename}.tmp-#{Process.pid}-#{SecureRandom.hex(8)}")
      FileUtils.mkdir(temporary, mode: 0o700)
      File.chmod(0o700, temporary)
      temporary
    rescue Errno::EEXIST
      retry
    end

    def timestamp
      value = @clock.call
      raise ArgumentError, "clock must return a Time" unless value.is_a?(Time)

      value.utc.iso8601(6)
    end

    def fsync(path)
      @fsync.call(path)
    end

    def fsync_path(path)
      File.open(path, File::RDONLY) { |file| file.fsync }
    end
  end
end
