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

  def test_requires_action_item_to_be_boolean_or_nil
    [0, 1, "false", Object.new].each do |value|
      assert_raises(Cybort::ValidationError) do
        Cybort::Item.new(**valid_attributes, action_item: value)
      end
    end

    assert_equal false, Cybort::Item.new(**valid_attributes, action_item: false).action_item
    assert_equal true, Cybort::Item.new(**valid_attributes, action_item: true).action_item
    assert_nil Cybort::Item.new(**valid_attributes).action_item
  end

  def test_defensively_freezes_collections_and_copies_serialized_values
    item = Cybort::Item.new(
      **valid_attributes,
      urls: ["https://example.test"],
      info: { source: { tags: ["rss"] } }
    )

    assert item.urls.frozen?
    assert item.info.frozen?
    assert_raises(FrozenError) { item.urls << "https://other.test" }
    assert_raises(FrozenError) { item.info.fetch(:source).fetch(:tags) << "new" }

    serialized = item.to_h
    serialized.fetch(:urls) << "https://other.test"
    serialized.fetch(:info).fetch(:source).fetch(:tags) << "new"

    assert_equal ["https://example.test"], item.urls
    assert_equal ["rss"], item.info.fetch(:source).fetch(:tags)
  end
end
