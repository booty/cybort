require "test_helper"

class ItemTest < Minitest::Test
  def valid_attributes
    {
      instance_id: "personal_rss",
      canonical_id: "entry-1",
      fetched_at: Time.utc(2026, 8, 16, 12),
      title: "An article"
    }
  end

  def test_defaults_optional_collections
    item = Cybort::Item.new(**valid_attributes)

    assert_equal [], item.urls
    assert_equal({}, item.info)
    assert_nil item.body
  end

  def test_requires_identity_timestamp_and_title
    %i[instance_id canonical_id fetched_at title].each do |field|
      attributes = valid_attributes.dup
      attributes.delete(field)

      assert_raises(Cybort::ValidationError) { Cybort::Item.new(**attributes) }
    end
  end

  def test_validates_priority_range
    assert_equal 0, Cybort::Item.new(**valid_attributes, priority: 0).priority
    assert_equal 100, Cybort::Item.new(**valid_attributes, priority: 100).priority

    assert_raises(Cybort::ValidationError) { Cybort::Item.new(**valid_attributes, priority: -1) }
    assert_raises(Cybort::ValidationError) { Cybort::Item.new(**valid_attributes, priority: 101) }
  end
end

