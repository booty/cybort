require "test_helper"

class TimeSeriesStartupCoordinatorTest < Minitest::Test
  def test_returns_empty_recovery_without_time_series_work
    return unless assert defined?(Cybort::TimeSeriesStartupCoordinator), "startup coordinator is missing"

    coordinator = Cybort::TimeSeriesStartupCoordinator.new(
      persistence: Object.new, reader: nil, persistence_factory: nil
    )

    writer, recovery = coordinator.prepare(
      result_kinds: { "items" => :items }, completions: Queue.new
    )

    assert_nil writer
    assert_equal({ blocked_instances: [], errors: {} }, recovery)
  end

  def test_startup_error_blocks_only_time_series_instances
    return unless assert defined?(Cybort::TimeSeriesStartupCoordinator), "startup coordinator is missing"

    error = Cybort::TimeSeriesStartupError.new
    coordinator = Cybort::TimeSeriesStartupCoordinator.new(
      persistence: Object.new, reader: nil, persistence_factory: nil,
      startup_error: error
    )

    writer, recovery = coordinator.prepare(
      result_kinds: { "items" => :items, "series" => :time_series }, completions: Queue.new
    )

    assert_nil writer
    assert_equal ["series"], recovery.fetch(:blocked_instances)
    assert_same error, recovery.fetch(:errors).fetch("series")
    assert_same error, recovery.fetch(:writer_failure)
  end
end
