require "rubygems"

module Cybort
  Dependency = Struct.new(
    :executable, :purpose, :install_hint, :auth_hint, :version_requirement,
    :environment_keys, keyword_init: true
  ) do
    def initialize(executable:, purpose:, install_hint: nil, auth_hint: nil, version_requirement: nil, environment_keys: [])
      executable = executable.to_s.strip
      purpose = purpose.to_s.strip
      raise ArgumentError, "dependency executable must be nonblank" if executable.empty?
      raise ArgumentError, "dependency purpose must be nonblank" if purpose.empty?
      raise ArgumentError, "dependency environment_keys must be an array" unless environment_keys.is_a?(Array)

      requirement_parts = if version_requirement.is_a?(String)
        version_requirement.split(/\s*,\s*/)
      else
        Array(version_requirement)
      end
      requirement = version_requirement && Gem::Requirement.new(*requirement_parts)
      super(
        executable: executable,
        purpose: purpose,
        install_hint: install_hint&.to_s,
        auth_hint: auth_hint&.to_s,
        version_requirement: requirement,
        environment_keys: environment_keys.map(&:to_s).freeze
      )
      freeze
    end
  end

  DependencyResolution = Struct.new(:dependency, :path, :version, :error, keyword_init: true) do
    def available?
      error.nil? && !path.nil?
    end
  end
end
