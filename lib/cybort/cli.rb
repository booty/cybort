require "fileutils"
require "json"
require "optparse"

module Cybort
  module CLI
    module_function

    def start(argv, out: $stdout, err: $stderr, home: Dir.home, input: $stdin, http_client: nil, registry: nil,
              clock: -> { Time.now.utc }, command_runner: nil, dependency_checker: nil,
              monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      args = argv.dup
      if args.first == "init"
        return initialize_installation(args[1] || File.join(home, ".cybort"), input: input, out: out, clock: clock)
      end

      options = parse_options(args, out)
      root = File.join(home, ".cybort")
      configuration = Configuration.load(File.join(root, "cybort.toml"))
      persistence = Persistence.new(File.join(root, "cybort.sqlite3"), clock: clock)
      persistence.setup!
      command_runner ||= CommandRunner.new(monotonic_clock: monotonic_clock)
      dependency_checker ||= DependencyChecker.new(command_runner: command_runner)
      result = Orchestrator.new(
        configuration: configuration,
        persistence: persistence,
        registry: registry || AdapterRegistry.default,
        http_client: http_client || HttpClient.new,
        clock: clock,
        command_runner: command_runner,
        dependency_checker: dependency_checker,
        monotonic_clock: monotonic_clock
      ).run(force_fetch: options.fetch(:force_fetch))

      payload = {
        status: result.overall_status,
        unavailable_dependencies: result.unavailable_dependencies,
        instances: result.instances.map do |status|
          status.to_h.merge(items: persistence.items_for(instance_id: status.instance_id).map(&:to_h))
        end
      }
      out.puts JSON.generate(payload)
      result.overall_status == :success ? 0 : 1
    rescue ConfigurationError, OptionParser::ParseError, SystemCallError => error
      err.puts error.message
      2
    end

    def parse_options(args, out)
      options = { force_fetch: false }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: cybort [--force-fetch]"
        opts.on("--force-fetch", "Ignore adapter TTLs") { options[:force_fetch] = true }
        opts.on("--help", "Show this help") do
          out.puts opts
          exit 0
        end
      end
      parser.parse!(args)
      raise OptionParser::InvalidOption, args.join(" ") unless args.empty?

      options
    end

    def initialize_installation(path, input:, out:, clock:)
      io = Struct.new(:input, :output) do
        def gets
          input.gets
        end

        def puts(message = "")
          output.puts(message)
        end
      end.new(input, out)
      result = Installer.new(io: io, clock: clock).run(location: path)
      out.puts "Initialized Cybort at #{path}" if %i[created reset reset_with_config].include?(result)
      %i[created kept reset reset_with_config].include?(result) ? 0 : 1
    end
  end
end
