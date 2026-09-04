require_relative "test_helper"

class ErrorsTest < Minitest::Test
  def test_command_error_freezes_allow_listed_scalar_metadata
    error = Cybort::CommandError.new(
      "gws command failed",
      metadata: { tool: "gws", operation: "list", exit_category: "nonzero", exit_code: 1 }
    )

    assert_equal "gws command failed", error.message
    assert error.safe_metadata.frozen?
    assert_equal "gws", error.safe_metadata.fetch(:tool)
    assert_raises(ArgumentError) do
      Cybort::CommandError.new("unsafe", metadata: { stderr: "secret" })
    end
  end

  def test_command_error_rejects_non_scalar_or_oversized_metadata
    assert_raises(ArgumentError) do
      Cybort::CommandError.new("unsafe", metadata: { tool: ["gws"] })
    end
    assert_raises(ArgumentError) do
      Cybort::CommandError.new("unsafe", metadata: { tool: "x" * 300 })
    end
  end
end
