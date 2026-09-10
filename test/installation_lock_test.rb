require "test_helper"
require "open3"
require "rbconfig"

class InstallationLockTest < Minitest::Test
  def test_symlink_alias_and_real_path_share_one_process_lock
    Dir.mktmpdir do |directory|
      real_root = File.join(directory, "real-cybort")
      alias_root = File.join(directory, "alias-cybort")
      FileUtils.mkdir_p(real_root)
      File.symlink(real_root, alias_root)
      script = <<~'RUBY'
        require "cybort"
        Cybort::InstallationLock.new(ARGV.fetch(0)).synchronize do
          puts "held"
          STDOUT.flush
          STDIN.read
        end
      RUBY
      stdin, stdout, stderr, wait_thread = Open3.popen3(
        RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script, real_root
      )
      assert_equal "held\n", stdout.gets

      alias_lock = Cybort::InstallationLock.new(alias_root)
      real_lock = Cybort::InstallationLock.new(real_root)
      assert_equal real_lock.path, alias_lock.path
      assert_raises(Cybort::InstallationLock::BusyError) do
        alias_lock.synchronize { flunk "lock unexpectedly acquired through symlink alias" }
      end

      stdin.close
      assert wait_thread.value.success?, stderr.read
      assert alias_lock.synchronize { true }
    ensure
      stdin&.close unless stdin&.closed?
      stdout&.close unless stdout&.closed?
      stderr&.close unless stderr&.closed?
      wait_thread&.join
    end
  end

  def test_same_lock_object_contention_does_not_replace_owner_descriptor
    Dir.mktmpdir do |directory|
      lock = Cybort::InstallationLock.new(File.join(directory, "cybort"))
      entered = Queue.new
      release = Queue.new

      owner = Thread.new do
        lock.synchronize do
          entered << true
          release.pop
          :owner_finished
        end
      end
      entered.pop

      contender = Thread.new do
        lock.synchronize { flunk "contending thread unexpectedly acquired the lock" }
      rescue Exception => error # capture the expected cross-thread contention result
        error
      end

      error = contender.value
      release << true
      assert_equal :owner_finished, owner.value
      assert_instance_of Cybort::InstallationLock::BusyError, error

      assert lock.synchronize { true }, "the lock must remain usable after contention"
    end
  end

  def test_lock_file_is_private_and_nonblocking_across_processes
    Dir.mktmpdir do |directory|
      root = File.join(directory, "cybort")
      script = <<~'RUBY'
        require "cybort"
        Cybort::InstallationLock.new(ARGV.fetch(0)).synchronize do
          puts "held"
          STDOUT.flush
          STDIN.read
        end
      RUBY
      stdin, stdout, stderr, wait_thread = Open3.popen3(
        RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script, root
      )
      assert_equal "held\n", stdout.gets
      lock_path = "#{root}.lock"
      assert_equal 0o600, File.stat(lock_path).mode & 0o777

      assert_raises(Cybort::InstallationLock::BusyError) do
        Cybort::InstallationLock.new(root).synchronize { flunk "lock unexpectedly acquired" }
      end

      stdin.close
      assert wait_thread.value.success?, stderr.read
      stdout.close
      stderr.close
      assert Cybort::InstallationLock.new(root).synchronize { true }
    ensure
      stdin&.close unless stdin&.closed?
      stdout&.close unless stdout&.closed?
      stderr&.close unless stderr&.closed?
      wait_thread&.join
    end
  end
end
