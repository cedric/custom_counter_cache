require File.join(File.dirname(__FILE__), 'test_helper')

# State lives in ActiveSupport::IsolatedExecutionState; only the main thread touches the database.
class IsolationTest < Minitest::Test
  def setup
    ActiveRecord::Base.lease_connection.begin_transaction(joinable: false)
    @library = Library.create!
  end

  def teardown
    ActiveRecord::Base.lease_connection.rollback_transaction
  end

  def test_skip_in_another_thread_does_not_suppress_this_threads_recounts
    while_held_open_in_another_thread(->(&inside) { CustomCounterCache.skip(&inside) }) do
      Book.create!(library: @library)
      assert_equal 1, @library.reload.books_count
    end
  end

  def test_batch_in_another_thread_does_not_collect_this_threads_recounts
    while_held_open_in_another_thread(->(&inside) { CustomCounterCache.batch(&inside) }) do
      Book.create!(library: @library)
      assert_equal 1, @library.reload.books_count
    end
  end

  def test_nested_skip_restores_the_outer_state_when_the_inner_block_ends
    CustomCounterCache.skip do
      CustomCounterCache.skip { Book.create!(library: @library) }
      Book.create!(library: @library)
      assert_equal 0, @library.reload.books_count
    end

    Book.create!(library: @library)
    assert_equal 3, @library.reload.books_count
  end

  def test_skip_restores_state_after_its_block_raises
    assert_raises(RuntimeError) { CustomCounterCache.skip { raise 'boom' } }

    Book.create!(library: @library)
    assert_equal 1, @library.reload.books_count
  end

  def test_a_raising_inner_skip_leaves_the_outer_skip_in_force
    CustomCounterCache.skip do
      assert_raises(RuntimeError) { CustomCounterCache.skip { raise 'boom' } }
      Book.create!(library: @library)
      assert_equal 0, @library.reload.books_count
    end
  end

  private

  # Holds `opener` open in a background thread while the block runs, then releases and joins it.
  def while_held_open_in_another_thread(opener)
    entered, release = Queue.new, Queue.new
    thread = Thread.new { opener.call { entered << true; release.pop } }
    entered.pop
    yield
  ensure
    release << true
    thread&.join
  end
end
