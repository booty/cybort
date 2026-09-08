require "fileutils"
require "json"
require "optparse"

module Cybort
  module CLI
    module_function

    def start(argv, out: $stdout, err: $stderr, home: Dir.home, input: $stdin, http_client: nil, registry: nil,
              clock: -> { Time.now.utc }, command_runner: nil, dependency_checker: nil,
              monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
              output_mode: :json)
      args = argv.dup
      if args.first == "init"
        return initialize_installation(args[1] || File.join(home, ".cybort"), input: input, out: out, clock: clock)
      end
      if args.first == "purge"
        return purge_instance(args.drop(1), input: input, out: out, home: home, clock: clock)
      end

      options = parse_options(args, out, output_mode: output_mode)
      root = options.fetch(:root) || File.join(home, ".cybort")
      configuration_path = File.join(root, "cybort.toml")
      unless File.file?(configuration_path)
        raise ConfigurationError,
              "No Cybort configuration found at #{configuration_path}. " \
              "Run `bundle exec bin/cybort init` to create it, then edit the config file and run Cybort again."
      end

      configuration = Configuration.load(configuration_path)
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
        monotonic_clock: monotonic_clock,
        progress: options.fetch(:output_mode) == :diagnostic ? out : nil
      ).run(force_fetch: options.fetch(:force_fetch))

      if options.fetch(:output_mode) == :json
        payload = {
          status: result.overall_status,
          unavailable_dependencies: result.unavailable_dependencies,
          instances: result.instances.map do |status|
            status.to_h.merge(items: persistence.items_for(instance_id: status.instance_id).map(&:to_h))
          end
        }
        out.puts JSON.generate(payload)
      end
      result.overall_status == :success ? 0 : 1
    rescue ConfigurationError, OptionParser::ParseError, SystemCallError => error
      err.puts error.message
      2
    end

    def parse_options(args, out, output_mode:)
      options = { force_fetch: false, output_mode: output_mode, root: nil }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: cybort [--force-fetch] [--json] [--root PATH]"
        opts.on("--force-fetch", "Ignore adapter TTLs") { options[:force_fetch] = true }
        opts.on("--json", "Emit a machine-readable JSON run summary") { options[:output_mode] = :json }
        opts.on("--root PATH", "Use an alternate installation directory") { |path| options[:root] = File.expand_path(path) }
        opts.on("--help", "Show this help") do
          out.puts opts
          exit 0
        end
      end
      parser.parse!(args)
      raise OptionParser::InvalidOption, args.join(" ") unless args.empty?

      options
    end

    def purge_instance(args, input:, out:, home:, clock:)
      options = { confirm: false, backup: nil, root: nil }
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: cybort purge INSTANCE_ID [--yes] [--backup PATH] [--root PATH]"
        opts.on("--yes", "Skip the interactive purge confirmation") { options[:confirm] = true }
        opts.on("--backup PATH", "Create a SQLite backup before deletion") { |path| options[:backup] = path }
        opts.on("--root PATH", "Use an alternate installation directory") { |path| options[:root] = File.expand_path(path) }
        opts.on("--help", "Show this help") do
          out.puts opts
          exit 0
        end
      end
      parser.parse!(args)
      instance_id = args.shift
      raise OptionParser::MissingArgument, "INSTANCE_ID" unless instance_id
      raise OptionParser::InvalidOption, args.join(" ") unless args.empty?

      root = options.fetch(:root) || File.join(home, ".cybort")
      database_path = File.join(root, "cybort.sqlite3")
      raise ConfigurationError, "No Cybort database found at #{database_path}" unless File.file?(database_path)

      persistence = Persistence.new(database_path, clock: clock).setup!
      record = persistence.instance_record(instance_id)
      raise ConfigurationError, "Unknown adapter instance: #{instance_id}" unless record

      unless options[:confirm]
        out.puts "This permanently deletes #{instance_id}'s items, sync state, and fetch history."
        out.puts "Type PURGE #{instance_id} to confirm, or anything else to cancel:"
        return 1 unless input.gets.to_s.strip == "PURGE #{instance_id}"
      end

      backup_path = options[:backup] && persistence.backup_to(options[:backup])
      persistence.delete_instance(instance_id: instance_id)
      out.puts "Purged #{instance_id}.#{backup_path ? " Backup: #{backup_path}" : " No backup was created."}"
      0
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
      out.puts "Initialized Cybort at #{path}; edit #{path}/cybort.toml to configure" if %i[created reset reset_with_config].include?(result)
      %i[created kept reset reset_with_config].include?(result) ? 0 : 1
    end
  end
end
