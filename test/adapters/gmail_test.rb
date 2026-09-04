require "test_helper"

class GmailAdapterTest < Minitest::Test
  FakeStatus = Struct.new(:success?)

  class StubCommandRunner
    attr_reader :calls

    def initialize(list_body:, details: {}, list_result: nil, detail_results: {})
      @list_body = list_body
      @details = details
      @list_result = list_result
      @detail_results = detail_results
      @calls = []
    end

    def run(argv, **options)
      @calls << [argv, options]
      params = JSON.parse(argv.fetch(-1))
      if argv.include?("list")
        @list_result || command_result(stdout: @list_body)
      else
        result = @detail_results.fetch(params.fetch("id"), nil)
        result || command_result(stdout: JSON.generate(@details.fetch(params.fetch("id"))))
      end
    end

    def command_result(stdout:, stderr: "", success: true, timed_out: false, stdout_truncated: false, stderr_truncated: false, spawn_error_category: nil)
      Cybort::CommandResult.new(
        argv: [], stdout: stdout, stderr: stderr, status: FakeStatus.new(success),
        timed_out: timed_out, stdout_truncated: stdout_truncated,
        stderr_truncated: stderr_truncated, spawn_error_category: spawn_error_category
      )
    end
  end

  def test_fetches_deduplicated_messages_and_normalizes_metadata
    runner = StubCommandRunner.new(
      list_body: fixture("list_valid.json"),
      details: { "one" => fixture_json("details/valid_one.json"), "two" => fixture_json("details/valid_two.json") }
    )
    result = adapter(runner).fetch

    assert result.success?
    assert_equal %w[one two], result.items.map(&:canonical_id)
    assert_equal "Quarterly review", result.items.first.title
    assert_equal "A short message preview", result.items.first.body
    assert_equal Time.at(1_786_878_000).utc, result.items.first.remote_created_at
    assert_equal "sender@example.test", result.items.first.info.fetch(:from)
    assert_equal "<one@example.test>", result.items.first.info.fetch(:message_id)
    assert_equal "(no subject)", result.items.last.title
    assert_nil result.items.last.body
    assert_nil result.items.last.remote_created_at
    assert_equal 3, runner.calls.length
    assert_equal fixed_time, result.items.map(&:fetched_at).uniq.first
  end

  def test_constructs_structured_list_and_detail_arguments
    runner = StubCommandRunner.new(
      list_body: fixture("empty.json"),
      details: {}
    )
    adapter_instance = adapter(runner, query: "in:anywhere", num_items_to_fetch: 7)
    adapter_instance.fetch

    list_argv, list_options = runner.calls.first
    list_params = JSON.parse(list_argv.fetch(-1))
    assert_equal({ "userId" => "me", "maxResults" => 7, "q" => "in:anywhere" }, list_params)
    assert_equal 30, list_options.fetch(:timeout_seconds)
    assert_equal "/usr/local/bin/gws", list_argv.first
    assert_equal [
      "/usr/local/bin/gws", "gmail", "users", "messages", "list", "--params", list_argv.fetch(-1)
    ], list_argv

    runner = StubCommandRunner.new(
      list_body: JSON.generate({ "messages" => [{ "id" => "one" }] }),
      details: { "one" => fixture_json("details/valid_one.json") }
    )
    adapter(runner).fetch
    detail_argv, = runner.calls.last
    detail_params = JSON.parse(detail_argv.fetch(-1))
    assert_equal [
      "/usr/local/bin/gws", "gmail", "users", "messages", "get", "--params", detail_argv.fetch(-1)
    ], detail_argv
    assert_equal "metadata", detail_params.fetch("format")
    assert_equal ["Subject", "From", "Date", "Message-ID"], detail_params.fetch("metadataHeaders")
  end

  def test_accepts_empty_list_without_detail_calls
    runner = StubCommandRunner.new(list_body: fixture("empty.json"))
    result = adapter(runner).fetch

    assert result.success?
    assert_empty result.items
    assert_equal 1, runner.calls.length
  end

  def test_rejects_blank_id_and_mismatched_detail_id_without_partial_items
    blank = adapter(StubCommandRunner.new(list_body: fixture("list_blank_id.json"))).fetch
    refute blank.success?
    assert_instance_of Cybort::CommandError, blank.error

    mismatch_runner = StubCommandRunner.new(
      list_body: JSON.generate({ "messages" => [{ "id" => "one" }] }),
      detail_results: { "one" => command_result(stdout: fixture("details/mismatched_id.json")) }
    )
    mismatch = adapter(mismatch_runner).fetch
    refute mismatch.success?
    assert_empty mismatch.items
  end

  def test_rejects_malformed_detail_without_partial_items
    runner = StubCommandRunner.new(
      list_body: JSON.generate({ "messages" => [{ "id" => "one" }] }),
      detail_results: { "one" => command_result(stdout: fixture("details/malformed.json")) }
    )

    result = adapter(runner).fetch

    refute result.success?
    assert_instance_of Cybort::CommandError, result.error
    assert_equal "invalid_json", result.metadata.fetch(:exit_category)
    assert_empty result.items
  end

  def test_rejects_detail_nonzero_timeout_and_truncation_safely
    [
      command_result(stdout: "private@example.test", stderr: "token=private", success: false),
      command_result(stdout: "", timed_out: true),
      command_result(stdout: "", stdout_truncated: true)
    ].each do |command_result_value|
      runner = StubCommandRunner.new(
        list_body: JSON.generate({ "messages" => [{ "id" => "one" }] }),
        detail_results: { "one" => command_result_value }
      )

      result = adapter(runner).fetch

      refute result.success?
      refute_includes result.error.message, "private"
      refute_includes JSON.generate(result.metadata), "private"
      assert_empty result.items
    end
  end

  def test_rejects_non_object_list_response_as_safe_command_error
    runner = StubCommandRunner.new(list_body: JSON.generate([{"id" => "one"}]))

    result = adapter(runner).fetch

    refute result.success?
    assert_instance_of Cybort::CommandError, result.error
    assert_equal "invalid_json", result.metadata.fetch(:exit_category)
  end

  def test_caps_over_returned_list_to_configured_limit
    runner = StubCommandRunner.new(
      list_body: fixture("list_over_limit.json"),
      details: {
        "one" => fixture_json("details/valid_one.json"),
        "two" => fixture_json("details/valid_two.json")
      }
    )

    result = adapter(runner, num_items_to_fetch: 2).fetch

    assert result.success?
    assert_equal %w[one two], result.items.map(&:canonical_id)
    assert_equal 3, runner.calls.length
  end

  def test_deduplicates_before_applying_fetch_limit
    runner = StubCommandRunner.new(
      list_body: JSON.generate({ "messages" => [{ "id" => "one" }, { "id" => "one" }, { "id" => "two" }] }),
      details: { "one" => fixture_json("details/valid_one.json"), "two" => fixture_json("details/valid_two.json") }
    )

    result = adapter(runner, num_items_to_fetch: 2).fetch

    assert result.success?
    assert_equal %w[one two], result.items.map(&:canonical_id)
    assert_equal 3, runner.calls.length
  end

  def test_converts_command_failures_into_safe_metadata
    runner = StubCommandRunner.new(
      list_body: "ignored",
      list_result: command_result(stdout: "secret@example.test", stderr: "token=secret", success: false)
    )
    result = adapter(runner).fetch

    refute result.success?
    assert_instance_of Cybort::CommandError, result.error
    assert_equal "nonzero", result.metadata.fetch(:exit_category)
    refute_includes result.error.message, "secret"
    refute_includes JSON.generate(result.metadata), "secret"
  end

  def test_enforces_aggregate_deadline_without_real_sleep
    times = [0.0, 0.0, 299.0, 300.0]
    runner = StubCommandRunner.new(list_body: fixture("empty.json"))
    result = adapter(runner, monotonic_clock: -> { times.shift || 300.0 }).fetch

    assert result.success?
    assert_equal 1, runner.calls.length
    assert_equal 30, runner.calls.first.last.fetch(:timeout_seconds)
  end

  def test_fails_before_detail_spawn_when_aggregate_budget_is_exhausted
    times = [0.0, 0.0, 300.0]
    runner = StubCommandRunner.new(
      list_body: JSON.generate({ "messages" => [{ "id" => "one" }] }),
      details: { "one" => fixture_json("details/valid_one.json") }
    )

    result = adapter(runner, monotonic_clock: -> { times.shift || 300.0 }).fetch

    refute result.success?
    assert_equal "timeout", result.metadata.fetch(:exit_category)
    assert_equal 1, runner.calls.length
  end

  def test_rejects_num_items_above_gmail_limit
    instance = instance(num_items_to_fetch: 501)

    assert_raises(Cybort::ConfigurationError) { Cybort::Adapters::Gmail.validate_configuration!(instance) }
  end

  def test_records_actual_detail_command_index_for_shape_failures
    runner = StubCommandRunner.new(
      list_body: JSON.generate({ "messages" => [{ "id" => "one" }] }),
      detail_results: { "one" => command_result(stdout: fixture("details/malformed.json")) }
    )

    result = adapter(runner).fetch

    assert_equal 2, result.metadata.fetch(:command_index)
  end

  def test_does_not_accept_numeric_internal_date
    detail = fixture_json("details/valid_two.json").merge("internalDate" => 1_786_878_000_000)
    runner = StubCommandRunner.new(
      list_body: JSON.generate({ "messages" => [{ "id" => "two" }] }),
      details: { "two" => detail }
    )

    result = adapter(runner).fetch

    assert_nil result.items.first.remote_created_at
  end

  private

  def adapter(runner, query: "", num_items_to_fetch: 25, monotonic_clock: -> { 0.0 })
    Cybort::Adapters::Gmail.new(
      instance: instance(query: query, num_items_to_fetch: num_items_to_fetch),
      context: { items: [], last_successful_fetch: nil, sync_state: nil },
      http_client: nil,
      clock: -> { fixed_time },
      command_runner: runner,
      dependency_resolutions: { "gws" => dependency_resolution },
      monotonic_clock: monotonic_clock
    )
  end

  def instance(query: "", num_items_to_fetch: 25)
    Cybort::Configuration::Instance.new(
      id: "gmail",
      name: "Gmail",
      adapter: "gmail",
      ttl_minutes: 30,
      num_items_to_fetch: num_items_to_fetch,
      options: { user_id: "me", query: query }
    )
  end

  def dependency_resolution
    dependency = Cybort::Dependency.new(executable: "gws", purpose: "gmail")
    Cybort::DependencyResolution.new(dependency: dependency, path: "/usr/local/bin/gws", version: "0.22.5", error: nil)
  end

  def command_result(**kwargs)
    StubCommandRunner.new(list_body: "").command_result(**kwargs)
  end

  def fixed_time
    Time.utc(2026, 9, 4, 12)
  end

  def fixture(name)
    File.read(File.expand_path("../fixtures/gmail/#{name}", __dir__))
  end

  def fixture_json(name)
    JSON.parse(fixture(name))
  end
end
