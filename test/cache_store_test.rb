require File.join(File.dirname(__FILE__), 'test_helper')
require 'active_support/testing/time_helpers'

# Not wrapped in a rolled-back transaction: invalidation happens after a real commit.
class CacheStoreTest < Minitest::Test
  include ActiveSupport::Testing::TimeHelpers

  def setup
    @store = CustomCounterCache.cache_store = ActiveSupport::Cache::MemoryStore.new
    @blog = Blog.create!
  end

  def teardown
    [Entry, Blog].each(&:delete_all)
    CustomCounterCache.cache_store = nil
  end

  def test_reading_computes_on_a_miss_then_serves_from_the_cache
    Entry.insert_all([{ blog_id: @blog.id }, { blog_id: @blog.id }])
    assert_equal 2, @blog.entries_count
    assert_equal 0, capture_sql { assert_equal 2, @blog.entries_count }.size
  end

  def test_a_child_change_deletes_the_key_after_commit
    assert_equal 0, @blog.entries_count
    ActiveRecord::Base.transaction do
      Entry.create!(blog: @blog)
      assert_equal 0, @blog.entries_count # still the cached value until commit
    end
    assert_equal 1, @blog.entries_count
  end

  def test_a_rolled_back_change_keeps_the_cached_value
    assert_equal 0, @blog.entries_count
    ActiveRecord::Base.transaction do
      Entry.create!(blog: @blog)
      raise ActiveRecord::Rollback
    end
    assert @store.exist?(CustomCounterCache.cache_key(@blog, :entries_count))
  end

  def test_expires_in_is_passed_to_the_store
    assert_equal 0, @blog.entries_count
    Entry.insert_all([{ blog_id: @blog.id }])
    assert_equal 0, @blog.entries_count
    travel(2.hours) { assert_equal 1, @blog.entries_count }
  end

  def test_update_method_and_bulk_recount_write_a_fresh_value
    assert_equal 0, @blog.entries_count
    Entry.insert_all([{ blog_id: @blog.id }]) # no callbacks: the cached 0 is now stale
    assert_equal 0, @blog.entries_count

    sql = capture_sql { assert_equal 1, Blog.recount_counter_caches(:entries_count) }

    refute sql.any? { |statement| statement.include?('"counters"') }
    assert_equal 1, @blog.entries_count
  end

  def test_writer_writes_the_cache
    @blog.entries_count = 7
    assert_equal 7, @blog.entries_count
  end

  def test_touch_bumps_the_owner_when_its_key_is_deleted
    @blog.update_column(:updated_at, 1.day.ago)
    Entry.create!(blog: @blog, draft: true)
    assert_operator @blog.reload.updated_at, :>, 1.minute.ago
  end

  def test_destroying_the_owner_deletes_its_keys_and_leaves_the_counters_table_alone
    assert_equal 0, @blog.entries_count
    sql = capture_sql { @blog.destroy! }
    refute @store.exist?(CustomCounterCache.cache_key(@blog, :entries_count))
    refute sql.any? { |statement| statement.include?('"counters"') }
  end

  # The owner is gone by the time its key is invalidated, so the touch must be skipped.
  def test_destroying_an_owner_along_with_its_children_skips_the_touch
    blog = CascadeBlog.create!
    CascadeEntry.create!(blog: blog, draft: true)
    blog.destroy!
    refute Blog.exists?(blog.id)
  end

  def test_reading_without_a_cache_store_raises_a_clear_error
    CustomCounterCache.cache_store = nil
    error = assert_raises(ArgumentError) { @blog.entries_count }
    assert_match(/CustomCounterCache.cache_store/, error.message)
  end

  def test_rails_cache_is_the_default_store
    CustomCounterCache.cache_store = nil
    rails_cache = ActiveSupport::Cache::MemoryStore.new
    Object.const_set(:Rails, Module.new { define_singleton_method(:cache) { rails_cache } })
    assert_same rails_cache, CustomCounterCache.cache_store
  ensure
    Object.send(:remove_const, :Rails)
  end

  def test_an_unknown_store_raises
    klass = Class.new(ApplicationRecord) { self.table_name = 'blogs' }
    assert_raises(ArgumentError) { klass.define_counter_cache(:x, store: :redis) { 0 } }
  end

  def capture_sql(&block)
    sql = []
    collector = ->(*, payload) { sql << payload[:sql] }
    ActiveSupport::Notifications.subscribed(collector, 'sql.active_record', &block)
    sql
  end
end
