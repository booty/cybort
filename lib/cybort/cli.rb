require "fileutils"
require "json"
require "optparse"

module Cybort
  module CLI
    module_function

    def start(argv, out: $stdout, err: $stderr, home: Dir.home, http_client: nil, registry: nil, clock: -> { Time.now.utc })
      args = argv.dup
      if args.first == "init"
        return initialize_installation(args[1] || File.join(home, ".cybort"), out: out, clock: clock)
      end

      options = parse_options(args, out)
      root = File.join(home, ".cybort")
      configuration = Configuration.load(File.join(root, "cybort.toml"))
      persistence = Persistence.new(File.join(root, "cybort.sqlite3"), clock: clock)
      persistence.setup!
      result = Orchestrator.new(
        configuration: configuration,
        persistence: persistence,
        registry: registry || AdapterRegistry.default,
        http_client: http_client || HttpClient.new,
        clock: clock
      ).run(force_fetch: options.fetch(:force_fetch))

      payload = {
        status: result.overall_status,
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

    def initialize_installation(path, out:, clock:)
      FileUtils.mkdir_p(path)
      config_path = File.join(path, "cybort.toml")
      File.write(config_path, "schema_version = 1\n") unless File.exist?(config_path)
      Persistence.new(File.join(path, "cybort.sqlite3"), clock: clock).setup!
      out.puts "Initialized Cybort at #{path}"
      0
    end
  end
end

