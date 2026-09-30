require File.join(File.dirname(__FILE__), 'test_helper')

class CombinationsTest < Minitest::Test
  include ActiveJob::TestHelper

  # Records deletes so tests can count invalidations.
  class SpyStore < ActiveSupport::Cache::MemoryStore
    attr_reader :deleted

    def delete(name, options = nil)
      (@deleted ||= []) << name
      super
    end
  end

  def setup
    ActiveRecord::Base.lease_connection.begin_transaction(joinable: false)
    @store = CustomCounterCache.cache_store = SpyStore.new
  end

  def teardown
    ActiveRecord::Base.lease_connection.rollback_transaction
    CustomCounterCache.cache_store = nil
    clear_enqueued_jobs
  end

  # -- recount: :later --

  def test_later_on_a_cache_counter_deletes_the_key_after_commit_and_enqueues_no_job
    blog = Blog.create!
    key = CustomCounterCache.cache_key(blog, :entries_count)
    assert_equal 0, blog.entries_count
    assert @store.exist?(key)

    LaterEntry.create!(blog: blog)

    refute @store.exist?(key)
    assert_no_enqueued_jobs
    assert_equal 1, blog.entries_count
  end

  def test_batch_with_later_enqueues_one_job_per_owner
    shop = Shop.create!
    CustomCounterCache.batch do
      3.times { Receipt.create!(shop: shop) }
      assert_no_enqueued_jobs
    end

    assert_enqueued_jobs 1, only: CustomCounterCache::RecountJob
    perform_enqueued_jobs
    assert_equal 3, shop.reload.receipts_count
  end

  # -- batch --

  def test_batch_recounts_a_grandparent_once_for_grandchildren_under_different_intermediates
    forum = Forum.create!
    topic_a, topic_b = forum.topics.create!, forum.topics.create!

    sql = capture_sql do
      CustomCounterCache.batch do
        2.times { Vote.create!(topic: topic_a) }
        2.times { Vote.create!(topic: topic_b) }
      end
    end

    assert_equal 1, sql.count { |statement| statement.start_with?('UPDATE "forums"') }
    assert_equal 4, forum.reload.votes_count
  end

  def test_batch_with_a_cache_counter_invalidates_once
    blog = Blog.create!
    key = CustomCounterCache.cache_key(blog, :entries_count)
    @store.write(key, 99)
    @store.deleted&.clear

    CustomCounterCache.batch do
      3.times { Entry.create!(blog: blog) }
      assert_equal 99, blog.entries_count
    end

    assert_equal 1, @store.deleted.count(key)
    assert_equal 3, blog.entries_count
  end

  def test_batch_keeps_the_first_owner_instance_so_its_loaded_counters_stay_current
    user = User.create!
    first = User.includes(:counters).find(user.id)
    second = User.find(user.id)
    assert first.counters.loaded?

    CustomCounterCache.batch do
      Article.create!(user: first, state: 'published')
      Article.create!(user: second, state: 'published')
    end

    assert_equal 2, first.published_count
  end

  # -- on_change: on a grandparent path --

  def test_on_change_on_a_grandparent_path_recounts_only_for_listed_attributes
    district = District.create!
    precinct = district.precincts.create!
    ballot = Ballot.create!(precinct: precinct)
    district.update_column(:ballots_count, 99)

    ballot.update!(note: 'unlisted')
    assert_equal 99, district.reload.ballots_count

    ballot.update!(weight: 5)
    assert_equal 1, district.reload.ballots_count
  end

  def test_on_change_on_a_grandparent_path_watches_the_first_steps_key
    district_a, district_b = District.create!, District.create!
    precinct_a, precinct_b = district_a.precincts.create!, district_b.precincts.create!
    ballot = Ballot.create!(precinct: precinct_a)
    [district_a, district_b].each { |district| district.update_column(:ballots_count, 99) }

    ballot.update!(precinct: precinct_b)

    assert_equal [0, 1], [district_a.reload.ballots_count, district_b.reload.ballots_count]
  end

  # -- dedup --

  def test_separately_loaded_instances_of_one_owner_recount_once_per_transaction
    library = Library.create!
    first, second = Library.find(library.id), Library.find(library.id)

    sql = capture_sql do
      ActiveRecord::Base.transaction do
        Book.create!(library: first)
        Book.create!(library: second)
      end
    end

    assert_equal 1, sql.count { |statement| statement.start_with?('UPDATE "libraries"') }
    assert_equal 2, library.reload.books_count
  end

  # -- store: :cache vs a column --

  def test_cache_store_wins_over_a_column_of_the_same_name
    gauge = Gauge.create!
    assert_equal :cache, Gauge.custom_counter_cache_storage(:foo_count)

    assert_equal 42, gauge.foo_count
    gauge.foo_count = 7
    assert_equal 7, gauge.foo_count
    assert_equal 7, @store.read(CustomCounterCache.cache_key(gauge, :foo_count))

    gauge.update_foo_count
    assert_equal 42, gauge.foo_count
    assert_equal 0, Gauge.where(id: gauge.id).pick(:foo_count)
    assert_equal 0, gauge[:foo_count]
  end

  private

  def capture_sql(&block)
    sql = []
    collector = ->(*, payload) { sql << payload[:sql] }
    ActiveSupport::Notifications.subscribed(collector, 'sql.active_record', &block)
    sql
  end
end
