require "json"

module Cybort
  class GmailCredentials
    MAX_FILE_BYTES = 16_384
    LIMITS = {
      "client_id" => 1_024,
      "client_secret" => 4_096,
      "refresh_token" => 8_192
    }.freeze

    attr_reader :client_id, :client_secret, :refresh_token

    def self.load(path:)
      raise GmailApiError.new(operation: :credentials, category: :missing) if path.nil?

      expanded = File.expand_path(path)
      flags = File::RDONLY | File::NOFOLLOW | File::NONBLOCK
      payload = File.open(expanded, flags) do |file|
        validate_file!(file.stat)
        raw = file.read(MAX_FILE_BYTES + 1)
        if raw.bytesize > MAX_FILE_BYTES
          raise GmailApiError.new(operation: :credentials, category: :invalid_credentials)
        end
        JSON.parse(raw)
      end

      unless payload.is_a?(Hash) && payload["type"] == "authorized_user" &&
             LIMITS.all? { |key, limit| printable?(payload[key], limit) }
        raise GmailApiError.new(operation: :credentials, category: :invalid_credentials)
      end

      new(**LIMITS.keys.to_h { |key| [key.to_sym, payload.fetch(key).dup.freeze] }).freeze
    rescue GmailApiError
      raise
    rescue Errno::ENOENT
      raise GmailApiError.new(operation: :credentials, category: :missing), cause: nil
    rescue JSON::ParserError, EncodingError, ArgumentError
      raise GmailApiError.new(operation: :credentials, category: :invalid_credentials), cause: nil
    rescue SystemCallError, IOError
      raise GmailApiError.new(operation: :credentials, category: :unreadable), cause: nil
    end

    def self.validate_file!(stat)
      unless stat.file? && stat.uid == Process.euid && (stat.mode & 0o077).zero?
        raise GmailApiError.new(operation: :credentials, category: :unreadable)
      end
    end
    private_class_method :validate_file!

    def self.printable?(value, maximum_bytes)
      value.is_a?(String) && value.valid_encoding? && !value.strip.empty? &&
        value.bytesize <= maximum_bytes && !value.match?(/[\x00-\x1F\x7F]/)
    end

    private_class_method :new

    def initialize(client_id:, client_secret:, refresh_token:)
      @client_id = client_id
      @client_secret = client_secret
      @refresh_token = refresh_token
    end

    def inspect
      "#<Cybort::GmailCredentials [REDACTED]>"
    end

    alias to_s inspect
  end
end
