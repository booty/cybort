require "test_helper"

class GmailCredentialsTest < Minitest::Test
  MAX_FILE_BYTES = 16_384

  def with_credentials(payload, mode: 0o600)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "credentials.json")
      File.write(path, payload.is_a?(String) ? payload : JSON.generate(payload))
      File.chmod(mode, path)
      yield path
    end
  end

  def authorized_user
    { "type" => "authorized_user", "client_id" => "fake-client",
      "client_secret" => "secret-sentinel", "refresh_token" => "refresh-sentinel" }
  end

  def test_reads_expected_fields_and_redacts_inspection
    with_credentials(authorized_user.merge("token_uri" => "https://untrusted.test")) do |path|
      credentials = Cybort::GmailCredentials.load(path: path)
      assert_equal "fake-client", credentials.client_id
      assert_equal "secret-sentinel", credentials.client_secret
      assert_equal "refresh-sentinel", credentials.refresh_token
      assert credentials.frozen?
      refute_includes credentials.inspect, "sentinel"
      refute_includes credentials.to_s, "sentinel"
      refute credentials.respond_to?(:token_uri)
    end
  end

  def test_downloaded_client_json_is_not_user_credentials
    with_credentials({ "installed" => authorized_user }) do |path|
      error = assert_raises(Cybort::GmailApiError) do
        Cybort::GmailCredentials.load(path: path)
      end
      assert_equal :invalid_credentials, error.safe_metadata.fetch(:category)
      refute_includes error.message, path
      refute_includes error.message, "sentinel"
    end
  end

  def test_group_readable_credentials_are_rejected
    with_credentials(authorized_user, mode: 0o640) do |path|
      error = assert_raises(Cybort::GmailApiError) do
        Cybort::GmailCredentials.load(path: path)
      end
      assert_equal :unreadable, error.safe_metadata.fetch(:category)
    end
  end

  def test_nil_and_nonexistent_paths_are_missing
    error = assert_raises(Cybort::GmailApiError) do
      Cybort::GmailCredentials.load(path: nil)
    end
    assert_equal :missing, error.safe_metadata.fetch(:category)

    error = assert_raises(Cybort::GmailApiError) do
      Cybort::GmailCredentials.load(path: "/private/tmp/cybort-gmail-does-not-exist")
    end
    assert_equal :missing, error.safe_metadata.fetch(:category)
  end

  def test_malformed_invalid_encoding_and_wrong_root_are_invalid_credentials
    payloads = [
      "not-json",
      "{\"type\": \"authorized_user\", \"client_id\": \"\xFF\"}".b,
      JSON.generate([authorized_user]),
      JSON.generate(authorized_user.merge("type" => "installed"))
    ]

    payloads.each do |payload|
      with_credentials(payload) do |path|
        error = assert_raises(Cybort::GmailApiError) do
          Cybort::GmailCredentials.load(path: path)
        end
        assert_equal :invalid_credentials, error.safe_metadata.fetch(:category), payload.inspect
      end
    end
  end

  def test_missing_blank_control_and_oversized_fields_are_invalid_credentials
    {
      "client_id" => [nil, "", " \t" , "bad\nvalue", "a" * 1_025],
      "client_secret" => [nil, "", " \t", "bad\x00value", "a" * 4_097],
      "refresh_token" => [nil, "", " \t", "bad\u007fvalue", "a" * 8_193]
    }.each do |key, values|
      values.each do |value|
        with_credentials(authorized_user.merge(key => value)) do |path|
          error = assert_raises(Cybort::GmailApiError) do
            Cybort::GmailCredentials.load(path: path)
          end
          assert_equal :invalid_credentials, error.safe_metadata.fetch(:category), [key, value].inspect
        end
      end
    end
  end

  def test_oversized_file_is_rejected_at_explicit_read_limit
    with_credentials("a" * (MAX_FILE_BYTES + 1)) do |path|
      error = assert_raises(Cybort::GmailApiError) do
        Cybort::GmailCredentials.load(path: path)
      end
      assert_equal :invalid_credentials, error.safe_metadata.fetch(:category)
    end
  end

  def test_regular_file_descriptor_is_closed_after_parse_failure
    with_credentials("not-json") do |path|
      file_singleton = File.singleton_class
      original_open = file_singleton.instance_method(:open)
      opened_file = nil
      read_limits = []
      file_singleton.define_method(:open) do |*arguments, &block|
        original_open.bind(self).call(*arguments) do |file|
          opened_file = file
          original_read = file.method(:read)
          file.define_singleton_method(:read) do |*read_arguments|
            read_limits << read_arguments.first
            original_read.call(*read_arguments)
          end
          block.call(file)
        end
      end
      begin
        assert_raises(Cybort::GmailApiError) { Cybort::GmailCredentials.load(path: path) }
      ensure
        file_singleton.send(:define_method, :open, original_open)
      end
      assert opened_file
      assert opened_file.closed?
      assert_equal [MAX_FILE_BYTES + 1], read_limits
    end
  end

  def test_rejects_directory_and_leaf_symlink_as_unreadable
    Dir.mktmpdir do |directory|
      error = assert_raises(Cybort::GmailApiError) do
        Cybort::GmailCredentials.load(path: directory)
      end
      assert_equal :unreadable, error.safe_metadata.fetch(:category)

      target = File.join(directory, "real.json")
      link = File.join(directory, "link.json")
      File.write(target, JSON.generate(authorized_user))
      File.chmod(0o600, target)
      File.symlink(target, link)
      error = assert_raises(Cybort::GmailApiError) do
        Cybort::GmailCredentials.load(path: link)
      end
      assert_equal :unreadable, error.safe_metadata.fetch(:category)
    end
  end

  def test_rejects_non_regular_descriptor_without_blocking_fifo_reader
    Dir.mktmpdir do |directory|
      path = File.join(directory, "credentials.fifo")
      File.mkfifo(path, 0o600)
      error = assert_raises(Cybort::GmailApiError) do
        Cybort::GmailCredentials.load(path: path)
      end
      assert_equal :unreadable, error.safe_metadata.fetch(:category)
    end
  end

  def test_private_file_validator_rejects_wrong_owner_from_stat
    stat = Struct.new(:file?, :uid, :mode).new(true, Process.euid + 1, 0o600)
    error = assert_raises(Cybort::GmailApiError) do
      Cybort::GmailCredentials.send(:validate_file!, stat)
    end
    assert_equal :unreadable, error.safe_metadata.fetch(:category)
  end

  def test_printable_validation_is_shared_and_strict
    assert Cybort::GmailCredentials.printable?("plain", 5)
    refute Cybort::GmailCredentials.printable?(nil, 10)
    refute Cybort::GmailCredentials.printable?("\xFF".b.force_encoding(Encoding::UTF_8), 10)
    refute Cybort::GmailCredentials.printable?(" \t", 10)
    refute Cybort::GmailCredentials.printable?("a\x00b", 10)
    refute Cybort::GmailCredentials.printable?("a\u007Fb", 10)
    refute Cybort::GmailCredentials.printable?("123456", 5)
  end

  def test_gmail_api_error_has_allowlisted_safe_metadata_and_exact_403_guidance
    error = Cybort::GmailApiError.new(operation: :list, category: :authorization, status: 403)
    assert_kind_of Cybort::SourceError, error
    assert_equal({ source: "gmail_api", operation: :list, category: :authorization, status: 403 }, error.safe_metadata)
    assert error.safe_metadata.frozen?
    assert_equal "Gmail list failed (authorization, HTTP 403). Check Gmail scope, API enablement, and account/admin policy.", error.message
  end

  def test_gmail_api_error_rejects_unknown_operations_categories_and_statuses
    assert_raises(ArgumentError) do
      Cybort::GmailApiError.new(operation: :refresh, category: :authentication)
    end
    assert_raises(ArgumentError) do
      Cybort::GmailApiError.new(operation: :list, category: :secret)
    end
    ["403", 99, 600, 1.2].each do |status|
      assert_raises(ArgumentError) do
        Cybort::GmailApiError.new(operation: :list, category: :http, status: status)
      end
    end
  end
end
