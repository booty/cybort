require "test_helper"

class CleanupFailureMetadataTest < Minitest::Test
  def test_bounds_and_sanitizes_cleanup_failure_details
    refute_nil defined?(Cybort::CleanupFailureMetadata), "cleanup metadata helper is missing"

    details = Cybort::CleanupFailureMetadata.detail(
      RuntimeError.new("private cleanup context"),
      phase: "phase-#{'x' * 200}"
    )
    assert_equal "RuntimeError", details.fetch(:error_class)
    assert_equal 128, details.fetch(:phase).bytesize
    assert_equal %i[phase error_class], details.keys

    failures = Cybort::CleanupFailureMetadata.bound(
      [details] + Array.new(12) { |index| { phase: "phase-#{index}", error_class: "Error" } }
    )
    assert_equal 8, failures.length
    assert failures.all? { |failure| failure.keys == %i[phase error_class] }
    assert failures.all?(&:frozen?)
  end

  def test_discards_untrusted_or_malformed_fields
    refute_nil defined?(Cybort::CleanupFailureMetadata), "cleanup metadata helper is missing"

    failures = Cybort::CleanupFailureMetadata.bound([
      { phase: "safe", error_class: "Error", message: "must not survive" },
      { "phase" => "\xFF", "error_class" => "Error" },
      { phase: "valid", error_class: "Error" }
    ])

    assert_equal [{ phase: "safe", error_class: "Error" }, { phase: "valid", error_class: "Error" }], failures
    refute failures.any? { |failure| failure.key?(:message) }
  end
end
