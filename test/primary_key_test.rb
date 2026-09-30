require File.join(File.dirname(__FILE__), 'test_helper')

class PrimaryKeyTest < Minitest::Test
  include ActiveJob::TestHelper

  def setup
    ActiveRecord::Base.lease_connection.begin_transaction(joinable: false)
    CustomCounterCache.cache_store = ActiveSupport::Cache::MemoryStore.new
    @vault = Vault.create!(code: 'v1')
    @other = Vault.create!(code: 'v2')
  end

  def teardown
    ActiveRecord::Base.lease_connection.rollback_transaction
    CustomCounterCache.cache_store = nil
    clear_enqueued_jobs
  end

  # -- column counter --

  def test_column_counter_recounts_on_create_and_destroy
    deposit = Deposit.create!(vault: @vault)
    Deposit.create!(vault: @vault)
    assert_equal 2, @vault.reload.deposits_count

    deposit.destroy!
    assert_equal 1, @vault.reload.deposits_count
  end

  def test_column_counter_recounts_both_owners_on_a_move
    deposit = Deposit.create!(vault: @vault)
    deposit.update!(vault: @other)

    assert_equal 0, @vault.reload.deposits_count
    assert_equal 1, @other.reload.deposits_count
  end

  def test_recount_skips_a_column_owner_deleted_before_it_ran
    sql = capture_sql do
      ActiveRecord::Base.transaction do
        Deposit.create!(vault: @vault)
        Vault.where(code: 'v1').delete_all
      end
    end
    refute sql.any? { |statement| statement.start_with?('UPDATE "vaults"') }, sql.inspect
  end

  # -- recount: :later --

  def test_later_job_is_enqueued_with_the_string_id_and_recounts_when_performed
    LaterDeposit.create!(vault: @vault)
    assert_enqueued_with(job: CustomCounterCache::RecountJob, args: ['Vault', 'v1', 'later_deposits_count'])
    assert_equal 0, @vault.reload.later_deposits_count

    perform_enqueued_jobs
    assert_equal 1, @vault.reload.later_deposits_count
  end

  # -- cache counter --

  def test_cache_counter_key_contains_the_code
    assert_equal 'custom_counter_cache/v1/Vault/v1/cached_deposits_count', CustomCounterCache.cache_key(@vault, :cached_deposits_count)
    assert_equal 0, @vault.cached_deposits_count
    Deposit.create!(vault: @vault)
    assert_equal 1, @vault.cached_deposits_count
    assert_equal 0, @other.cached_deposits_count
  end

  # -- counters table with a string countable_id --

  def test_counters_table_counter_recounts_with_a_string_countable_id
    locker = Locker.create!(code: 'L1')
    item = LockerItem.create!(locker: locker)
    LockerItem.create!(locker: locker)

    assert_equal 2, locker.reload.items_count
    assert_equal [2], StringCounter.where(countable_type: 'Locker', countable_id: 'L1', key: 'items_count').pluck(:value)

    item.destroy!
    assert_equal 1, Locker.find('L1').items_count
  end

  def test_counters_table_counter_moves_between_string_keyed_owners
    a, b = Locker.create!(code: 'A'), Locker.create!(code: 'B')
    item = LockerItem.create!(locker: a)
    item.update!(locker: b)

    assert_equal 0, a.reload.items_count
    assert_equal 1, b.reload.items_count
  end

  def test_recount_skips_a_counters_table_owner_deleted_before_it_ran
    locker = Locker.create!(code: 'L1')
    ActiveRecord::Base.transaction do
      LockerItem.create!(locker: locker)
      Locker.where(code: 'L1').delete_all
    end
    assert_equal 0, StringCounter.count
  end

  private

  def capture_sql(&block)
    sql = []
    collector = ->(*, payload) { sql << payload[:sql] }
    ActiveSupport::Notifications.subscribed(collector, 'sql.active_record', &block)
    sql
  end
end
