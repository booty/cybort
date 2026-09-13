require "test_helper"

class AppleHealthAdapterTest < Minitest::Test
  def valid_instance(options: { directory: "~/Health Exports" }, num_items_to_fetch: 1,
                     retention_ttl_minutes: nil, hard_expiry_ttl_minutes: nil)
    Cybort::Configuration::Instance.new(
      id: "health", name: "Apple Health", adapter: "apple_health", ttl_minutes: 1_440,
      num_items_to_fetch: num_items_to_fetch, retention_ttl_minutes: retention_ttl_minutes,
      hard_expiry_ttl_minutes: hard_expiry_ttl_minutes, options: options
    )
  end

  def test_validates_without_touching_the_filesystem
    assert_nil Cybort::Adapters::AppleHealth.validate_configuration!(valid_instance)
  end

  def test_rejects_unsafe_or_unsupported_configuration
    invalid = [
      valid_instance(options: {}), valid_instance(options: { directory: "relative/path" }),
      valid_instance(options: { directory: "/tmp/$HOME" }), valid_instance(options: { directory: "/tmp/a*b" }),
      valid_instance(options: { directory: "/tmp/#{"a" * 4_097}" }),
      valid_instance(num_items_to_fetch: 2), valid_instance(retention_ttl_minutes: 30),
      valid_instance(options: { directory: "~/Health", extra: true })
    ]
    invalid.each { |instance| assert_raises(Cybort::ConfigurationError) { Cybort::Adapters::AppleHealth.validate_configuration!(instance) } }
  end

  def test_constructor_accepts_injected_spool_boundary_without_source_access
    spool = Object.new
    adapter = Cybort::Adapters::AppleHealth.new(
      instance: valid_instance, context: {}, clock: -> { Time.now.utc },
      monotonic_clock: -> { 0.0 }, spool_factory: spool
    )
    assert_same spool, adapter.spool_factory
    assert_raises(NotImplementedError) { adapter.fetch }
  end
end
