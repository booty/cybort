require "open3"

module Cybort
  CommandResult = Struct.new(
    :argv, :stdout, :stderr, :status, :timed_out,
    :stdout_truncated, :stderr_truncated, :spawn_error_category,
    keyword_init: true
  )

  class CommandRunner
    BASE_ENV_KEYS = %w[HOME PATH TMPDIR].freeze
    CHUNK_BYTES = 16 * 1024
    TERM_GRACE_SECONDS = 0.25
    DRAIN_GRACE_SECONDS = 0.25

    def initialize(monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, sleeper: ->(seconds) { sleep(seconds) })
      @monotonic_clock = monotonic_clock
      @sleeper = sleeper
    end

    def run(argv, env: {}, allowed_env_keys: [], timeout_seconds: 30, max_output_bytes: 1_048_576)
      validate_arguments!(argv, env, allowed_env_keys, timeout_seconds, max_output_bytes)
      child_env = child_environment(env, allowed_env_keys)
      executable = argv.fetch(0)
      started_at = monotonic_clock.call

      stdin = stdout = stderr = wait_thread = nil
      readers = []
      timed_out = false
      status = nil
      stdout_data = ["", false]
      stderr_data = ["", false]

      begin
        stdin, stdout, stderr, wait_thread = Open3.popen3(
          child_env,
          executable,
          *argv.drop(1),
          unsetenv_others: true,
          pgroup: true
        )
        stdin.close

        readers = [
          Thread.new { stdout_data = read_stream(stdout, max_output_bytes) },
          Thread.new { stderr_data = read_stream(stderr, max_output_bytes) }
        ]

        deadline = started_at + timeout_seconds
        until wait_thread.join(0.01)
          next if monotonic_clock.call < deadline

          timed_out = true
          terminate_process_group(wait_thread, deadline: deadline)
          break
        end
        status = wait_thread.value

        drain_deadline = [deadline, monotonic_clock.call + DRAIN_GRACE_SECONDS].min
        while readers.any?(&:alive?) && monotonic_clock.call < drain_deadline
          @sleeper.call(0.005)
        end
        if readers.any?(&:alive?)
          timed_out = true
          terminate_process_group(wait_thread, deadline: drain_deadline)
          close_quietly(stdout)
          close_quietly(stderr)
        end
      rescue SystemCallError => error
        return CommandResult.new(
          argv: argv.dup.freeze,
          stdout: "",
          stderr: "",
          status: nil,
          timed_out: false,
          stdout_truncated: false,
          stderr_truncated: false,
          spawn_error_category: spawn_error_category(error)
        )
      ensure
        close_quietly(stdin)
        close_quietly(stdout)
        close_quietly(stderr)
        readers.each { |reader| reader.join(1) }
        if wait_thread && wait_thread.alive?
          terminate_process_group(wait_thread, deadline: monotonic_clock.call)
          wait_thread.join(1)
        end
      end

      CommandResult.new(
        argv: argv.dup.freeze,
        stdout: stdout_data.fetch(0),
        stderr: stderr_data.fetch(0),
        status: status,
        timed_out: timed_out,
        stdout_truncated: stdout_data.fetch(1),
        stderr_truncated: stderr_data.fetch(1),
        spawn_error_category: nil
      )
    end

    private

    attr_reader :monotonic_clock

    def validate_arguments!(argv, env, allowed_env_keys, timeout_seconds, max_output_bytes)
      raise ArgumentError, "command argv must be a non-empty array" unless argv.is_a?(Array) && !argv.empty?
      raise ArgumentError, "command executable must be an absolute path" unless argv.first.is_a?(String) && argv.first.start_with?("/")
      raise ArgumentError, "command arguments must be strings" unless argv.all? { |argument| argument.is_a?(String) }
      raise ArgumentError, "command environment must be a hash" unless env.is_a?(Hash)
      raise ArgumentError, "allowed environment keys must be an array" unless allowed_env_keys.is_a?(Array)
      unless timeout_seconds.is_a?(Numeric) && timeout_seconds.finite? && timeout_seconds.positive?
        raise ArgumentError, "command timeout must be a positive finite number"
      end
      raise ArgumentError, "command output limit must be a nonnegative integer" unless max_output_bytes.is_a?(Integer) && max_output_bytes >= 0
    end

    def child_environment(env, allowed_env_keys)
      allowed = (BASE_ENV_KEYS + allowed_env_keys.map(&:to_s)).uniq
      env.each_key do |key|
        key = key.to_s
        next if allowed.include?(key) || key.start_with?("CYBORT_")

        raise ArgumentError, "environment key is not allowed: #{key}"
      end

      inherited = ENV.each_with_object({}) do |(key, value), result|
        result[key] = value if BASE_ENV_KEYS.include?(key)
      end
      inherited.merge(env.transform_keys(&:to_s))
    end

    def read_stream(io, max_output_bytes)
      output = +""
      truncated = false
      loop do
        chunk = io.readpartial(CHUNK_BYTES)
        if output.bytesize < max_output_bytes
          remaining = max_output_bytes - output.bytesize
          output << chunk.byteslice(0, remaining)
        end
        truncated ||= output.bytesize + (chunk.bytesize > [max_output_bytes - output.bytesize, 0].max ? 1 : 0) > max_output_bytes
      end
    rescue EOFError, IOError
      [output, truncated]
    end

    def terminate_process_group(wait_thread, deadline:)
      pid = wait_thread.pid
      begin
        Process.kill("TERM", -pid)
      rescue Errno::ESRCH, Errno::EPERM
        return
      end

      while wait_thread.alive? && monotonic_clock.call < deadline + TERM_GRACE_SECONDS
        @sleeper.call(0.005)
      end
      if wait_thread.alive?
        begin
          Process.kill("KILL", -pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
      end
      wait_thread.join(1)
    end

    def spawn_error_category(error)
      case error
      when Errno::ENOENT
        "not_found"
      when Errno::EACCES, Errno::EPERM
        "permission"
      else
        "other"
      end
    end

    def close_quietly(io)
      io&.close unless io.nil? || io.closed?
    rescue IOError
      nil
    end
  end
end
