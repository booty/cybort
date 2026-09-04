require_relative "test_helper"
require "rbconfig"

class CommandRunnerTest < Minitest::Test
  def setup
    @runner = Cybort::CommandRunner.new(monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @ruby = RbConfig.ruby
  end

  def test_run_passes_arguments_without_shell_interpretation
    Dir.mktmpdir do |directory|
      path = File.join(directory, "should-not-exist")
      result = @runner.run([@ruby, "-e", "puts ARGV.inspect", "a;$(touch #{path})"])

      assert_equal ["a;$(touch #{path})"], JSON.parse(result.stdout)
      assert result.status.success?
      refute_path_exists path
    end
  end

  def test_rejects_empty_argv
    assert_raises(ArgumentError) { @runner.run([]) }
  end

  def test_closes_stdin_so_reader_can_finish
    result = @runner.run([@ruby, "-e", "STDIN.read; puts 'done'"])

    assert_equal "done\n", result.stdout
    refute result.timed_out
  end

  def test_limits_stdout_and_stderr_and_marks_truncation
    result = @runner.run([@ruby, "-e", "$stdout.write('x' * 200); $stderr.write('y' * 200)"], max_output_bytes: 32)

    assert_equal 32, result.stdout.bytesize
    assert_equal 32, result.stderr.bytesize
    assert result.stdout_truncated
    assert result.stderr_truncated
  end

  def test_drains_large_stdout_and_stderr_concurrently
    script = "$stdout.write('x' * 131072); $stderr.write('y' * 131072)"
    result = @runner.run([@ruby, "-e", script], max_output_bytes: 64)

    assert result.stdout_truncated
    assert result.stderr_truncated
    assert result.status.success?
  end

  def test_escalates_when_process_ignores_term
    result = @runner.run(
      [@ruby, "-e", "Signal.trap('TERM') {}; sleep 10"],
      timeout_seconds: 0.05
    )

    assert result.timed_out
    refute_nil result.status
    refute result.status.success?
  end

  def test_terminates_descendant_that_keeps_output_pipes_open
    script = "pid = fork { sleep 10 }; Process.detach(pid); exit 0"
    result = @runner.run([@ruby, "-e", script], timeout_seconds: 0.1, max_output_bytes: 32)

    assert result.timed_out
  end

  def test_does_not_inherit_parent_secret
    ENV["CYBORT_TEST_PARENT_SECRET"] = "not-for-child"
    result = @runner.run([@ruby, "-e", "puts ENV.key?('CYBORT_TEST_PARENT_SECRET')"])

    assert_equal "false\n", result.stdout
  ensure
    ENV.delete("CYBORT_TEST_PARENT_SECRET")
  end

  def test_allows_explicit_connector_environment_key
    result = @runner.run(
      [@ruby, "-e", "puts ENV.fetch('CONNECTOR_SETTING')"],
      env: { "CONNECTOR_SETTING" => "enabled" },
      allowed_env_keys: ["CONNECTOR_SETTING"]
    )

    assert_equal "enabled\n", result.stdout
  end

  def test_classifies_spawn_failures_without_exposing_path
    result = @runner.run(["/definitely/missing/cybort-command"])

    assert_equal "not_found", result.spawn_error_category
    assert_nil result.status
    refute_includes result.stderr, "definitely"
  end

  def test_rejects_invalid_limits
    assert_raises(ArgumentError) { @runner.run([@ruby, "-e", ""], timeout_seconds: 0) }
    assert_raises(ArgumentError) { @runner.run([@ruby, "-e", ""], max_output_bytes: -1) }
  end
end
