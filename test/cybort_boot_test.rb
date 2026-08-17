require "test_helper"

class CybortBootTest < Minitest::Test
  def test_cybort_loads_with_a_version
    assert_equal "0.1.0", Cybort::VERSION
  end
end
