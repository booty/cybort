require "digest"
require "fileutils"
require "json"
require "rbconfig"
require "securerandom"
require "timeout"

module Cybort
  AppleHealthAcquiredArchive = Data.define(
    :path, :archive_sha256, :compressed_bytes, :source_started_at
  )

  class AppleHealthArchiveAcquirer
    ARCHIVE_PREFIX = "cybort-apple-health-archive-"
    HELPER_PATH = File.expand_path("../../script/apple_health_archive_copy_helper.rb", __dir__)
    MAX_REQUEST_BYTES = 16 * 1024
    MAX_RESPONSE_BYTES = 16 * 1024
    MAX_COMPRESSED_BYTES = 4 * 1024 * 1024 * 1024

    def initialize(temp_directory:, wall_clock: -> { Time.now.utc },
                   monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                   timeout_seconds: 600, process_supervisor: nil, stat_provider: nil)
      @temp_directory = File.expand_path(temp_directory.to_s)
      @wall_clock = wall_clock
      @monotonic_clock = monotonic_clock
      @timeout_seconds = timeout_seconds
      @process_supervisor = process_supervisor
      @stat_provider = stat_provider || ->(path) { File.lstat(path) }
      @acquired_identities = {}
      @destination_directories = {}
      validate_constructor!
      prepare_temp_directory!
    end

    def validate_directory(path)
      expanded = expand_path(path)
      ensure_separate_from_temp!(expanded)
      stat = lstat(expanded)
      unless stat.directory? && !stat.symlink?
        raise_error(:directory, :directory_unsafe)
      end
      ensure_owner!(stat, :directory)
      ensure_not_group_or_other_writable!(stat, :directory)
      warnings = (stat.mode & 0o044).positive? ? [:broader_read_permissions] : []
      canonical = File.realpath(expanded)
      ensure_separate_from_temp!(canonical)
      current_stat = lstat(expanded)
      unless current_stat.directory? && !current_stat.symlink? &&
             stat_identity(current_stat) == stat_identity(stat)
        raise_error(:directory, :directory_unsafe)
      end
      { path: canonical, warnings: warnings.freeze }.freeze
    rescue AppleHealthError
      raise
    rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR, Errno::ELOOP
      raise_error(:directory, :directory_unavailable)
    end

    def candidate_paths(directory:)
      validated = validate_directory(directory)
      names = Dir.each_child(validated.fetch(:path)).to_a
      candidates = names.select { |name| name.b.downcase.end_with?(".zip") }
      raise_error(:directory, :too_many_archives, limit_name: :archive_count,
                  counts: { candidate_count: candidates.length }) if candidates.length > 128

      candidates.sort_by!(&:b)
      candidates.each_with_index.map do |name, index|
        path = File.join(validated.fetch(:path), name)
        stat = lstat(path)
        unless stat.file? && !stat.symlink?
          raise_error(:directory, :directory_unsafe, candidate_ordinal: index + 1)
        end
        ensure_owner!(stat, :directory, candidate_ordinal: index + 1)
        ensure_not_group_or_other_writable!(stat, :directory, candidate_ordinal: index + 1)
        path
      end.freeze
    rescue AppleHealthError
      raise
    rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR, Errno::ELOOP
      raise_error(:directory, :directory_unavailable)
    end

    def acquire(source_path:, candidate_ordinal: nil)
      source_path = File.expand_path(source_path.to_s)
      ensure_separate_from_temp!(source_path)
      started_at = wall_time
      destination = nil
      destination_was_absent = false
      helper_responded = false
      destination_owned = false
      destination_identity = nil
      captured_stat = lstat(source_path)
      unless captured_stat.file? && !captured_stat.symlink?
        raise_error(:acquisition, :archive_changed_during_acquisition,
                    candidate_ordinal: candidate_ordinal)
      end
      ensure_owner!(captured_stat, :acquisition, candidate_ordinal: candidate_ordinal)
      ensure_not_group_or_other_writable!(captured_stat, :acquisition, candidate_ordinal: candidate_ordinal)
      destination = new_destination
      destination_was_absent = destination_absent?(destination)
      deadline = monotonic_time + @timeout_seconds
      response = run_copy_helper(
        source_path: source_path, target_path: destination,
        captured_stat: stat_projection(captured_stat), deadline: deadline,
        candidate_ordinal: candidate_ordinal
      )
      helper_responded = true
      destination_owned = response["created"] == true ||
                          (response["status"] == "ok" && !response.key?("created"))
      destination_identity = stat_identity_from_projection(response["target_stat"]) if destination_owned
      validate_copy_response!(response, captured_stat, destination,
                              deadline: deadline, candidate_ordinal: candidate_ordinal)
      ensure_before_deadline!(deadline, candidate_ordinal: candidate_ordinal)
      destination_identity ||= stat_identity(File.lstat(destination))
      @acquired_identities[destination] = destination_identity
      AppleHealthAcquiredArchive.new(
        path: destination, archive_sha256: response.fetch("sha256"),
        compressed_bytes: response.fetch("bytes"), source_started_at: started_at
      )
    rescue Timeout::Error
      cleanup_failed_copy(destination, destination_was_absent, helper_responded,
                          destination_owned, destination_identity)
      raise_error(:acquisition, :archive_acquisition_timeout,
                  candidate_ordinal: candidate_ordinal)
    rescue AppleHealthError
      cleanup_failed_copy(destination, destination_was_absent, helper_responded,
                          destination_owned, destination_identity)
      raise
    rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR, Errno::ELOOP
      cleanup_failed_copy(destination, destination_was_absent, helper_responded,
                          destination_owned, destination_identity)
      raise_error(:acquisition, :archive_changed_during_acquisition,
                  candidate_ordinal: candidate_ordinal)
    rescue Interrupt
      cleanup_failed_copy(destination, destination_was_absent, helper_responded,
                          destination_owned, destination_identity)
      raise
    rescue StandardError
      cleanup_failed_copy(destination, destination_was_absent, helper_responded,
                          destination_owned, destination_identity)
      raise_error(:acquisition, :archive_changed_during_acquisition,
                  candidate_ordinal: candidate_ordinal)
    end

    def release(archive)
      path = archive.respond_to?(:path) ? archive.path : archive.to_s
      return nil unless private_copy?(path)

      identity = @acquired_identities[path]
      return nil unless identity

      remove_private_copy(path, expected_identity: identity)
      @acquired_identities.delete(path)
      nil
    rescue Errno::ENOENT
      nil
    end

    # Yields a descriptor for the exact object acquired by this instance. The
    # consumer must use this boundary instead of reopening the returned path.
    def with_archive_io(archive)
      path = archive.respond_to?(:path) ? archive.path : archive.to_s
      identity = @acquired_identities[path]
      raise_error(:acquisition, :archive_changed_during_acquisition) unless identity

      file = nil
      begin
        file = File.open(path, File::RDONLY | File::NOFOLLOW)
        raise IOError unless stat_identity(file.stat) == identity
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, IOError
        file&.close
        raise_error(:acquisition, :archive_changed_during_acquisition)
      end

      begin
        yield file
      ensure
        file.close unless file.closed?
      end
    end

    def cleanup_orphans!
      Dir.each_child(@temp_directory) do |name|
        next unless name.start_with?(ARCHIVE_PREFIX)

        path = File.join(@temp_directory, name)
        begin
          stat = File.lstat(path)
          if stat.file? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o022).zero?
            FileUtils.rm_f(path)
          elsif stat.directory? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
            cleanup_orphan_directory(path)
          end
        rescue Errno::ENOENT
          next
        end
      end
      self
    end

    private

    def run_copy_helper(source_path:, target_path:, captured_stat:, deadline:, candidate_ordinal:)
      return run_injected_supervisor(source_path: source_path, target_path: target_path,
                                     captured_stat: captured_stat, deadline: deadline,
                                     candidate_ordinal: candidate_ordinal) if @process_supervisor

      pid = nil
      reaped = false
      request_reader, request_writer = IO.pipe
      response_reader, response_writer = IO.pipe
      pid = Process.spawn(
        RbConfig.ruby, HELPER_PATH, in: request_reader, out: response_writer,
        err: File::NULL, close_others: true
      )
      request_reader.close
      response_writer.close
      write_frame(request_writer, {
        "source_path" => source_path, "target_path" => target_path,
        "captured_stat" => captured_stat
      }, deadline: deadline)
      request_writer.close
      response = wait_for_response(response_reader, pid, deadline, candidate_ordinal: candidate_ordinal)
      response_reader.close
      _, status = wait_for_process(pid)
      reaped = true
      ensure_before_deadline!(deadline, candidate_ordinal: candidate_ordinal)
      raise_error(:acquisition, :archive_changed_during_acquisition,
                  candidate_ordinal: candidate_ordinal) unless status.success?
      response
    rescue Errno::EPIPE, IOError
      raise_error(:acquisition, :archive_changed_during_acquisition,
                  candidate_ordinal: candidate_ordinal)
    ensure
      request_reader&.close unless request_reader&.closed?
      request_writer&.close unless request_writer&.closed?
      response_reader&.close unless response_reader&.closed?
      response_writer&.close unless response_writer&.closed?
      terminate_process(pid) unless reaped
    end

    def run_injected_supervisor(source_path:, target_path:, captured_stat:, deadline:, candidate_ordinal:)
      response = @process_supervisor.call(
        source_path: source_path, target_path: target_path,
        captured_stat: captured_stat, deadline: deadline
      )
      unless response.is_a?(Hash)
        raise_error(:acquisition, :archive_changed_during_acquisition,
                    candidate_ordinal: candidate_ordinal)
      end
      ensure_before_deadline!(deadline, candidate_ordinal: candidate_ordinal)
      response
    rescue AppleHealthError
      raise
    rescue Timeout::Error
      raise
    rescue StandardError
      raise_error(:acquisition, :archive_changed_during_acquisition,
                  candidate_ordinal: candidate_ordinal)
    end

    def wait_for_response(reader, _pid, deadline, candidate_ordinal:)
      read_frame(reader, MAX_RESPONSE_BYTES, deadline: deadline)
    rescue JSON::ParserError, IOError
      raise_error(:acquisition, :archive_changed_during_acquisition,
                  candidate_ordinal: candidate_ordinal)
    end

    def validate_copy_response!(response, captured_stat, destination, deadline:, candidate_ordinal:)
      unless response["status"] == "ok"
        category = response["status"] == "size_limit" ? :archive_size_limit : :archive_changed_during_acquisition
        raise_error(:acquisition, category, limit_name: :compressed_bytes,
                    candidate_ordinal: candidate_ordinal) if category == :archive_size_limit
        raise_error(:acquisition, category, candidate_ordinal: candidate_ordinal)
      end
      bytes = response["bytes"]
      expected_digest = response["sha256"]
      unless bytes.is_a?(Integer) && bytes >= 0 && bytes <= MAX_COMPRESSED_BYTES &&
             expected_digest.is_a?(String) && expected_digest.match?(/\A[0-9a-f]{64}\z/)
        raise_error(:acquisition, :archive_changed_during_acquisition,
                    candidate_ordinal: candidate_ordinal)
      end
      destination_stat = File.open(destination, File::RDONLY | File::NOFOLLOW) do |file|
        stat = file.stat
        raise IOError unless stat.file? && !stat.symlink?

        copied_digest = Digest::SHA256.new
        bytes_read = 0
        while (chunk = file.read(1024 * 1024))
          ensure_before_deadline!(deadline, candidate_ordinal: candidate_ordinal)
          copied_digest.update(chunk)
          bytes_read += chunk.bytesize
          raise IOError if bytes_read > MAX_COMPRESSED_BYTES
        end
        [stat, copied_digest.hexdigest, bytes_read]
      end
      stat, destination_digest, destination_bytes = destination_stat
      projections = [response["opened_stat"], response["finished_stat"], response["path_stat"]]
      expected = stat_projection(captured_stat)
      target_projection = response["target_stat"]
      unless stat.file? && !stat.symlink? && projections.all?(expected) &&
             target_projection == stat_projection(stat) &&
             destination_bytes == bytes && destination_digest == expected_digest
        raise_error(:acquisition, :archive_changed_during_acquisition,
                    candidate_ordinal: candidate_ordinal)
      end
    rescue Errno::ENOENT, Errno::EACCES
      raise_error(:acquisition, :archive_changed_during_acquisition,
                  candidate_ordinal: candidate_ordinal)
    end

    def write_frame(io, payload, deadline: nil)
      encoded = JSON.generate(payload)
      raise IOError, "frame too large" if encoded.bytesize > MAX_REQUEST_BYTES

      write_all(io, [encoded.bytesize].pack("N"), deadline: deadline)
      write_all(io, encoded, deadline: deadline)
      io.flush
    end

    def read_frame(io, maximum_bytes, deadline: nil)
      header = read_exact(io, 4, deadline: deadline)
      raise EOFError unless header && header.bytesize == 4

      length = header.unpack1("N")
      raise IOError, "frame too large" if length > maximum_bytes

      payload = read_exact(io, length, deadline: deadline)
      raise EOFError unless payload && payload.bytesize == length

      JSON.parse(payload)
    end

    def read_exact(io, length, deadline: nil)
      result = +"".b
      while result.bytesize < length
        wait_for_io(io, deadline)
        chunk = io.read(length - result.bytesize)
        raise EOFError unless chunk && !chunk.empty?

        result << chunk
      end
      result
    end

    def write_all(io, payload, deadline: nil)
      offset = 0
      while offset < payload.bytesize
        wait_for_writable(io, deadline)
        written = io.write(payload.byteslice(offset, payload.bytesize - offset))
        raise IOError unless written.is_a?(Integer) && written.positive?

        offset += written
      end
    end

    def wait_for_io(io, deadline)
      return if deadline.nil?

      remaining = deadline - monotonic_time
      timeout! if remaining <= 0
      timeout! unless IO.select([io], nil, nil, remaining)
    end

    def wait_for_writable(io, deadline)
      return if deadline.nil?

      remaining = deadline - monotonic_time
      timeout! if remaining <= 0
      timeout! unless IO.select(nil, [io], nil, remaining)
    end

    def destination_absent?(path)
      File.lstat(path)
      false
    rescue Errno::ENOENT
      true
    end

    def private_copy?(path)
      expanded = File.expand_path(path.to_s)
      return false unless expanded.start_with?("#{@temp_directory}/")

      relative = expanded.delete_prefix("#{@temp_directory}/")
      components = relative.split(File::SEPARATOR)
      components.first&.start_with?(ARCHIVE_PREFIX) &&
        File.basename(expanded).start_with?(ARCHIVE_PREFIX)
    end

    def remove_private_copy(path, expected_identity: nil)
      return unless path && private_copy?(path)

      stat = File.lstat(path)
      return false unless stat.file? && !stat.symlink?
      return false if expected_identity && stat_identity(stat) != expected_identity

      FileUtils.rm_f(path)
      remove_destination_directory(path)
      true
    rescue Errno::ENOENT
      remove_destination_directory(path)
      false
    rescue StandardError
      false
    end

    def cleanup_failed_copy(path, destination_was_absent, helper_responded,
                            destination_owned, destination_identity)
      return unless path

      owned = (destination_owned && (destination_identity || destination_was_absent)) ||
              (!helper_responded && destination_was_absent)
      if owned
        remove_private_copy(path, expected_identity: destination_identity)
      end
      remove_destination_directory(path)
    end

    def new_destination
      directory = loop do
        candidate = File.join(@temp_directory, "#{ARCHIVE_PREFIX}#{SecureRandom.hex(16)}")
        begin
          Dir.mkdir(candidate, 0o700)
          break candidate
        rescue Errno::EEXIST
          next
        end
      end
      path = File.join(directory, "#{ARCHIVE_PREFIX}payload.zip")
      @destination_directories[path] = directory
      path
    end

    def remove_destination_directory(path)
      directory = @destination_directories[path]
      return unless directory

      begin
        Dir.rmdir(directory)
        @destination_directories.delete(path)
      rescue Errno::ENOENT
        @destination_directories.delete(path)
      rescue Errno::ENOTEMPTY
        nil
      rescue StandardError
        nil
      end
    end

    def cleanup_orphan_directory(directory)
      Dir.each_child(directory) do |name|
        next unless name.start_with?(ARCHIVE_PREFIX)

        path = File.join(directory, name)
        begin
          stat = File.lstat(path)
          FileUtils.rm_f(path) if stat.file? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o022).zero?
        rescue Errno::ENOENT
          next
        end
      end
      Dir.rmdir(directory)
    rescue Errno::ENOTEMPTY, Errno::ENOENT
      nil
    end

    def prepare_temp_directory!
      if File.exist?(@temp_directory) || File.symlink?(@temp_directory)
        stat = File.lstat(@temp_directory)
        raise ArgumentError, "temporary directory must be a private directory" unless stat.directory? && !stat.symlink?
        raise ArgumentError, "temporary directory has the wrong owner" unless stat.uid == Process.uid
        raise ArgumentError, "temporary directory permissions are too broad" unless (stat.mode & 0o077).zero?
      else
        FileUtils.mkdir_p(@temp_directory)
      end
      File.chmod(0o700, @temp_directory)
      @temp_directory = File.realpath(@temp_directory)
    end

    def expand_path(path)
      raise_error(:directory, :directory_unavailable) unless path.is_a?(String)
      File.expand_path(path)
    end

    def ensure_separate_from_temp!(path)
      expanded = File.expand_path(path)
      canonical = begin
        File.realpath(expanded)
      rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR, Errno::ELOOP
        expanded
      end
      temp = @temp_directory
      if [expanded, canonical].any? { |value| value == temp || value.start_with?("#{temp}/") } ||
         [expanded, canonical].any? { |value| temp == value || temp.start_with?("#{value}/") }
        raise_error(:directory, :directory_unsafe)
      end
    end

    def lstat(path)
      @stat_provider.call(path)
    end

    def ensure_owner!(stat, phase, candidate_ordinal: nil)
      raise_error(phase, :directory_unsafe, candidate_ordinal: candidate_ordinal) unless stat.uid == Process.uid
    end

    def ensure_not_group_or_other_writable!(stat, phase, candidate_ordinal: nil)
      raise_error(phase, :directory_unsafe, candidate_ordinal: candidate_ordinal) unless (stat.mode & 0o022).zero?
    end

    def stat_projection(stat)
      {
        "device" => stat.dev, "inode" => stat.ino, "size" => stat.size,
        "mtime_nsec" => (stat.mtime.to_r * 1_000_000_000).to_i,
        "ctime_nsec" => (stat.ctime.to_r * 1_000_000_000).to_i
      }
    end

    def stat_identity(stat)
      [stat.dev, stat.ino]
    end

    def stat_identity_from_projection(projection)
      return unless projection.is_a?(Hash)
      return unless projection["device"].is_a?(Integer) && projection["inode"].is_a?(Integer)

      [projection["device"], projection["inode"]]
    end

    def wall_time
      value = @wall_clock.call
      raise ArgumentError, "wall clock must return a Time" unless value.is_a?(Time)

      value.utc
    end

    def monotonic_time
      value = Float(@monotonic_clock.call)
      raise ArgumentError, "monotonic clock must return a finite number" unless value.finite?

      value
    rescue ArgumentError, TypeError
      raise ArgumentError, "monotonic clock must return a finite number"
    end

    def timeout!
      raise Timeout::Error
    end

    def wait_for_process(pid)
      loop do
        return Process.wait2(pid)
      rescue Errno::EINTR
        next
      end
    rescue Errno::ECHILD
      raise IOError, "helper process was not waitable"
    end

    def terminate_process(pid)
      return unless pid

      begin
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        nil
      end
      begin
        Process.waitpid(pid)
      rescue Errno::EINTR
        retry
      rescue Errno::ECHILD
        nil
      end
    end

    def ensure_before_deadline!(deadline, candidate_ordinal: nil)
      return if monotonic_time < deadline

      raise_error(:acquisition, :archive_acquisition_timeout,
                  candidate_ordinal: candidate_ordinal)
    end

    def validate_constructor!
      raise ArgumentError, "timeout must be positive" unless @timeout_seconds.is_a?(Numeric) && @timeout_seconds.finite? && @timeout_seconds.positive?
      raise ArgumentError, "wall clock must be callable" unless @wall_clock.respond_to?(:call)
      raise ArgumentError, "monotonic clock must be callable" unless @monotonic_clock.respond_to?(:call)
      if @process_supervisor && !@process_supervisor.respond_to?(:call)
        raise ArgumentError, "process supervisor must be callable"
      end
    end

    def raise_error(phase, category, candidate_ordinal: nil, limit_name: nil, counts: {})
      raise AppleHealthError.new(
        phase: phase, category: category, candidate_ordinal: candidate_ordinal,
        limit_name: limit_name, counts: counts
      )
    end
  end
end
