require "test_helper"
require "support/gmail_http_fixture"

class GmailAdapterTest < Minitest::Test
  READONLY_SCOPE = "https://www.googleapis.com/auth/gmail.readonly"

  def test_fetches_deduplicated_messages_and_normalizes_metadata
    with_credentials do |credentials_file|
      http = GmailHttpFixture.new(responses: [
        token_response,
        response(fixture_json("list_valid.json")),
        response(fixture_json("details/valid_one.json")),
        response(fixture_json("details/valid_two.json"))
      ])
      result = adapter(http_client: http, credentials_file: credentials_file).fetch

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
      assert_equal 4, http.calls.length
      assert_equal fixed_time, result.items.map(&:fetched_at).uniq.first
    end
  end

  def test_constructs_direct_api_list_and_detail_requests
    with_credentials do |credentials_file|
      http = GmailHttpFixture.new(responses: [token_response, response({ "messages" => [] })])
      adapter_instance = adapter(
        http_client: http,
        credentials_file: credentials_file,
        query: "in:anywhere",
        include_spam_trash: true,
        num_items_to_fetch: 7
      )
      result = adapter_instance.fetch

      assert result.success?
      token_call, list_call = http.calls
      assert_equal :post_form, token_call.fetch(:method)
      assert_equal "https://oauth2.googleapis.com/token", token_call.fetch(:url)
      assert_equal({
        grant_type: "refresh_token", client_id: "fake-client",
        client_secret: "fake-secret", refresh_token: "fake-refresh"
      }, token_call.fetch(:form))
      refute token_call.fetch(:headers).key?("Authorization")

      assert_equal :get, list_call.fetch(:method)
      list_uri = URI(list_call.fetch(:url))
      assert_equal "/gmail/v1/users/me/messages", list_uri.path
      list_params = URI.decode_www_form(list_uri.query).to_h
      assert_equal({ "maxResults" => "7", "includeSpamTrash" => "true", "q" => "in:anywhere" }, list_params)

      http = GmailHttpFixture.new(responses: [
        token_response,
        response({ "messages" => [{ "id" => "one" }] }),
        response(fixture_json("details/valid_one.json"))
      ])
      adapter(http_client: http, credentials_file: credentials_file).fetch
      detail_call = http.calls.fetch(2)
      detail_uri = URI(detail_call.fetch(:url))
      assert_equal "/gmail/v1/users/me/messages/one", detail_uri.path
      assert_equal "Bearer fake-access", detail_call.fetch(:headers).fetch("Authorization")
      assert_equal 1, detail_call.fetch(:headers).length
      detail_pairs = URI.decode_www_form(detail_uri.query)
      assert_equal "metadata", detail_pairs.assoc("format").last
      assert_equal "id,threadId,labelIds,snippet,internalDate,payload/headers", detail_pairs.assoc("fields").last
      assert_equal %w[Subject From Date Message-ID], detail_pairs.select { |key, _| key == "metadataHeaders" }.map(&:last)
    end
  end

  def test_accepts_empty_list_without_detail_calls
    with_credentials do |credentials_file|
      http = GmailHttpFixture.new(responses: [token_response, response(fixture_json("empty.json"))])
      result = adapter(http_client: http, credentials_file: credentials_file).fetch

      assert result.success?
      assert_empty result.items
      assert_equal 2, http.calls.length
    end
  end

  def test_rejects_blank_id_and_mismatched_detail_id_without_partial_items
    with_credentials do |credentials_file|
      blank_http = GmailHttpFixture.new(responses: [token_response, response(fixture_json("list_blank_id.json"))])
      blank = adapter(http_client: blank_http, credentials_file: credentials_file).fetch
      refute blank.success?
      assert_instance_of Cybort::GmailApiError, blank.error
      assert_equal :invalid_identity, blank.metadata.fetch(:category)

      mismatch_http = GmailHttpFixture.new(responses: [
        token_response,
        response({ "messages" => [{ "id" => "one" }] }),
        response(fixture_json("details/mismatched_id.json"))
      ])
      mismatch = adapter(http_client: mismatch_http, credentials_file: credentials_file).fetch
      refute mismatch.success?
      assert_empty mismatch.items
      assert_equal :invalid_identity, mismatch.metadata.fetch(:category)
    end
  end

  def test_rejects_malformed_detail_without_partial_items
    with_credentials do |credentials_file|
      http = GmailHttpFixture.new(responses: [
        token_response,
        response({ "messages" => [{ "id" => "one" }] }),
        response_body(fixture("details/malformed.json"))
      ])
      result = adapter(http_client: http, credentials_file: credentials_file).fetch

      refute result.success?
      assert_instance_of Cybort::GmailApiError, result.error
      assert_equal :invalid_json, result.metadata.fetch(:category)
      assert_empty result.items
    end
  end

  def test_rejects_non_object_list_response_as_safe_gmail_error
    with_credentials do |credentials_file|
      http = GmailHttpFixture.new(responses: [token_response, response([{"id" => "one"}])])
      result = adapter(http_client: http, credentials_file: credentials_file).fetch

      refute result.success?
      assert_instance_of Cybort::GmailApiError, result.error
      assert_equal :invalid_shape, result.metadata.fetch(:category)
    end
  end

  def test_caps_over_returned_list_to_configured_limit
    with_credentials do |credentials_file|
      http = GmailHttpFixture.new(responses: [
        token_response,
        response(fixture_json("list_over_limit.json")),
        response(fixture_json("details/valid_one.json")),
        response(fixture_json("details/valid_two.json"))
      ])
      result = adapter(http_client: http, credentials_file: credentials_file, num_items_to_fetch: 2).fetch

      assert result.success?
      assert_equal %w[one two], result.items.map(&:canonical_id)
      assert_equal 4, http.calls.length
    end
  end

  def test_http_failures_are_safe_and_do_not_return_partial_items
    with_credentials do |credentials_file|
      http = GmailHttpFixture.new(responses: [
        token_response,
        response({ "messages" => [{ "id" => "one" }] }),
        Cybort::HttpError.new(status: 500)
      ])
      result = adapter(http_client: http, credentials_file: credentials_file).fetch

      refute result.success?
      assert_equal :http, result.metadata.fetch(:category)
      assert_equal 500, result.metadata.fetch(:status)
      assert_empty result.items
      refute_includes result.error.message, "private"
    end
  end

  def test_counts_credential_time_against_attempt_budget
    with_credentials do |credentials_file|
      times = [0.0, 299.0, 299.0, 300.0]
      http = GmailHttpFixture.new(responses: [token_response])
      result = adapter(
        http_client: http,
        credentials_file: credentials_file,
        monotonic_clock: -> { times.shift || 300.0 }
      ).fetch

      refute result.success?
      assert_equal :deadline, result.metadata.fetch(:category)
      assert_equal 1, http.calls.length
    end
  end

  def test_does_not_start_detail_request_after_token_expiry
    with_credentials do |credentials_file|
      times = [0.0, 0.0, 0.0, 0.0, 0.0, 2.0, 2.0]
      http = GmailHttpFixture.new(responses: [
        token_response("expires_in" => 1),
        response({ "messages" => [{ "id" => "one" }] })
      ])
      result = adapter(
        http_client: http,
        credentials_file: credentials_file,
        monotonic_clock: -> { times.shift || 2.0 }
      ).fetch

      refute result.success?
      assert_equal :token_expired, result.metadata.fetch(:category)
      assert_equal 2, http.calls.length
    end
  end

  def test_does_not_start_detail_request_after_attempt_deadline
    with_credentials do |credentials_file|
      times = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 300.0]
      http = GmailHttpFixture.new(responses: [
        token_response,
        response({ "messages" => [{ "id" => "one" }] })
      ])
      result = adapter(
        http_client: http,
        credentials_file: credentials_file,
        monotonic_clock: -> { times.shift || 300.0 }
      ).fetch

      refute result.success?
      assert_equal :deadline, result.metadata.fetch(:category)
      assert_equal 2, http.calls.length
    end
  end

  def test_checks_attempt_deadline_after_last_detail_response
    with_credentials do |credentials_file|
      times = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 300.0]
      http = GmailHttpFixture.new(responses: [
        token_response,
        response({ "messages" => [{ "id" => "one" }] }),
        response(fixture_json("details/valid_one.json"))
      ])
      result = adapter(
        http_client: http,
        credentials_file: credentials_file,
        monotonic_clock: -> { times.shift || 300.0 }
      ).fetch

      refute result.success?
      assert_equal :deadline, result.metadata.fetch(:category)
      assert_equal 3, http.calls.length
    end
  end

  def test_remote_missing_credentials_is_a_safe_source_failure
    Dir.mktmpdir do |directory|
      credentials_file = File.join(directory, "missing.json")
      http = GmailHttpFixture.new(responses: [])
      result = adapter(http_client: http, credentials_file: credentials_file).fetch

      refute result.success?
      assert_equal :credentials, result.metadata.fetch(:operation)
      assert_equal :missing, result.metadata.fetch(:category)
      assert_empty http.calls
    end
  end

  def test_cache_hit_with_missing_credentials_does_not_read_or_call_http
    Dir.mktmpdir do |directory|
      credentials_file = File.join(directory, "missing.json")
      cached_item = Cybort::Item.new(
        instance_id: "gmail", canonical_id: "cached", fetched_at: fixed_time,
        title: "Cached message"
      )
      http = GmailHttpFixture.new(responses: [])
      result = adapter(
        http_client: http,
        credentials_file: credentials_file,
        context: {
          items: [cached_item], last_successful_fetch: fixed_time - 60,
          sync_state: {}
        }
      ).fetch

      assert result.success?
      refute result.source_fetched
      assert_equal [cached_item], result.items
      assert_empty http.calls
    end
  end

  def test_success_metadata_and_snapshot_replacement_contract_are_unchanged
    with_credentials do |credentials_file|
      http = GmailHttpFixture.new(responses: [token_response, response(fixture_json("empty.json"))])
      result = adapter(http_client: http, credentials_file: credentials_file).fetch

      assert result.success?
      refute result.replace_existing_items
      assert_equal({ source: "gmail_api", limit: 25, message_count: 0 }, result.metadata)
    end
  end

  def test_does_not_accept_numeric_internal_date
    with_credentials do |credentials_file|
      detail = fixture_json("details/valid_two.json").merge("internalDate" => 1_786_878_000_000)
      http = GmailHttpFixture.new(responses: [
        token_response,
        response({ "messages" => [{ "id" => "two" }] }),
        response(detail)
      ])
      result = adapter(http_client: http, credentials_file: credentials_file).fetch

      assert_nil result.items.first.remote_created_at
    end
  end

  def test_validates_user_query_path_limits_and_boolean_options_without_io
    invalid_options = [
      { user_id: nil }, { user_id: true }, { user_id: 1 },
      { user_id: "a" * 321 }, { user_id: "a\u0000@example.test" },
      { user_id: "name@example.test/path" }, { user_id: "name@example.test?x" },
      { query: nil }, { query: true }, { query: 1 },
      { query: "a" * 4_097 }, { query: "a\u0000b" },
      { credentials_file: nil }, { credentials_file: "" },
      { credentials_file: " " }, { credentials_file: "relative.json" },
      { credentials_file: "~other/file.json" }, { credentials_file: "a" * 4_097 },
      { include_spam_trash: nil }, { include_spam_trash: "true" },
      { include_spam_trash: 1 }
    ]

    invalid_options.each do |options|
      error = assert_raises(Cybort::ConfigurationError, options.inspect) do
        Cybort::Adapters::Gmail.validate_configuration!(instance(options: options))
      end
      refute_includes error.message, options.inspect
    end

    [0, 501].each do |limit|
      assert_raises(Cybort::ConfigurationError) do
        Cybort::Adapters::Gmail.validate_configuration!(instance(num_items_to_fetch: limit))
      end
    end
  end

  def test_accepts_omitted_credentials_path_blank_query_and_valid_utf8_query
    assert_silent do
      Cybort::Adapters::Gmail.validate_configuration!(instance(options: {}))
      Cybort::Adapters::Gmail.validate_configuration!(instance(options: {
        user_id: "person@example.test", query: "from:✓ ",
        credentials_file: "~/google-auth/application_default_credentials.json",
        include_spam_trash: false
      }))
      Cybort::Adapters::Gmail.validate_configuration!(instance(options: { query: "  " }))
    end
  end

  private

  def adapter(http_client:, credentials_file:, query: "", user_id: "me", include_spam_trash: false,
              num_items_to_fetch: 25, context: nil, monotonic_clock: -> { 0.0 })
    options = {
      user_id: user_id, query: query,
      credentials_file: credentials_file, include_spam_trash: include_spam_trash
    }
    Cybort::Adapters::Gmail.new(
      instance: instance(options: options, num_items_to_fetch: num_items_to_fetch),
      context: context || { items: [], last_successful_fetch: nil, sync_state: nil },
      http_client: http_client,
      clock: -> { fixed_time },
      monotonic_clock: monotonic_clock
    )
  end

  def instance(options: { user_id: "me", query: "" }, num_items_to_fetch: 25)
    Cybort::Configuration::Instance.new(
      id: "gmail",
      name: "Gmail",
      adapter: "gmail",
      ttl_minutes: 30,
      num_items_to_fetch: num_items_to_fetch,
      options: options
    )
  end

  def with_credentials
    Dir.mktmpdir do |directory|
      path = File.join(directory, "authorized_user.json")
      File.write(path, JSON.generate(
        "type" => "authorized_user",
        "client_id" => "fake-client",
        "client_secret" => "fake-secret",
        "refresh_token" => "fake-refresh"
      ))
      File.chmod(0o600, path)
      yield path
    end
  end

  def token_response(overrides = {})
    response({
      "access_token" => "fake-access",
      "token_type" => "Bearer",
      "expires_in" => 3_600,
      "scope" => READONLY_SCOPE
    }.merge(overrides))
  end

  def response(payload)
    Cybort::HttpResponse.new(status: 200, headers: {}, body: JSON.generate(payload))
  end

  def response_body(body)
    Cybort::HttpResponse.new(status: 200, headers: {}, body: body)
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
