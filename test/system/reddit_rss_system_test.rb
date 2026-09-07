require "test_helper"

class RedditRssSystemTest < Minitest::Test
  include RedditRssFixture

  class Gate
    Lease = Struct.new(:released, keyword_init: true) do
      def observe(metadata:, status:)
        nil
      end

      def release
        self.released = true
      end
    end

    attr_reader :leases

    def initialize
      @leases = []
    end

    def acquire(operation:, deadline_monotonic:)
      lease = Lease.new(released: false)
      @leases << [operation, deadline_monotonic, lease]
      lease
    end
  end

  class SequenceHttp
    attr_reader :calls

    def initialize(bodies)
      @bodies = bodies.dup
      @calls = []
    end

    def get(url, headers:, timeout_seconds:, deadline_monotonic:)
      @calls << {
        url: url, headers: headers, timeout_seconds: timeout_seconds,
        deadline_monotonic: deadline_monotonic
      }
      value = @bodies.shift
      raise "fixture response queue exhausted" if value.nil?
      raise value if value.is_a?(Exception)

      Cybort::HttpResponse.new(status: 200, headers: {}, body: value)
    end
  end

  class DispatchHttp
    attr_reader :calls

    def initialize(&response)
      @response = response
      @calls = []
    end

    def get(url, headers: {}, timeout_seconds: nil, deadline_monotonic: nil)
      @calls << {
        url: url, headers: headers, timeout_seconds: timeout_seconds,
        deadline_monotonic: deadline_monotonic
      }
      value = @response.call(url)
      raise value if value.is_a?(Exception)

      Cybort::HttpResponse.new(status: 200, headers: {}, body: value)
    end
  end

  Instance = Cybort::Configuration::Instance

  def with_database
    Tempfile.create(["cybort-reddit-rss", ".sqlite3"]) do |file|
      file.close
      yield file.path
    end
  end

  def reddit_instance
    Instance.new(
      id: "reddit_rss", name: "Reddit RSS", adapter: "reddit_rss", ttl_minutes: 15,
      retention_ttl_minutes: nil, num_items_to_fetch: 20,
      options: {
        subreddits: ["ruby", "rails"],
        user_agent: "macos:com.example.cybort:v0.1.0 (by /u/example_user)"
      }
    )
  end

  def configuration(instances = { reddit_rss: reddit_instance })
    Struct.new(:instances).new(instances.transform_keys(&:to_s))
  end

  def registry_for(gate, monotonic_clock)
    registry = Cybort::AdapterRegistry.default
    registry.register(
      "reddit_rss",
      ->(**kwargs) {
        Cybort::Adapters::RedditRSS.new(
          **kwargs.merge(coordinator: gate, monotonic_clock: monotonic_clock)
        )
      },
      validate_configuration: ->(instance) { Cybort::Adapters::RedditRSS.validate_configuration!(instance) }
    )
    registry
  end

  def build_orchestrator(path, http_client, now:, gate:, monotonic_clock: -> { 100.0 }, instances: nil)
    persistence = Cybort::Persistence.new(path, clock: -> { now.call })
    persistence.setup!
    orchestrator = Cybort::Orchestrator.new(
      configuration: configuration(instances || { reddit_rss: reddit_instance }),
      persistence: persistence,
      registry: registry_for(gate, monotonic_clock),
      http_client: http_client,
      clock: -> { now.call },
      monotonic_clock: monotonic_clock
    )
    [orchestrator, persistence]
  end

  def poll_bodies(at:, id: "t3_abc", subreddit: "ruby", title: "A post", published_at: nil)
    published_at ||= at - 60
    entry = atom_entry(id: id, subreddit: subreddit, title: title, published: published_at.iso8601)
    empty = atom([])
    [empty, empty, atom([entry])]
  end

  def empty_poll_bodies
    [atom([]), atom([]), atom([])]
  end

  def write_cli_config(home, body)
    root = File.join(home, ".cybort")
    FileUtils.mkdir_p(root)
    File.write(File.join(root, "cybort.toml"), body)
  end

  def test_two_remote_polls_round_trip_bounded_history_and_warm_cache
    with_database do |path|
      current = Time.utc(2026, 9, 6, 12)
      now = -> { current }
      http = SequenceHttp.new(
        poll_bodies(at: current) + poll_bodies(at: current + 60, title: "Updated", published_at: current - 60)
      )
      gate = Gate.new
      orchestrator, persistence = build_orchestrator(path, http, now: now, gate: gate)

      first = orchestrator.run(force_fetch: true)
      assert_equal :success, first.overall_status
      assert_equal ["t3_abc"], persistence.items_for(instance_id: "reddit_rss").map(&:canonical_id)
      assert_equal 1, persistence.context_for(instance_id: "reddit_rss").fetch(:sync_state).fetch(:polls).length

      current += 60
      second = orchestrator.run(force_fetch: true)
      assert_equal :success, second.overall_status
      state = persistence.context_for(instance_id: "reddit_rss").fetch(:sync_state)
      assert_equal 2, state.fetch(:polls).length
      stored_json = JSON.parse(persistence.instance_record("reddit_rss").fetch("sync_state_json"))
      assert stored_json.key?("polls")
      refute stored_json.key?(:polls)

      cached = orchestrator.run
      assert_equal :success, cached.overall_status
      assert_equal 6, http.calls.length
      assert_equal 2, persistence.fetch_runs_for(instance_id: "reddit_rss").length
      assert_equal 6, gate.leases.length
      assert gate.leases.all? { |_, _, lease| lease.released }
    end
  end

  def test_incomplete_three_feed_attempt_preserves_snapshot_state_and_freshness
    with_database do |path|
      current = Time.utc(2026, 9, 6, 12)
      now = -> { current }
      first_http = SequenceHttp.new(poll_bodies(at: current))
      gate = Gate.new
      orchestrator, persistence = build_orchestrator(path, first_http, now: now, gate: gate)
      assert_equal :success, orchestrator.run(force_fetch: true).overall_status
      old_items = persistence.items_for(instance_id: "reddit_rss").map(&:canonical_id)
      old_state = persistence.instance_record("reddit_rss").fetch("sync_state_json")
      old_fetch = persistence.instance_record("reddit_rss").fetch("last_successful_fetch")

      failing_http = SequenceHttp.new([
        atom([]), atom([]), Cybort::SourceError.new("feed failed")
      ])
      failing, = build_orchestrator(path, failing_http, now: -> { current + 60 }, gate: gate)
      result = failing.run(force_fetch: true)

      assert_equal :failure, result.overall_status
      assert_equal old_items, persistence.items_for(instance_id: "reddit_rss").map(&:canonical_id)
      assert_equal old_state, persistence.instance_record("reddit_rss").fetch("sync_state_json")
      assert_equal old_fetch, persistence.instance_record("reddit_rss").fetch("last_successful_fetch")
      assert_equal %w[successful failed], persistence.fetch_runs_for(instance_id: "reddit_rss").map { |run| run.fetch("status") }
      assert_equal 3, failing_http.calls.length
    end
  end

  def test_each_feed_failure_independently_preserves_prior_snapshot_state_and_freshness
    %w[new rising top].each_with_index do |operation, failure_index|
      with_database do |path|
        current = Time.utc(2026, 9, 6, 12)
        now = -> { current }
        first_http = SequenceHttp.new(poll_bodies(at: current))
        gate = Gate.new
        first, persistence = build_orchestrator(path, first_http, now: now, gate: gate)
        assert_equal :success, first.run(force_fetch: true).overall_status
        old_items = persistence.items_for(instance_id: "reddit_rss").map(&:canonical_id)
        old_state = persistence.instance_record("reddit_rss").fetch("sync_state_json")
        old_fetch = persistence.instance_record("reddit_rss").fetch("last_successful_fetch")

        responses = poll_bodies(at: current)
        responses[failure_index] = "<html>#{operation}-failure-sentinel</html>"
        current += 60
        failing_http = SequenceHttp.new(responses)
        failing, = build_orchestrator(path, failing_http, now: now, gate: gate)
        result = failing.run(force_fetch: true)

        assert_equal :failure, result.overall_status, operation
        status = result.instances.fetch(0)
        assert_equal operation.to_sym, status.metadata.fetch(:operation), operation
        assert_equal old_items, persistence.items_for(instance_id: "reddit_rss").map(&:canonical_id), operation
        assert_equal old_state, persistence.instance_record("reddit_rss").fetch("sync_state_json"), operation
        assert_equal old_fetch, persistence.instance_record("reddit_rss").fetch("last_successful_fetch"), operation
        assert_equal %w[successful failed], persistence.fetch_runs_for(instance_id: "reddit_rss").map { |run| run.fetch("status") }, operation
      end
    end
  end

  def test_empty_three_feed_success_replaces_items_but_retains_bounded_candidates_and_poll
    with_database do |path|
      current = Time.utc(2026, 9, 6, 12)
      now = -> { current }
      first_http = SequenceHttp.new(poll_bodies(at: current))
      gate = Gate.new
      first, persistence = build_orchestrator(path, first_http, now: now, gate: gate)
      assert_equal :success, first.run(force_fetch: true).overall_status

      current += 60
      empty_http = SequenceHttp.new(empty_poll_bodies)
      empty_run, = build_orchestrator(path, empty_http, now: now, gate: gate)
      result = empty_run.run(force_fetch: true)

      assert_equal :success, result.overall_status
      assert_empty persistence.items_for(instance_id: "reddit_rss")
      state = persistence.context_for(instance_id: "reddit_rss").fetch(:sync_state)
      assert_equal 2, state.fetch(:polls).length
      assert state.fetch(:candidates).key?(:t3_abc)
      assert_equal 3, empty_http.calls.length
    end
  end

  def test_reddit_rss_failure_does_not_block_ordinary_rss_success_and_cli_returns_partial_failure
    Dir.mktmpdir("cybort-reddit-rss-mixed") do |home|
      write_cli_config(home, <<~TOML)
        schema_version = 1

        [instances.reddit_rss]
        name = "Reddit RSS"
        adapter = "reddit_rss"
        ttl_minutes = 15
        num_items_to_fetch = 20
        subreddits = ["ruby"]
        user_agent = "macos:com.example.cybort:v0.1.0 (by /u/example_user)"

        [instances.personal_rss]
        name = "Personal RSS"
        adapter = "rss"
        ttl_minutes = 15
        num_items_to_fetch = 5
        url = "https://example.test/feed.xml"
      TOML

      current = Time.utc(2026, 9, 6, 12)
      rss_body = File.read(File.expand_path("../fixtures/rss/basic.xml", __dir__))
      http = DispatchHttp.new do |url|
        if url.include?("reddit.com")
          Cybort::SourceError.new("reddit rss unavailable")
        else
          rss_body
        end
      end
      gate = Gate.new
      out = StringIO.new
      err = StringIO.new
      status = Cybort::CLI.start(
        ["--force-fetch", "--json"], home: home, out: out, err: err,
        http_client: http, registry: registry_for(gate, -> { 100.0 }),
        clock: -> { current }, monotonic_clock: -> { 100.0 }
      )

      assert_equal 1, status
      payload = JSON.parse(out.string)
      assert_equal "partial_failure", payload.fetch("status")
      rss_status = payload.fetch("instances").find { |instance| instance.fetch("id") == "personal_rss" }
      reddit_status = payload.fetch("instances").find { |instance| instance.fetch("id") == "reddit_rss" }
      assert_equal "success", rss_status.fetch("status")
      refute_empty rss_status.fetch("items")
      assert_equal "failure", reddit_status.fetch("status")
      assert_empty reddit_status.fetch("items")
      refute_empty Cybort::Persistence.new(File.join(home, ".cybort", "cybort.sqlite3")).tap(&:setup!).items_for(instance_id: "personal_rss")
      assert_equal 1, http.calls.count { |call| call.fetch(:url).include?("example.test") }
    end
  end

  def test_two_rss_groups_keep_independent_state_and_share_one_injected_gate
    instances = {
      ruby_group: reddit_instance.tap do |value|
        value.id = "ruby_group"
        value.name = "Ruby"
        value.options = value.options.merge(subreddits: ["ruby"])
      end,
      rails_group: reddit_instance.tap do |value|
        value.id = "rails_group"
        value.name = "Rails"
        value.options = value.options.merge(subreddits: ["rails"])
      end
    }
    with_database do |path|
      current = Time.utc(2026, 9, 6, 12)
      ruby_bodies = poll_bodies(at: current, subreddit: "ruby", id: "t3_abc")
      rails_bodies = poll_bodies(at: current, subreddit: "rails", id: "t3_def")
      bodies_by_group = { "/r/ruby/" => ruby_bodies, "/r/rails/" => rails_bodies }
      seen_by_group = Hash.new(0)
      http = DispatchHttp.new do |url|
        marker = bodies_by_group.keys.find { |group| url.include?(group) }
        raise "unexpected group route" unless marker

        body = bodies_by_group.fetch(marker).fetch(seen_by_group[marker])
        seen_by_group[marker] += 1
        body
      end
      gate = Gate.new
      orchestrator, persistence = build_orchestrator(
        path, http, now: -> { current }, gate: gate, instances: instances
      )

      result = orchestrator.run(force_fetch: true)

      assert_equal :success, result.overall_status
      assert_equal ["t3_abc"], persistence.items_for(instance_id: "ruby_group").map(&:canonical_id)
      assert_equal ["t3_def"], persistence.items_for(instance_id: "rails_group").map(&:canonical_id)
      ruby_state = persistence.context_for(instance_id: "ruby_group").fetch(:sync_state)
      rails_state = persistence.context_for(instance_id: "rails_group").fetch(:sync_state)
      assert ruby_state.fetch(:candidates).key?(:t3_abc)
      refute ruby_state.fetch(:candidates).key?(:t3_def)
      assert rails_state.fetch(:candidates).key?(:t3_def)
      refute rails_state.fetch(:candidates).key?(:t3_abc)
      assert_equal 6, gate.leases.length
      assert_equal 6, http.calls.length
      assert_equal 3, http.calls.count { |call| call.fetch(:url).include?("/r/ruby/") }
      assert_equal 3, http.calls.count { |call| call.fetch(:url).include?("/r/rails/") }
    end
  end

  def test_replacement_transaction_rollback_restores_selection_state_and_freshness
    with_database do |path|
      current = Time.utc(2026, 9, 6, 12)
      instance = reddit_instance
      persistence = Cybort::Persistence.new(path, clock: -> { current })
      persistence.setup!
      persistence.register_instance(instance)
      gate = Gate.new

      first_adapter = Cybort::Adapters::RedditRSS.new(
        instance: instance,
        context: persistence.context_for(instance_id: instance.id),
        http_client: SequenceHttp.new(poll_bodies(at: current)),
        coordinator: gate,
        clock: -> { current }, monotonic_clock: -> { 100.0 }
      )
      persistence.write_fetch_result(first_adapter.fetch(fetch_mode: :remote, planned_at: current))
      old_items = persistence.items_for(instance_id: instance.id).map(&:canonical_id)
      old_state = persistence.instance_record(instance.id).fetch("sync_state_json")
      old_fetch = persistence.instance_record(instance.id).fetch("last_successful_fetch")

      current += 60
      second_adapter = Cybort::Adapters::RedditRSS.new(
        instance: instance,
        context: persistence.context_for(instance_id: instance.id),
        http_client: SequenceHttp.new(poll_bodies(at: current, id: "t3_def", title: "Replacement")),
        coordinator: gate,
        clock: -> { current }, monotonic_clock: -> { 100.0 }
      )
      replacement = second_adapter.fetch(fetch_mode: :remote, planned_at: current)
      persistence.define_singleton_method(:insert_fetch_run) { |_result, _status| raise "history unavailable" }
      begin
        assert_raises(RuntimeError) { persistence.write_fetch_result(replacement) }
      ensure
        persistence.singleton_class.send(:remove_method, :insert_fetch_run)
      end

      assert_equal old_items, persistence.items_for(instance_id: instance.id).map(&:canonical_id)
      assert_equal old_state, persistence.instance_record(instance.id).fetch("sync_state_json")
      assert_equal old_fetch, persistence.instance_record(instance.id).fetch("last_successful_fetch")
      assert_equal ["successful"], persistence.fetch_runs_for(instance_id: instance.id).map { |run| run.fetch("status") }
    end
  end

  def test_diagnostics_and_history_are_safe_while_success_metadata_contains_counts_and_flags
    Dir.mktmpdir("cybort-reddit-rss-safe-output") do |home|
      write_cli_config(home, <<~TOML)
        schema_version = 1

        [instances.reddit_rss]
        name = "Reddit RSS"
        adapter = "reddit_rss"
        ttl_minutes = 15
        num_items_to_fetch = 20
        subreddits = ["ruby"]
        user_agent = "macos:com.example.cybort:v0.1.0 (by /u/body-author-ua-sentinel)"
      TOML

      current = Time.utc(2026, 9, 6, 12)
      gate = Gate.new
      success_http = SequenceHttp.new(poll_bodies(at: current))
      success_out = StringIO.new
      success_err = StringIO.new
      success_status = Cybort::CLI.start(
        ["--force-fetch", "--json"], home: home, out: success_out, err: success_err,
        http_client: success_http, registry: registry_for(gate, -> { 100.0 }),
        clock: -> { current }, monotonic_clock: -> { 100.0 }
      )
      assert_equal 0, success_status
      metadata = JSON.parse(success_out.string).fetch("instances").first.fetch("metadata")
      assert_equal %w[new_count top_count rising_count observed_candidate_count
                      signalled_candidate_count selected_count history_count
                      future_exclusion_count confidence].sort,
                   metadata.keys.grep(/count|confidence/).sort
      assert metadata.fetch("confidence").key?("observed_only")

      current += 60
      failure_http = SequenceHttp.new([
        atom([]), atom([]), "<html>BODY_AUTHOR_ERROR_SENTINEL</html>"
      ])
      diagnostic_out = StringIO.new
      diagnostic_err = StringIO.new
      diagnostic_status = Cybort::CLI.start(
        ["--force-fetch"], home: home, out: diagnostic_out, err: diagnostic_err,
        http_client: failure_http, registry: registry_for(gate, -> { 100.0 }),
        clock: -> { current }, monotonic_clock: -> { 100.0 }, output_mode: :diagnostic
      )
      assert_equal 1, diagnostic_status
      output = diagnostic_out.string + diagnostic_err.string
      refute_includes output, "BODY_AUTHOR_ERROR_SENTINEL"
      refute_includes output, "body-author-ua-sentinel"

      persistence = Cybort::Persistence.new(File.join(home, ".cybort", "cybort.sqlite3"))
      history = persistence.fetch_runs_for(instance_id: "reddit_rss")
      refute_includes history.last.fetch("error_message"), "BODY_AUTHOR_ERROR_SENTINEL"
      refute_includes history.last.fetch("metadata_json"), "body-author-ua-sentinel"
      refute_includes history.last.fetch("metadata_json"), "BODY_AUTHOR_ERROR_SENTINEL"
      assert_includes history.first.fetch("metadata_json"), "top_count"
      assert_includes history.first.fetch("metadata_json"), "confidence"
    end
  end

  def test_cli_uses_explicit_reddit_rss_registry_factory_with_local_config
    Dir.mktmpdir("cybort-reddit-rss-cli") do |home|
      root = File.join(home, ".cybort")
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "cybort.toml"), <<~TOML)
        schema_version = 1

        [instances.reddit_rss]
        name = "Reddit RSS"
        adapter = "reddit_rss"
        ttl_minutes = 15
        num_items_to_fetch = 20
        subreddits = ["ruby", "rails"]
        user_agent = "macos:com.example.cybort:v0.1.0 (by /u/example_user)"
      TOML

      current = Time.utc(2026, 9, 6, 12)
      http = SequenceHttp.new(poll_bodies(at: current))
      gate = Gate.new
      registry = registry_for(gate, -> { 100.0 })
      out = StringIO.new
      err = StringIO.new
      status = Cybort::CLI.start(
        ["--force-fetch", "--json"],
        home: home,
        out: out,
        err: err,
        http_client: http,
        registry: registry,
        clock: -> { current },
        monotonic_clock: -> { 100.0 }
      )

      assert_equal 0, status
      assert_empty err.string
      payload = JSON.parse(out.string)
      assert_equal "success", payload.fetch("status")
      assert_equal ["t3_abc"], payload.fetch("instances").first.fetch("items").map { |item| item.fetch("canonical_id") }
      assert_equal 3, http.calls.length
    end
  end
end
