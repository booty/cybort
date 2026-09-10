require "test_helper"
require "open3"
require "rbconfig"

class InstallationLockTest < Minitest::Test
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
