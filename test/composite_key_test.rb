require File.join(File.dirname(__FILE__), 'test_helper')

class CompositeKeyTest < Minitest::Test
  include ActiveJob::TestHelper

  def setup
    ActiveRecord::Base.lease_connection.begin_transaction(joinable: false)
    CustomCounterCache.cache_store = ActiveSupport::Cache::MemoryStore.new
    @eu7 = Store.create!(region: 'eu', number: 7)
    @eu8 = Store.create!(region: 'eu', number: 8)
    @us7 = Store.create!(region: 'us', number: 7)
  end

  def teardown
    ActiveRecord::Base.lease_connection.rollback_transaction
    CustomCounterCache.cache_store = nil
    clear_enqueued_jobs
  end

  def test_column_counter_recounts_on_create_and_destroy
    sale = Sale.create!(store: @eu7)
    Sale.create!(store: @eu7)
    assert_equal 2, @eu7.reload.sales_count

    sale.destroy!
    assert_equal 1, @eu7.reload.sales_count
  end

  def test_moving_to_an_owner_that_differs_in_every_key_column_recounts_both
    sale = Sale.create!(store: @eu7)
    sale.update!(store_region: 'us', store_number: 7)
    assert_equal 0, @eu7.reload.sales_count
    assert_equal 1, @us7.reload.sales_count
  end

  def test_moving_to_an_owner_that_differs_in_one_key_column_recounts_both
    sale = Sale.create!(store: @eu7)
    sale.update!(store: @eu8)
    assert_equal 0, @eu7.reload.sales_count
    assert_equal 1, @eu8.reload.sales_count
  end

  def test_on_change_watches_every_foreign_key_column
    sale = Sale.create!(store: @eu7)
    @eu7.update_column(:sales_count, 99)
    sale.update!(amount: 5) # listed attribute: recounts
    assert_equal 1, @eu7.reload.sales_count

    @eu8.update_column(:sales_count, 99)
    sale.update!(store_number: 8) # key column, not listed: still recounts both
    assert_equal [0, 1], [@eu7.reload.sales_count, @eu8.reload.sales_count]
  end

  def test_recount_counter_caches_handles_composite_keys
    Sale.insert_all([{ store_region: 'eu', store_number: 7 }, { store_region: 'us', store_number: 7 }])
    assert_equal 3, Store.recount_counter_caches(:sales_count)
    assert_equal [1, 0, 1], [@eu7, @eu8, @us7].map { |store| store.reload.sales_count }
  end

  def test_later_job_finds_the_owner_by_its_composite_key
    Refund.create!(store: @eu8)
    assert_enqueued_with(job: CustomCounterCache::RecountJob, args: ['Store', ['eu', 8], 'refunds_count'])
    perform_enqueued_jobs
    assert_equal 1, @eu8.reload.refunds_count
  end

  def test_cache_counter_keys_include_every_key_column
    assert_equal 'custom_counter_cache/v1/Store/eu-7/cached_sales_count', CustomCounterCache.cache_key(@eu7, :cached_sales_count)
    assert_equal 0, @eu7.cached_sales_count
    Sale.create!(store: @eu7)
    assert_equal 1, @eu7.cached_sales_count
    assert_equal 0, @eu8.cached_sales_count
  end

  def test_recount_skips_a_composite_owner_deleted_before_it_ran
    ActiveRecord::Base.transaction do
      Sale.create!(store: @eu7)
      Store.where(region: 'eu', number: 7).delete_all
    end
    refute Store.exists?(region: 'eu', number: 7)
  end

  def test_counters_table_counter_on_a_composite_key_owner_raises_a_clear_error
    kiosk = Kiosk.find(['eu', 7])
    error = assert_raises(ArgumentError) { kiosk.tallies_count }
    assert_match(/composite primary key/, error.message)
    assert_match(/store: :cache/, error.message)
  end
end
