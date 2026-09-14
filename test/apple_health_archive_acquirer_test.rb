require "test_helper"

class AppleHealthArchiveAcquirerTest < Minitest::Test
  def setup
    @root = File.realpath(Dir.mktmpdir)
    @source = File.join(@root, "exports")
    @temp = File.join(@root, "tmp")
    FileUtils.mkdir_p(@source)
    @acquirer = Cybort::AppleHealthArchiveAcquirer.new(
      temp_directory: @temp, wall_clock: -> { Time.utc(2026, 9, 13, 12) },
      monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    )
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_validates_private_directory_and_discovers_sorted_immediate_zip_children
    File.write(File.join(@source, "b.ZIP"), "b")
    File.write(File.join(@source, ".a.zip"), "a")
    FileUtils.mkdir_p(File.join(@source, "nested"))
    File.write(File.join(@source, "nested", "ignored.zip"), "ignored")

    result = @acquirer.validate_directory(@source)
    assert_equal File.realpath(@source), result.fetch(:path)
    assert_equal [".a.zip", "b.ZIP"],
                 @acquirer.candidate_paths(directory: @source).map { |path| File.basename(path) }
  end

  def test_rejects_zip_named_symlink_without_exposing_path
    target = File.join(@source, "target.zip")
    File.write(target, "bytes")
    File.symlink(target, File.join(@source, "link.zip"))

    error = assert_raises(Cybort::AppleHealthError) do
      @acquirer.candidate_paths(directory: @source)
    end
    assert_equal :directory_unsafe, error.safe_metadata.fetch(:category)
    refute_includes error.message, "link.zip"
    refute_includes error.message, @source
  end

  def test_acquires_a_private_copy_and_hashes_all_bytes
    source_path = File.join(@source, "export.zip")
    contents = ("archive-data\0" * 10_000).b
    File.binwrite(source_path, contents)

    archive = @acquirer.acquire(source_path: source_path, candidate_ordinal: 1)
    assert File.file?(archive.path)
    assert archive.path.start_with?("#{File.expand_path(@temp)}/")
    assert_equal contents.bytesize, archive.compressed_bytes
    assert_equal Digest::SHA256.hexdigest(contents), archive.archive_sha256
    assert_equal 0o600, File.stat(archive.path).mode & 0o777
    assert_equal contents, File.binread(archive.path)
    @acquirer.release(archive)
    refute File.exist?(archive.path)
  end

  def test_cleanup_orphans_removes_only_reserved_regular_files
    orphan = File.join(@temp, "#{Cybort::AppleHealthArchiveAcquirer::ARCHIVE_PREFIX}orphan")
    File.write(orphan, "stale")
    File.utime(Time.at(0), Time.at(0), orphan)
    symlink = File.join(@temp, "#{Cybort::AppleHealthArchiveAcquirer::ARCHIVE_PREFIX}link")
    File.symlink(orphan, symlink)

    @acquirer.cleanup_orphans!
    refute File.exist?(orphan)
    assert File.symlink?(symlink)
  end

  def test_constructor_cleans_stale_orphan_directories_but_keeps_fresh_artifacts
    stale_file = File.join(@temp, "#{Cybort::AppleHealthArchiveAcquirer::ARCHIVE_PREFIX}stale")
    fresh_file = File.join(@temp, "#{Cybort::AppleHealthArchiveAcquirer::ARCHIVE_PREFIX}fresh")
    File.write(stale_file, "stale")
    File.write(fresh_file, "fresh")
    File.utime(Time.at(0), Time.at(0), stale_file)

    stale_directory = File.join(@temp, "#{Cybort::AppleHealthArchiveAcquirer::ARCHIVE_PREFIX}directory")
    Dir.mkdir(stale_directory, 0o700)
    stale_payload = File.join(stale_directory, "#{Cybort::AppleHealthArchiveAcquirer::ARCHIVE_PREFIX}payload")
    File.write(stale_payload, "stale")
    File.utime(Time.at(0), Time.at(0), stale_payload)
    File.utime(Time.at(0), Time.at(0), stale_directory)
    nested_symlink = File.join(stale_directory, "#{Cybort::AppleHealthArchiveAcquirer::ARCHIVE_PREFIX}link")
    File.symlink(stale_payload, nested_symlink)

    Cybort::AppleHealthArchiveAcquirer.new(
      temp_directory: @temp, wall_clock: -> { Time.utc(2026, 9, 13, 12) }
    )

    refute File.exist?(stale_file)
    assert File.file?(fresh_file)
    assert File.symlink?(nested_symlink)
    assert Dir.exist?(stale_directory)
  end

  def test_yields_the_acquired_descriptor_and_preserves_consumer_errors
    source_path = File.join(@source, "export.zip")
    File.binwrite(source_path, "archive-data")
    archive = @acquirer.acquire(source_path: source_path, candidate_ordinal: 1)

    assert_equal "archive-data", @acquirer.with_archive_io(archive, &:read)
    assert_raises(IOError) do
      @acquirer.with_archive_io(archive) { raise IOError, "consumer failure" }
    end

    @acquirer.release(archive)
  end

  def test_partial_response_frame_honors_deadline_without_blocking_on_read
    reader, writer = IO.pipe
    payload = JSON.generate({ "status" => "ok" })
    writer.write([payload.bytesize].pack("N"))
    writer.write(payload.byteslice(0, 1))
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.05
    error = nil
    thread = Thread.new do
      begin
        @acquirer.send(:read_frame, reader, 1024, deadline: deadline)
      rescue StandardError => caught
        error = caught
      end
    end

    thread.join(1)
    refute thread.alive?, "partial frame read exceeded its deadline"
    assert_instance_of Timeout::Error, error
  ensure
    writer&.close unless writer&.closed?
    reader&.close unless reader&.closed?
    thread&.kill if thread&.alive?
    thread&.join
  end

  def test_process_reaping_honors_deadline
    pid = Process.spawn(RbConfig.ruby, "-e", "sleep 5")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.05

    assert_raises(Timeout::Error) do
      @acquirer.send(:wait_for_process, pid, deadline: deadline)
    end
  ensure
    if pid
      begin
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        nil
      end
      begin
        Process.waitpid(pid)
      rescue Errno::ECHILD, Errno::ESRCH
        nil
      end
    end
  end

  def test_terminate_process_detaches_when_reap_deadline_expires
    calls = []
    monotonic_values = [10.0, 10.2]
    acquirer = Cybort::AppleHealthArchiveAcquirer.new(
      temp_directory: @temp, wall_clock: -> { Time.utc(2026, 9, 13, 12) },
      monotonic_clock: -> { monotonic_values.shift || 10.2 }
    )
    process_singleton = Process.singleton_class
    originals = {
      kill: Process.method(:kill), waitpid: Process.method(:waitpid),
      detach: Process.method(:detach)
    }
    originals.each_key { |name| process_singleton.send(:remove_method, name) }
    process_singleton.define_method(:kill) do |signal, pid|
      calls << [:kill, signal, pid]
    end
    process_singleton.define_method(:waitpid) do |pid, flags|
      calls << [:waitpid, pid, flags]
      nil
    end
    process_singleton.define_method(:detach) do |pid|
      calls << [:detach, pid]
      :detached
    end

    acquirer.send(:terminate_process, 123, deadline: 10.0)

    assert_equal [
      [:kill, "KILL", 123],
      [:waitpid, 123, Process::WNOHANG],
      [:detach, 123]
    ], calls
  ensure
    originals&.each do |name, method|
      process_singleton.send(:remove_method, name) if process_singleton.instance_methods(false).include?(name)
      process_singleton.define_method(name, method)
    end
  end

  def test_injected_supervisor_call_honors_deadline
    source_path = File.join(@source, "export.zip")
    File.binwrite(source_path, "archive-data")
    started = Queue.new
    release = Queue.new
    supervisor = lambda do |**_arguments|
      started << true
      release.pop
      { "status" => "changed" }
    end
    acquirer = Cybort::AppleHealthArchiveAcquirer.new(
      temp_directory: @temp, wall_clock: -> { Time.utc(2026, 9, 13, 12) },
      timeout_seconds: 0.05, process_supervisor: supervisor
    )
    error = nil
    worker = Thread.new do
      begin
        acquirer.acquire(source_path: source_path, candidate_ordinal: 1)
      rescue StandardError => caught
        error = caught
      end
    end

    started.pop
    joined = worker.join(0.2)
    refute_nil joined, "blocking supervisor exceeded its deadline"
    unless joined
      release << true
      worker.join
    end
    refute worker.alive?
    assert_instance_of Cybort::AppleHealthError, error
    assert_equal :archive_acquisition_timeout, error.safe_metadata.fetch(:category)
  ensure
    release&.close rescue nil
    worker&.kill if worker&.alive?
    worker&.join
  end
end
