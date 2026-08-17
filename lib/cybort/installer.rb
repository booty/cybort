require "fileutils"
require "open3"

module Cybort
  class Installer
    def initialize(io:, clock: -> { Time.now.utc }, archive: method(:archive_installation))
      @io = io
      @clock = clock
      @archive = archive
    end

    def run(location:)
      location = File.expand_path(location)
      return create_new(location) unless existing_installation?(location)

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

    private

    def existing_installation?(location)
      File.directory?(location) && !Dir.children(location).empty?
    end

    def create_new(location)
      FileUtils.mkdir_p(location)
      config_path = File.join(location, "cybort.toml")
      File.write(config_path, "schema_version = 1\n") unless File.exist?(config_path)
      Persistence.new(File.join(location, "cybort.sqlite3"), clock: @clock).setup!
      :created
    end

    def confirmed_reset(location)
      @io.puts "Type RESET to confirm deleting the installation without a backup:"
      return :cancelled unless @io.gets.to_s.strip == "RESET"

      reset(location, keep_config: false, backup: false)
    end

    def reset(location, keep_config:, backup:)
      config = File.binread(File.join(location, "cybort.toml")) if keep_config && File.exist?(File.join(location, "cybort.toml"))
      @archive.call(location, backup_path(location)) if backup
      FileUtils.rm_rf(location)
      FileUtils.mkdir_p(location)
      File.write(File.join(location, "cybort.toml"), config) if config
      Persistence.new(File.join(location, "cybort.sqlite3"), clock: @clock).setup!
      keep_config ? :reset_with_config : :reset
    end

    def backup_path(location)
      timestamp = @clock.call.utc.strftime("%Y%m%dT%H%M%SZ")
      "#{location}.backup-#{timestamp}.tar.gz"
    end

    def archive_installation(location, backup_path)
      parent = File.dirname(location)
      basename = File.basename(location)
      _stdout, stderr, status = Open3.capture3("tar", "-czf", backup_path, "-C", parent, basename)
      raise SystemCallError.new("tar failed: #{stderr}") unless status.success?
    end
  end
end

