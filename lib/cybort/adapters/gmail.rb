require "json"
require "time"

module Cybort
  module Adapters
    class Gmail < Base
      MAX_RESULTS = 500
      COMMAND_TIMEOUT_SECONDS = 30
      ADAPTER_BUDGET_SECONDS = 300
      DEFAULT_USER_ID = "me"
      AUTH_HINT = "Run gws auth setup, then gws auth login --scopes https://www.googleapis.com/auth/gmail.readonly; verify with gws auth status."

      def self.validate_configuration!(instance)
        user_id = instance.options.fetch(:user_id, DEFAULT_USER_ID)
        query = instance.options.fetch(:query, "")
        unless user_id.is_a?(String) && !user_id.strip.empty?
          raise ConfigurationError, "gmail user_id must be a nonblank string"
        end
        raise ConfigurationError, "gmail query must be a string" unless query.is_a?(String)
        unless instance.num_items_to_fetch.is_a?(Integer) && instance.num_items_to_fetch.between?(1, MAX_RESULTS)
          raise ConfigurationError, "gmail num_items_to_fetch must be an integer from 1 through #{MAX_RESULTS}"
        end
      end

      def fetch_from_source
        deadline = monotonic_clock.call + ADAPTER_BUDGET_SECONDS
        fetched_at = clock.call
        @command_index = 0
        @command_statuses = []
        dependency = dependency_resolution

        list = run_gws(
          dependency,
          "list",
          ["gmail", "users", "messages", "list", "--params", JSON.generate(list_params)],
          deadline
        )
        parsed_list = parse_json!(list, "list")
        raise_command_error("list", "invalid_json", dependency) unless parsed_list.is_a?(Hash)
        raw_messages = parsed_list.key?("messages") ? parsed_list.fetch("messages") : []
        raise_command_error("list", "invalid_json", dependency) unless raw_messages.is_a?(Array)

        ids = raw_messages.first(instance.num_items_to_fetch).map { |message| message_id!(message, dependency) }.uniq
        items = ids.map.with_index do |message_id, index|
          detail = run_gws(
            dependency,
            "get",
            ["gmail", "users", "messages", "get", "--params", JSON.generate(detail_params(message_id))],
            deadline
          )
          message = parse_json!(detail, "get")
          item_from(message, message_id, fetched_at, dependency, command_index: @command_index)
        end

        {
          items: items,
          sync_state: {},
          metadata: {
            tool: "gws",
            tool_version: dependency.version,
            query: query,
            limit: instance.num_items_to_fetch,
            command_statuses: @command_statuses
          }
        }
      end

      private

      def user_id
        instance.options.fetch(:user_id, DEFAULT_USER_ID).to_s
      end

      def query
        instance.options.fetch(:query, "").to_s
      end

      def dependency_resolution
        dependency_resolutions.fetch("gws")
      rescue KeyError
        raise CommandError.new("gws dependency is unavailable", metadata: { tool: "gws", exit_category: "dependency" })
      end

      def gws_path(dependency)
        dependency.path || raise_command_error("preflight", "dependency", dependency)
      end

      def list_params
        params = { "userId" => user_id, "maxResults" => instance.num_items_to_fetch }
        params["q"] = query unless query.strip.empty?
        params
      end

      def detail_params(message_id)
        {
          "userId" => user_id,
          "id" => message_id,
          "format" => "metadata",
          "metadataHeaders" => ["Subject", "From", "Date", "Message-ID"]
        }
      end

      def run_gws(dependency, operation, argv, deadline)
        remaining = deadline - monotonic_clock.call
        raise_command_error(operation, "timeout", dependency) if remaining <= 0

        @command_index += 1
        result = command_runner.run(
          [gws_path(dependency), *argv],
          allowed_env_keys: dependency.dependency.environment_keys,
          timeout_seconds: [COMMAND_TIMEOUT_SECONDS, remaining].min,
          max_output_bytes: 1_048_576
        )
        category = command_failure_category(result)
        if category
          @command_statuses << { operation: operation, category: category, exit_code: safe_exit_code(result) }
          raise_command_error(operation, category, dependency, command_index: @command_index, exit_code: safe_exit_code(result))
        end

        @command_statuses << { operation: operation, category: "success", exit_code: safe_exit_code(result) }
        result
      end

      def parse_json!(result, operation, command_index: @command_index)
        raise_command_error(operation, "empty_output", dependency_resolution, command_index: command_index) if result.stdout.to_s.empty?
        JSON.parse(result.stdout)
      rescue JSON::ParserError
        raise_command_error(operation, "invalid_json", dependency_resolution, command_index: command_index)
      end

      def message_id!(message, dependency)
        unless message.is_a?(Hash) && message["id"].is_a?(String) && !message["id"].strip.empty?
          raise_command_error("list", "invalid_message_id", dependency, command_index: @command_index)
        end
        message.fetch("id")
      end

      def item_from(message, requested_id, fetched_at, dependency, command_index:)
        unless message.is_a?(Hash) && message["id"].is_a?(String) && message["id"] == requested_id
          raise_command_error("get", "mismatched_message_id", dependency, command_index: command_index)
        end

        headers = message.dig("payload", "headers")
        headers = [] unless headers.is_a?(Array)
        values = headers.each_with_object({}) do |header, result|
          next unless header.is_a?(Hash)
          name = header["name"].to_s.downcase
          value = header["value"]
          result[name] ||= value if value.is_a?(String) && !value.strip.empty?
        end
        subject = values["subject"].to_s.strip
        subject = "(no subject)" if subject.empty?
        info = {
          from: values["from"],
          date_header: values["date"],
          message_id: values["message-id"],
          thread_id: message["threadId"],
          label_ids: message["labelIds"]
        }.compact

        Item.new(
          instance_id: instance.id,
          canonical_id: requested_id,
          urls: [],
          fetched_at: fetched_at,
          remote_created_at: parse_internal_date(message["internalDate"]),
          title: subject,
          body: message["snippet"],
          info: info
        )
      end

      def parse_internal_date(value)
        return nil unless value.is_a?(String) && value.match?(/\A[1-9]\d*\z/)

        Time.at(value.to_i / 1_000.0).utc
      rescue ArgumentError, RangeError
        nil
      end

      def command_failure_category(result)
        return "spawn_#{result.spawn_error_category}" if result.spawn_error_category
        return "timeout" if result.timed_out
        return "output_truncated" if result.stdout_truncated || result.stderr_truncated
        return "nonzero" unless result.status&.success?
        nil
      end

      def safe_exit_code(result)
        result.status&.respond_to?(:exitstatus) ? result.status.exitstatus : nil
      end

      def raise_command_error(operation, category, dependency, command_index: @command_index, exit_code: nil)
        raise CommandError.new(
          "gws #{operation} command failed",
          metadata: {
            tool: "gws",
            operation: operation,
            command_index: command_index,
            exit_category: category,
            exit_code: exit_code,
            tool_version: dependency.version,
            auth_hint: AUTH_HINT
          }
        )
      end
    end
  end
end
