require File.join(File.dirname(__FILE__), 'test_helper')
require 'active_support/testing/assertions'
require 'active_support/testing/error_reporter_assertions'

# A recount runs after the save has committed, so its failure mustn't make the save look failed.
class RecountFailureTest < Minitest::Test
  include ActiveSupport::Testing::Assertions
  include ActiveSupport::Testing::ErrorReporterAssertions

  def setup
    ActiveRecord::Base.lease_connection.begin_transaction(joinable: false)
    @broken = FlakyLibrary.create!(name: 'broken')
    @fine = FlakyLibrary.create!(name: 'fine')
  end

  def teardown
    ActiveRecord::Base.lease_connection.rollback_transaction
  end

  def test_a_failed_recount_is_reported_and_the_save_returns_normally
    report = assert_error_reported(RuntimeError) { FlakyBook.create!(library: @broken) }

    assert_equal 'count failed', report.error.message
    assert report.handled
    assert_equal 'custom_counter_cache', report.source
    assert_equal({ owner: 'FlakyLibrary', owner_id: @broken.id, counter: 'books_count' }, report.context.slice(:owner, :owner_id, :counter))
    assert_equal 1, FlakyBook.where(library_id: @broken.id).count
  end

  def test_other_recounts_in_the_same_commit_still_run
    assert_error_reported(RuntimeError) do
      ActiveRecord::Base.transaction do
        FlakyBook.create!(library: @broken)
        FlakyBook.create!(library: @fine)
      end
    end
    assert_equal 1, @fine.reload.books_count
  end

  def test_in_debug_mode_the_failure_is_raised_to_the_developer
    ActiveSupport.error_reporter.debug_mode = true
    error = assert_raises(ActiveSupport::ErrorReporter::UnexpectedError) { FlakyBook.create!(library: @broken) }
    assert_instance_of RuntimeError, error.cause
    assert_equal 'count failed', error.cause.message
  ensure
    ActiveSupport.error_reporter.debug_mode = false
  end

  def test_the_failure_is_logged_for_apps_without_an_error_subscriber
    log = StringIO.new
    previous, ActiveRecord::Base.logger = ActiveRecord::Base.logger, Logger.new(log)
    assert_error_reported(RuntimeError) { FlakyBook.create!(library: @broken) }
    assert_match(/FlakyLibrary.*books_count.*count failed/, log.string)
  ensure
    ActiveRecord::Base.logger = previous
  end

  # Jobs keep raising so the queue's retries apply.
  def test_the_recount_job_still_raises
    require 'custom_counter_cache/recount_job'
    assert_raises(RuntimeError) { CustomCounterCache::RecountJob.perform_now('FlakyLibrary', @broken.id, 'books_count') }
  end

  def test_calling_the_update_method_directly_still_raises
    assert_raises(RuntimeError) { @broken.update_books_count }
  end
end
