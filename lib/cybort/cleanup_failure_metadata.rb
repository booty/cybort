module Cybort
  # Keeps cleanup diagnostics bounded and free of paths, messages, and other
  # exception details that may contain source or local-environment data.
  module CleanupFailureMetadata
    LIMIT = 8
    FIELD_BYTES = 128

    module_function

    def detail(error, phase:)
      {
        phase: field(phase),
        error_class: field(error.class.name.to_s)
      }.freeze
    end

    def bound(failures)
      Array(failures).first(LIMIT).filter_map do |failure|
        next unless failure.respond_to?(:key?)

        phase = field(failure[:phase] || failure["phase"])
        error_class = field(failure[:error_class] || failure["error_class"])
        next unless phase && error_class

        { phase: phase, error_class: error_class }.freeze
      end.freeze
    end

    def field(value)
      return unless value.is_a?(String)

      field = value.dup.force_encoding(Encoding::UTF_8)
      return unless field.valid_encoding?

      bounded = +""
      field.each_char do |character|
        candidate = bounded + character
        break if candidate.bytesize > FIELD_BYTES

        bounded << character
      end
      bounded.freeze
    end
    private_class_method :field
  end
end
