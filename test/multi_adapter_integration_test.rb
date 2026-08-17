require "test_helper"

class MultiAdapterIntegrationTest < Minitest::Test
  CONFIGURATION = File.expand_path("fixtures/configuration/rss_and_github.toml", __dir__)
  RSS_BODY = File.read(File.expand_path("fixtures/rss/basic.xml", __dir__))
  GITHUB_BODY = File.read(File.expand_path("fixtures/github/notifications.json", __dir__))

  class CoordinatedHttpClient
    attr_reader :calls

    def initialize(fail_github: false)
      @fail_github = fail_github
      @started = Queue.new
      @release = Queue.new
      @calls = []
    end

    def wait_for_requests(count)
      count.times { @started.pop }
    end

    def release_requests(count)
      count.times { @release << true }
    end

    def get(url, headers: {})
      @calls << [url, headers]
      @started << url
      @release.pop
      raise Cybort::SourceError, "GitHub unavailable" if @fail_github && url.include?("notifications")

      body = url.include?("notifications") ? GITHUB_BODY : RSS_BODY
      Cybort::HttpResponse.new(status: 200, headers: {}, body: body)
    end
  end

  def with_database
    Tempfile.create(["cybort-integration", ".sqlite3"]) do |file|
      file.close
      yield file.path
    end
  end

  def build_orchestrator(path, client)
    configuration = Cybort::Configuration.load(CONFIGURATION)
    persistence = Cybort::Persistence.new(path, clock: -> { Time.utc(2026, 8, 16, 12) })
    persistence.setup!
    orchestrator = Cybort::Orchestrator.new(
      configuration: configuration,
      persistence: persistence,
      registry: Cybort::AdapterRegistry.default,
      http_client: client,
      clock: -> { Time.utc(2026, 8, 16, 12) }
    )
    [orchestrator, persistence]
  end

  def test_rss_and_github_persist_in_one_database
    with_database do |path|
      client = CoordinatedHttpClient.new
      orchestrator, persistence = build_orchestrator(path, client)
      run_thread = Thread.new { orchestrator.run(force_fetch: true) }

      client.wait_for_requests(2)
      assert_empty persistence.items_for
      client.release_requests(2)
      result = run_thread.value

      assert_equal :success, result.overall_status
      assert_equal ["github", "rss"], persistence.items_for.map(&:instance_id).uniq.sort
      assert_equal 2, client.calls.length
    end
  end

  def test_github_failure_does_not_roll_back_rss
    with_database do |path|
      first_client = CoordinatedHttpClient.new
      orchestrator, persistence = build_orchestrator(path, first_client)
      first_thread = Thread.new { orchestrator.run(force_fetch: true) }
      first_client.wait_for_requests(2)
      first_client.release_requests(2)
      assert_equal :success, first_thread.value.overall_status

      second_client = CoordinatedHttpClient.new(fail_github: true)
      second_orchestrator, = build_orchestrator(path, second_client)
      second_thread = Thread.new { second_orchestrator.run(force_fetch: true) }
      second_client.wait_for_requests(2)
      second_client.release_requests(2)
      result = second_thread.value

      assert_equal :partial_failure, result.overall_status
      assert_equal 2, persistence.items_for(instance_id: "rss").length
      assert_equal 2, persistence.items_for(instance_id: "github").length
      assert_equal "failed", persistence.fetch_runs_for(instance_id: "github").last.fetch("status")
    end
  end
end
