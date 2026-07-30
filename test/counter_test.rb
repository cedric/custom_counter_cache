require File.join(File.dirname(__FILE__), 'test_helper')

class CounterTest < Minitest::Test

  def setup
    @user = User.create
    @box = Box.create
    Counter.destroy_all
  end

  def test_default_counter_value
    assert_equal 0, @user.published_count
    assert_equal 0, @box.green_balls_count
  end

  def test_create_and_destroy_counter
    @user.articles.create(state: 'published')
    assert_equal 1, Counter.count
    @user.destroy
    assert_equal 0, Counter.count
  end

  def test_create_and_destroy_polymorphic_association_counter
    @article = @user.articles.create(state: "published")
    assert_equal 0, @article.comments.size
    @comment = @article.comments.create(state: "published")
    assert_equal 1, @article.comments.size
    @article.destroy
    assert_equal 0, @article.comments.size
  end

  def test_increment_and_decrement_counter_with_conditions
    @article = @user.articles.create(state: 'unpublished')
    assert_equal 0, @user.published_count
    @article.update_attribute :state, 'published'
    assert_equal 1, @user.published_count
    3.times { |i| @user.articles.create(state: 'published') }
    assert_equal 4, @user.published_count
    @user.articles.each {|a| a.update(state: 'unpublished') }
    assert_equal 0, @user.published_count
  end

  def test_increment_and_decrement_polymorphic_counter_with_conditions
    @article = @user.articles.create(state: "published")
    @comment = @article.comments.create(state: "unpublished")
    assert_equal 0, @article.comments_count
    @comment.update_attribute :state, "published"
    assert_equal 1, @article.comments_count
    3.times { |i| @article.comments.create(state: "published") }
    assert_equal 4, @article.comments_count
    @article.comments.each { |c| c.update(state: 'unpublished') }
    assert_equal 0, @article.comments_count
  end

  def test_increment_and_decrement_counter_with_conditions_on_model_with_counter_column
    @ball = @box.balls.create(color: 'red')
    assert_equal 0, @box.reload.green_balls_count
    @ball.update_attribute :color, 'green'
    assert_equal 1, @box.reload.green_balls_count
    3.times { |i| @box.balls.create(color: 'green') }
    assert_equal 4, @box.reload.green_balls_count
    @box.balls.each {|b| b.update(color: 'red') }
    assert_equal 0, @box.reload.green_balls_count
  end

  # Test that an eager loaded
  def test_eager_loading_with_no_counter
    @article = @user.articles.create(state: 'unpublished')
    user = User.includes(:counters).first
    assert_equal 0, user.published_count

  end

  def test_eager_loading_with_counter
    @article = @user.articles.create(state: 'published')
    @user = User.includes(:counters).find(@user.id)
    assert_equal 1, @user.published_count
  end

  def test_except_option
    @ball = @box.balls.create
    assert_equal 1, @box.reload.lifetime_balls_count
    @ball.update(color: 'green')
    assert_equal 1, @box.reload.lifetime_balls_count
    @ball.destroy
    assert_equal 1, @box.reload.lifetime_balls_count
  end

  def test_only_option
    @ball = @box.balls.create
    assert_equal 0, @box.reload.destroyed_balls_count
    @ball.update(color: 'green')
    assert_equal 0, @box.reload.destroyed_balls_count
    @ball.destroy
    assert_equal 1, @box.reload.destroyed_balls_count
  end

  def test_reassigning_article_to_different_user_updates_both_counters
    @user2 = User.create
    @article = @user.articles.create(state: 'unpublished')
    assert_equal 0, @user.reload.published_count
    assert_equal 0, @user2.reload.published_count
    # Changing both user and state triggers the :if condition (state changed)
    # and the reassignment logic inside the callback updates the old user's counter too
    @article.update(user: @user2, state: 'published')
    assert_equal 0, @user.reload.published_count
    assert_equal 1, @user2.reload.published_count
  end

  # -- destroy loop regression --
  #
  # A consumer's Counter model might mistakenly add `dependent: :destroy` to
  # its `belongs_to :countable` (see test_helper.rb's Counter class and the
  # README "Note" on this). On a belongs_to, dependent: :destroy means "when
  # I am destroyed, also destroy the record I belong to" -- the opposite of
  # what a counter cache needs. Combined with the has_many :counters this gem
  # defines on the countable side, that mistake used to create a destroy
  # loop: destroying a countable record cascaded into destroying its
  # Counters, and each Counter's (wrongly configured) belongs_to cascaded
  # back into destroying the same countable record again, re-running its
  # full before_destroy chain against already-destroyed associations.
  #
  # has_many :counters now uses dependent: :delete_all, which deletes Counter
  # rows with a single SQL statement and never instantiates them or runs
  # their callbacks -- so a misconfigured Counter#belongs_to (like the one in
  # this test suite's fixtures, deliberately) can no longer cause the loop.

  def test_destroying_a_countable_record_with_a_dependent_association_does_not_recurse
    @user.articles.create!(state: 'published') # gives the user a real Counter row
    note = UserNote.create!(user: @user)

    @user.destroy!

    assert @user.destroyed?
    refute UserNote.exists?(note.id)
  end

  def test_counters_are_removed_via_a_single_delete_without_instantiating_them
    @user.articles.create!(state: 'published')
    assert_equal 1, Counter.where(countable: @user).count

    # dependent: :delete_all must never call Counter#destroy -- prove it by
    # making Counter#destroy raise, then destroying the user anyway.
    Counter.define_method(:destroy) { raise 'Counter#destroy should not be called' }

    @user.destroy!

    assert_equal 0, Counter.where(countable_type: 'User', countable_id: @user.id).count
  ensure
    Counter.send(:remove_method, :destroy) if Counter.instance_methods(false).include?(:destroy)
  end

  # -- update_counter_cache: polymorphic reassignment --
  #
  # For a polymorphic association, the old owner must be looked up by its
  # old *type* and old *id* together -- either can change independently
  # (moving to a different record of the same type only changes the id;
  # moving to a different type changes both).

  def test_reassigning_a_polymorphic_association_updates_both_old_and_new_owner_counters
    article1 = @user.articles.create!(state: 'unpublished')
    article2 = @user.articles.create!(state: 'unpublished')
    comment = article1.comments.create!(state: 'unpublished')
    comment.update!(state: 'published')
    assert_equal 1, article1.reload.comments_count
    assert_equal 0, article2.reload.comments_count

    # The :if condition only fires the callback on a state change, so toggle
    # state alongside the reassignment -- same pattern as
    # test_reassigning_article_to_different_user_updates_both_counters above.
    comment.update!(commentable: article2, state: 'unpublished')
    comment.update!(state: 'published')

    assert_equal 0, article1.reload.comments_count
    assert_equal 1, article2.reload.comments_count
  end

  # -- rescue StandardError / Heroku DATABASE_URL guard --
  #
  # Both class methods wrap their body in a rescue that swallows any
  # StandardError raised while table_exists? can't reach a database (e.g.
  # during `assets:precompile` on Heroku, where there is no DB connection at
  # all), but only when DATABASE_URL matches Heroku's placeholder value.
  # Anywhere else, the error must still propagate.

  def with_stubbed_table_exists(klass, error)
    klass.define_singleton_method(:table_exists?) { raise error }
    yield
  ensure
    klass.singleton_class.send(:remove_method, :table_exists?)
  end

  def test_define_counter_cache_reraises_when_database_url_is_not_the_heroku_placeholder
    klass = Class.new(ApplicationRecord) { self.table_name = 'users' }
    with_stubbed_table_exists(klass, 'no database connection') do
      assert_raises(RuntimeError) { klass.define_counter_cache(:whatever) { |r| 0 } }
    end
  end

  def test_define_counter_cache_swallows_error_when_database_url_is_the_heroku_placeholder
    klass = Class.new(ApplicationRecord) { self.table_name = 'users' }
    with_env('DATABASE_URL', 'postgres://user:pass@127.0.0.1/dbname') do
      with_stubbed_table_exists(klass, 'no database connection') do
        klass.define_counter_cache(:whatever) { |r| 0 } # must not raise
      end
    end
    refute klass.method_defined?(:whatever)
  end

  def test_update_counter_cache_reraises_when_database_url_is_not_the_heroku_placeholder
    klass = Class.new(ApplicationRecord) { self.table_name = 'articles' }
    with_stubbed_table_exists(klass, 'no database connection') do
      assert_raises(RuntimeError) { klass.update_counter_cache(:user, :whatever) }
    end
  end

  def test_update_counter_cache_swallows_error_when_database_url_is_the_heroku_placeholder
    klass = Class.new(ApplicationRecord) { self.table_name = 'articles' }
    with_env('DATABASE_URL', 'postgres://user:pass@127.0.0.1/dbname') do
      with_stubbed_table_exists(klass, 'no database connection') do
        klass.update_counter_cache(:user, :whatever) # must not raise
      end
    end
  end

  def with_env(key, value)
    original = ENV[key]
    ENV[key] = value
    yield
  ensure
    ENV[key] = original
  end

  # -- table_exists? early return (no error, just a missing table) --

  def test_define_counter_cache_is_a_no_op_when_the_table_does_not_exist
    klass = Class.new(ApplicationRecord) { self.table_name = 'nonexistent_table_xyz' }
    klass.define_counter_cache(:whatever) { |r| 0 }
    refute klass.method_defined?(:whatever)
    refute klass.method_defined?(:update_whatever)
  end

  def test_update_counter_cache_is_a_no_op_when_the_table_does_not_exist
    klass = Class.new(ApplicationRecord) { self.table_name = 'nonexistent_table_xyz' }
    klass.update_counter_cache(:user, :whatever)
    refute klass.method_defined?(:callback_user_whatever)
  end

  # -- update_counter_cache: :unless option --

  def test_unless_option_skips_the_callback_when_true
    @ball = @box.balls.create(color: 'red')
    assert_equal 1, @box.reload.non_green_balls_count
    @ball.update(color: 'green')
    # :unless suppresses the callback here, so the count is stale (still 1)
    # rather than recomputed to 0 -- proving the callback did not run.
    assert_equal 1, @box.reload.non_green_balls_count
  end

  def test_unless_option_runs_the_callback_when_false
    @ball = @box.balls.create(color: 'green')
    @ball.update(color: 'red')
    assert_equal 1, @box.reload.non_green_balls_count
  end

  # -- update_counter_cache: :prepend option --
  #
  # NOTE: this checks that :prepend is forwarded to the after_create callback
  # chain (the gem's own responsibility), not that it changes visible
  # execution order -- that's a separate, Rails-internals quirk: plain
  # sequential after_* callbacks in this Rails version don't necessarily run
  # in chain order just because one was prepended (confirmed with a bare
  # `after_create ..., prepend: true` outside this gem entirely).

  def test_prepend_option_is_forwarded_to_the_callback_chain
    after_create_filters = Ball._create_callbacks.select { |cb| cb.kind == :after }.map(&:filter)
    assert_operator after_create_filters.index(:callback_box_marker_b_count),
      :<, after_create_filters.index(:callback_box_marker_a_count),
      'expected the prepend: true callback (marker_b) to be ordered before the non-prepended one (marker_a)'
  end

end
