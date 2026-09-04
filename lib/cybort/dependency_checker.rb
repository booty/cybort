require "rubygems"

module Cybort
  class DependencyChecker
    VERSION_PATTERN = /^\s*gws(?:\s+version)?\s+v?(\d+\.\d+\.\d+)\s*$/i

    def initialize(command_runner: CommandRunner.new)
      @command_runner = command_runner
    end

    def resolve(dependency, env: ENV.to_h)
      path = find_executable(dependency.executable, env.fetch("PATH", ""))
      return unavailable(dependency, "missing") unless path
      return available(dependency, path, nil) unless dependency.version_requirement

      version = version_for(dependency, path)
      return unavailable(dependency, "version_check_failed", path: path) unless version

      resolution = available(dependency, path, version)
      validate_version!(dependency, resolution)
    rescue ArgumentError, Gem::Requirement::BadRequirementError
      unavailable(dependency, "version_check_failed")
    end

    def validate_version!(dependency, resolution)
      return resolution unless resolution.path
      return available(dependency, resolution.path, resolution.version) unless dependency.version_requirement

      version = resolution.version || version_for(dependency, resolution.path)
      return unavailable(dependency, "version_check_failed", path: resolution.path) unless version
      return available(dependency, resolution.path, version) if dependency.version_requirement.satisfied_by?(Gem::Version.new(version))

      unavailable(dependency, "unsupported_version", path: resolution.path, version: version)
    rescue ArgumentError
      unavailable(dependency, "version_check_failed", path: resolution.path, version: resolution.version)
    end

    private

    def find_executable(executable, path_value)
      seen = {}
      path_value.to_s.split(File::PATH_SEPARATOR, -1).each do |directory|
        directory = Dir.pwd if directory.empty?
        next if seen[directory]

        seen[directory] = true
        candidate = File.expand_path(executable, directory)
        return candidate if File.file?(candidate) && File.executable?(candidate)
      end
      nil
    end

    def version_result_usable?(result)
      result && result.spawn_error_category.nil? && !result.timed_out &&
        !result.stdout_truncated && !result.stderr_truncated && result.status&.success?
    end

    def version_for(dependency, path)
      result = @command_runner.run([path, "--version"], allowed_env_keys: dependency.environment_keys)
      return unless version_result_usable?(result)

      parse_version(result.stdout)
    end

    def parse_version(output)
      line = output.to_s.lines.find { |candidate| candidate.match?(VERSION_PATTERN) }
      match = line&.match(VERSION_PATTERN)
      match && Gem::Version.new(match[1]).to_s
    end

    def available(dependency, path, version)
      DependencyResolution.new(dependency: dependency, path: path, version: version, error: nil)
    end

    def unavailable(dependency, category, path: nil, version: nil)
      DependencyResolution.new(
        dependency: dependency,
        path: path,
        version: version,
        error: {
          category: category,
          executable: dependency.executable,
          purpose: dependency.purpose,
          install_hint: dependency.install_hint,
          auth_hint: dependency.auth_hint
        }.compact.freeze
      )
    end
  end
end
