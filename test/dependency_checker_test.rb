require_relative "test_helper"

class DependencyCheckerTest < Minitest::Test
  FakeRunner = Struct.new(:result) do
    attr_reader :calls

    def initialize(result)
      super
      @calls = []
    end

    def run(argv, **_options)
      @calls << argv
      result
    end
  end

  def test_resolves_first_regular_executable_from_path_and_deduplicates_entries
    Dir.mktmpdir do |directory|
      executable = File.join(directory, "gws")
      File.write(executable, "#!/bin/sh\n")
      FileUtils.chmod(0o755, executable)
      dependency = Cybort::Dependency.new(executable: "gws", purpose: "test tool")
      checker = Cybort::DependencyChecker.new(command_runner: FakeRunner.new(success_result))

      resolution = checker.resolve(dependency, env: { "PATH" => "#{directory}:#{directory}" })

      assert_equal executable, resolution.path
      assert_nil resolution.error
    end
  end

  def test_treats_empty_path_component_as_current_directory
    Dir.mktmpdir do |directory|
      Dir.chdir(directory) do
        executable = File.join(directory, "local-tool")
        File.write(executable, "#!/bin/sh\n")
        FileUtils.chmod(0o755, executable)
        dependency = Cybort::Dependency.new(executable: "local-tool", purpose: "test tool")
        checker = Cybort::DependencyChecker.new(command_runner: FakeRunner.new(success_result))

        resolution = checker.resolve(dependency, env: { "PATH" => ":/missing" })

        assert_equal File.expand_path("local-tool", Dir.pwd), resolution.path
      end
    end
  end

  def test_rejects_directory_and_reports_missing_install_guidance
    Dir.mktmpdir do |directory|
      dependency = Cybort::Dependency.new(
        executable: "gws",
        purpose: "Google Workspace CLI",
        install_hint: "brew install googleworkspace-cli"
      )
      checker = Cybort::DependencyChecker.new(command_runner: FakeRunner.new(success_result))

      resolution = checker.resolve(dependency, env: { "PATH" => directory })

      assert_nil resolution.path
      assert_equal "missing", resolution.error.fetch(:category)
      assert_equal "brew install googleworkspace-cli", resolution.error.fetch(:install_hint)
    end
  end

  def test_accepts_documented_gws_version
    with_tool("gws") do |directory|
      runner = FakeRunner.new(success_result(stdout: "gws version 0.22.5\n"))
      checker = Cybort::DependencyChecker.new(command_runner: runner)
      dependency = gws_dependency

      resolution = checker.resolve(dependency, env: { "PATH" => directory })

      assert_equal "0.22.5", resolution.version
      assert_nil resolution.error
      assert_equal [File.join(directory, "gws"), "--version"], runner.calls.first
    end
  end

  def test_rejects_unsupported_prerelease_and_malformed_versions
    with_tool("gws") do |directory|
      ["gws version 0.23.0\n", "gws version 0.22.5-rc1\n", "noise 9.9.9\n", "not a version\n"].each do |stdout|
        runner = FakeRunner.new(success_result(stdout: stdout))
        checker = Cybort::DependencyChecker.new(command_runner: runner)

        resolution = checker.resolve(gws_dependency, env: { "PATH" => directory })

        assert_includes %w[unsupported_version version_check_failed], resolution.error.fetch(:category)
      end
    end
  end

  def test_rejects_nonzero_timeout_truncated_or_spawn_failed_version_check
    with_tool("gws") do |directory|
      [
        failure_result,
        success_result(timed_out: true),
        success_result(stdout_truncated: true),
        success_result(spawn_error_category: "not_found")
      ].each do |result|
        checker = Cybort::DependencyChecker.new(command_runner: FakeRunner.new(result))

        resolution = checker.resolve(gws_dependency, env: { "PATH" => directory })

        assert_equal "version_check_failed", resolution.error.fetch(:category)
      end
    end
  end

  def test_validates_second_requirement_without_running_version_command_again
    with_tool("gws") do |directory|
      runner = FakeRunner.new(success_result(stdout: "gws version 0.22.6\n"))
      checker = Cybort::DependencyChecker.new(command_runner: runner)
      first = checker.resolve(gws_dependency, env: { "PATH" => directory })
      second = checker.validate_version!(gws_dependency, first)

      assert_equal first.path, second.path
      assert_equal 1, runner.calls.length
    end
  end

  private

  def gws_dependency
    Cybort::Dependency.new(
      executable: "gws",
      purpose: "Google Workspace CLI",
      version_requirement: ">= 0.22.5, < 0.23.0"
    )
  end

  def success_result(stdout: "", **attributes)
    Cybort::CommandResult.new(
      argv: [], stdout: stdout, stderr: "", status: fake_status,
      timed_out: false, stdout_truncated: false, stderr_truncated: false,
      spawn_error_category: nil, **attributes
    )
  end

  def failure_result(**attributes)
    success_result(status: Struct.new(:success?).new(false), **attributes)
  end

  def fake_status
    Struct.new(:success?).new(true)
  end

  def with_tool(name)
    Dir.mktmpdir do |directory|
      path = File.join(directory, name)
      File.write(path, "#!/bin/sh\n")
      FileUtils.chmod(0o755, path)
      yield directory
    end
  end
end
