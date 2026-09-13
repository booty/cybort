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
    symlink = File.join(@temp, "#{Cybort::AppleHealthArchiveAcquirer::ARCHIVE_PREFIX}link")
    File.symlink(orphan, symlink)

    @acquirer.cleanup_orphans!
    refute File.exist?(orphan)
    assert File.symlink?(symlink)
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
end
