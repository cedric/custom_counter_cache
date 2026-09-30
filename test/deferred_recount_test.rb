require File.join(File.dirname(__FILE__), 'test_helper')

# Commits for real, as in production, rather than inside the per-test transaction.
class DeferredRecountTest < Minitest::Test
  include ActiveJob::TestHelper

  def setup
    @shop = Shop.create!
  end

  def teardown
    [Order, Receipt, Shop, Book, Library].each(&:delete_all)
    clear_enqueued_jobs
  end

  def test_after_commit_recounts_once_the_transaction_commits
    ActiveRecord::Base.transaction do
      Order.create!(shop: @shop)
      assert_equal 0, @shop.reload.orders_count
    end
    assert_equal 1, @shop.reload.orders_count
  end

  def test_after_commit_recounts_immediately_without_an_open_transaction
    Order.create!(shop: @shop)
    assert_equal 1, @shop.reload.orders_count
  end

  def test_after_commit_recounts_each_owner_once_per_transaction
    sql = capture_sql do
      ActiveRecord::Base.transaction { 5.times { Order.create!(shop: @shop) } }
    end
    assert_equal 5, @shop.reload.orders_count
    assert_equal 1, sql.count { |statement| statement.start_with?('UPDATE "shops"') }
  end

  def test_after_commit_drops_the_recount_on_rollback_and_schedules_again_next_time
    ActiveRecord::Base.transaction do
      Order.create!(shop: @shop)
      raise ActiveRecord::Rollback
    end
    assert_equal 0, @shop.reload.orders_count

    ActiveRecord::Base.transaction { Order.create!(shop: @shop) }
    assert_equal 1, @shop.reload.orders_count
  end

  def test_after_commit_survives_a_rolled_back_savepoint_that_scheduled_it_first
    ActiveRecord::Base.transaction do
      ActiveRecord::Base.transaction(requires_new: true) do
        Order.create!(shop: @shop)
        raise ActiveRecord::Rollback
      end
      Order.create!(shop: @shop)
    end
    assert_equal 1, @shop.reload.orders_count
  end

  def test_later_enqueues_one_job_per_owner_after_commit
    ActiveRecord::Base.transaction do
      3.times { Receipt.create!(shop: @shop) }
      assert_no_enqueued_jobs
    end
    assert_enqueued_jobs 1, only: CustomCounterCache::RecountJob
    assert_equal 0, @shop.reload.receipts_count

    perform_enqueued_jobs
    assert_equal 3, @shop.reload.receipts_count
  end

  def test_later_enqueues_nothing_on_rollback
    ActiveRecord::Base.transaction do
      Receipt.create!(shop: @shop)
      raise ActiveRecord::Rollback
    end
    assert_no_enqueued_jobs
  end

  def test_recount_job_ignores_an_owner_deleted_before_it_ran
    Receipt.create!(shop: @shop)
    Receipt.delete_all
    @shop.delete
    perform_enqueued_jobs
    assert_performed_jobs 1
  end

  def test_batch_flush_inside_a_transaction_still_defers
    ActiveRecord::Base.transaction do
      CustomCounterCache.batch { 3.times { Order.create!(shop: @shop) } }
      assert_equal 0, @shop.reload.orders_count
    end
    assert_equal 3, @shop.reload.orders_count
  end

  def test_batch_flush_outside_a_transaction_recounts_immediately
    CustomCounterCache.batch { 2.times { Order.create!(shop: @shop) } }
    assert_equal 2, @shop.reload.orders_count
  end

  def test_recount_job_ignores_a_model_class_that_no_longer_exists
    CustomCounterCache::RecountJob.perform_now('RemovedModel', 1, 'orders_count')
  end

  def test_an_unknown_recount_timing_raises
    error = assert_raises(ArgumentError) { Order.update_counter_cache(:shop, :orders_count, recount: :someday) }
    assert_match(/recount/, error.message)
    assert_raises(ArgumentError) { Order.update_counter_cache(:shop, :orders_count, recount: :inline) }
  end

  def capture_sql(&block)
    sql = []
    collector = ->(*, payload) { sql << payload[:sql] }
    ActiveSupport::Notifications.subscribed(collector, 'sql.active_record', &block)
    sql
  end
end
