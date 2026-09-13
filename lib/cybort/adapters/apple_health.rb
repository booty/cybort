module Cybort
  module Adapters
    class AppleHealth < Base
      def self.validate_configuration!(instance)
        options = instance.options || {}
        unless options.keys.map(&:to_sym).sort == [:directory]
          raise ConfigurationError, "apple_health options must contain only directory"
        end
        unless instance.num_items_to_fetch == 1
          raise ConfigurationError, "apple_health num_items_to_fetch must be 1"
        end
        if instance.retention_ttl_minutes || instance.hard_expiry_ttl_minutes
          raise ConfigurationError, "apple_health does not support retention TTL settings"
        end

        directory = options[:directory]
        unless directory.is_a?(String) && directory.valid_encoding? &&
               directory.bytesize.between?(3, 4_096) &&
               (directory.start_with?("/") || directory.start_with?("~/")) &&
               !directory.match?(/[\x00-\x1f\x7f$`*?\[\]{}]/)
          raise ConfigurationError, "apple_health directory must be an absolute or ~/ path"
        end
        nil
      end

      def initialize(instance:, context:, clock:, monotonic_clock:, spool_factory:,
                     archive_acquirer: nil, zip_inspector: nil, parser_factory: nil,
                     **_unused)
        @instance = instance
        @context = context
        @clock = clock
        @monotonic_clock = monotonic_clock
        @spool_factory = spool_factory
        @archive_acquirer = archive_acquirer
        @zip_inspector = zip_inspector
        @parser_factory = parser_factory
      end

      attr_reader :instance, :context, :clock, :monotonic_clock, :spool_factory

      def fetch(**_kwargs)
        raise NotImplementedError, "Apple Health adapter implementation is not available yet"
      end
    end
  end
end
