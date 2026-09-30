require File.join(File.dirname(__FILE__), 'test_helper')

class CounterTest < Minitest::Test

  # Non-joinable so nested saves use savepoints and test-level rollbacks stay possible.
  def setup
    ActiveRecord::Base.lease_connection.begin_transaction(joinable: false)
    @user = User.create
    @box = Box.create
  end

  def teardown
    ActiveRecord::Base.lease_connection.rollback_transaction
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

  # Eager-loaded :counters must read correctly with and without a matching row.
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
    # State must change too: the :if only fires the callback on a state change.
    @article.update(user: @user2, state: 'published')
    assert_equal 0, @user.reload.published_count
    assert_equal 1, @user2.reload.published_count
  end

  # -- destroy loop regression --
  # Counter#belongs_to :countable, dependent: :destroy used to loop back into destroying the owner;
  # has_many :counters uses dependent: :delete_all so no Counter callbacks run.

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

    # delete_all must never instantiate Counters, so make #destroy raise.
    Counter.define_method(:destroy) { raise 'Counter#destroy should not be called' }

    @user.destroy!

    assert_equal 0, Counter.where(countable_type: 'User', countable_id: @user.id).count
  ensure
    Counter.send(:remove_method, :destroy) if Counter.instance_methods(false).include?(:destroy)
  end

  # -- update_counter_cache: polymorphic reassignment --
  # The old owner is found by old type and old id, either of which can change independently.

  def test_reassigning_a_polymorphic_association_updates_both_old_and_new_owner_counters
    article1 = @user.articles.create!(state: 'unpublished')
    article2 = @user.articles.create!(state: 'unpublished')
    comment = article1.comments.create!(state: 'unpublished')
    comment.update!(state: 'published')
    assert_equal 1, article1.reload.comments_count
    assert_equal 0, article2.reload.comments_count

    # Toggle state so the :if fires (see the user reassignment test above).
    comment.update!(commentable: article2, state: 'unpublished')
    comment.update!(state: 'published')

    assert_equal 0, article1.reload.comments_count
    assert_equal 1, article2.reload.comments_count
  end

  # -- rescue StandardError / Heroku DATABASE_URL guard --
  # Errors are swallowed only when DATABASE_URL is Heroku's precompile placeholder.

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
    # Stale (1, not 0) proves :unless suppressed the recount.
    assert_equal 1, @box.reload.non_green_balls_count
  end

  def test_unless_option_runs_the_callback_when_false
    @ball = @box.balls.create(color: 'green')
    @ball.update(color: 'red')
    assert_equal 1, @box.reload.non_green_balls_count
  end

  # -- update_counter_cache: :prepend option --
  # Asserts chain order only; Rails doesn't guarantee that prepending changes run order here.

  def test_prepend_option_is_forwarded_to_the_callback_chain
    after_create_filters = Ball._create_callbacks.select { |cb| cb.kind == :after }.map(&:filter)
    assert_operator after_create_filters.index(:callback_box_marker_b_count),
      :<, after_create_filters.index(:callback_box_marker_a_count),
      'expected the prepend: true callback (marker_b) to be ordered before the non-prepended one (marker_a)'
  end

  # -- plain update_counter_cache (no options) --

  def test_plain_update_counter_cache_recounts_on_create_update_and_destroy
    library = Library.create!
    book = Book.create!(library: library)
    Book.create!(library: library)
    assert_equal 2, library.reload.books_count

    library.update_column(:books_count, 99)
    book.save!
    assert_equal 2, library.reload.books_count

    library.update_column(:books_count, 99)
    book.destroy!
    assert_equal 1, library.reload.books_count
  end

  def test_reassigning_by_foreign_key_recounts_both_old_and_new_owner
    old_library = Library.create!
    new_library = Library.create!
    book = Book.create!(library: old_library)
    assert_equal 1, old_library.reload.books_count

    book.update!(library: new_library)

    assert_equal 0, old_library.reload.books_count
    assert_equal 1, new_library.reload.books_count
  end

  def test_clearing_the_foreign_key_recounts_the_old_owner
    library = Library.create!
    book = Book.create!(library: library)

    book.update!(library: nil)

    assert_equal 0, library.reload.books_count
  end

  def test_saving_and_destroying_a_record_with_no_owner_does_nothing
    book = Book.create!
    book.save!
    book.destroy!
    assert book.destroyed?
  end

  def test_reassigning_when_the_old_owner_is_gone_counts_the_new_owner
    old_library = Library.create!
    new_library = Library.create!
    book = Book.create!(library: old_library)
    old_library.delete

    book.update!(library: new_library)

    assert_equal 1, new_library.reload.books_count
  end

  # -- polymorphic moves --

  def test_moving_a_polymorphic_association_across_types_recounts_both_owners
    article = @user.articles.create!
    photo = Photo.create!(id: article.id + 100)
    comment = article.comments.create!(state: 'published')
    assert_equal 1, article.comments_count

    comment.update!(commentable: photo, state: 'unpublished')
    assert_equal 0, article.comments_count
    comment.update!(state: 'published')
    assert_equal 1, photo.comments_count
    assert_equal 0, article.comments_count
  end

  def test_changing_only_the_polymorphic_type_recounts_both_owners
    article = @user.articles.create!
    photo = Photo.create!(id: article.id)
    comment = article.comments.create!(state: 'published')
    assert_equal 1, article.comments_count

    comment.update!(commentable_type: 'Photo', state: 'unpublished')
    refute comment.saved_change_to_commentable_id?
    assert comment.saved_change_to_commentable_type?
    assert_equal 0, article.comments_count
    comment.update!(state: 'published')
    assert_equal 1, photo.comments_count
    assert_equal 0, article.comments_count
  end

  # -- virtual counter storage --

  def test_virtual_counters_are_scoped_by_countable_type
    article = @user.articles.create!
    photo = Photo.create!(id: article.id)
    2.times { article.comments.create!(state: 'published') }
    photo.comments.create!(state: 'published')

    assert_equal 2, article.comments_count
    assert_equal 1, photo.comments_count
    assert_equal 2, Counter.where(key: 'comments_count').count

    photo.comments_count = 7
    assert_equal 7, photo.comments_count
    assert_equal 2, article.comments_count
  end

  def test_virtual_counter_writer_creates_one_row_then_updates_it
    article = @user.articles.create!

    article.comments_count = 3
    row = Counter.find_by!(countable: article, key: 'comments_count')
    assert_equal 3, row.value

    article.comments_count = 5
    assert_equal 1, Counter.where(countable: article, key: 'comments_count').count
    assert_equal 5, row.reload.value
  end

  def test_virtual_counter_writer_coerces_values_with_to_i
    article = @user.articles.create!

    article.comments_count = '3'
    assert_equal 3, article.comments_count
    article.comments_count = nil
    assert_equal 0, article.comments_count
    assert_equal 1, Counter.where(countable: article).count
  end

  def test_counters_association_is_only_defined_for_models_with_virtual_counters
    refute Library.reflect_on_association(:counters)
    refute Library.new.respond_to?(:counters)
    assert Box.reflect_on_association(:counters)
    assert_equal 1, Box.reflect_on_all_associations.count { |r| r.name == :counters }
  end

  # -- :only / :except with multiple events --

  def test_only_option_with_multiple_events_skips_the_others
    ball = @box.balls.create!
    assert_equal 1, @box.create_destroy_events_count
    ball.update!(color: 'green')
    assert_equal 1, @box.create_destroy_events_count
    ball.destroy!
    assert_equal 2, @box.create_destroy_events_count
  end

  def test_except_option_with_multiple_events_fires_only_on_the_remainder
    ball = @box.balls.create!
    assert_equal 0, @box.update_events_count
    ball.update!(color: 'green')
    assert_equal 1, @box.update_events_count
    ball.destroy!
    assert_equal 1, @box.update_events_count
  end

  # -- rollback --

  def test_rolling_back_the_child_save_reverts_a_column_counter
    library = Library.create!

    ActiveRecord::Base.transaction(requires_new: true) do
      Book.create!(library: library)
      assert_equal 1, library.reload.books_count
      raise ActiveRecord::Rollback
    end

    assert_equal 0, library.reload.books_count
  end

  def test_rolling_back_the_child_save_reverts_a_virtual_counter
    article = @user.articles.create!

    ActiveRecord::Base.transaction(requires_new: true) do
      article.comments.create!(state: 'published')
      assert_equal 1, article.comments_count
      raise ActiveRecord::Rollback
    end

    assert_equal 0, article.comments_count
    assert_equal 0, Counter.where(countable: article).count
  end

  # -- generated methods --

  def test_update_method_for_a_column_counter_persists_the_recomputed_value
    library = Library.create!
    Book.insert_all([{ library_id: library.id }, { library_id: library.id }]) # skips callbacks
    assert_equal 0, library.reload.books_count

    library.update_books_count

    assert_equal 2, library.reload.books_count
  end

  def test_update_counter_cache_defines_a_public_callback_method
    assert Ball.public_method_defined?(:callback_box_green_balls_count)
    assert Book.public_method_defined?(:callback_library_books_count)
  end

  def test_update_counter_cache_without_the_association_raises_a_clear_error
    klass = Class.new(ApplicationRecord) { self.table_name = 'articles' }
    error = assert_raises(ArgumentError) { klass.update_counter_cache(:user, :whatever) }
    assert_match(/belongs_to :user/, error.message)
  end

  # -- custom keys --

  def test_reassigning_with_a_custom_primary_key_recounts_the_old_owner
    team_a = Team.create!(code: 'A')
    team_b = Team.create!(code: 'B')
    player = Player.create!(team: team_a)
    Player.create!(team: team_a)

    player.update!(team: team_b)

    assert_equal 1, team_a.reload.players_count
    assert_equal 1, team_b.reload.players_count
  end

  def test_reassigning_a_polymorphic_association_with_custom_key_columns_recounts_both_owners
    photo1 = Photo.create!
    photo2 = Photo.create!
    tag = Tag.create!(target: photo1)
    assert_equal 1, photo1.tags_count

    tag.update!(target: photo2)

    assert_equal 0, photo1.tags_count
    assert_equal 1, photo2.tags_count
  end

  def test_moving_away_from_a_polymorphic_type_that_no_longer_exists_counts_the_new_owner
    article = @user.articles.create!
    comment = article.comments.create!(state: 'unpublished')
    comment.update_columns(commentable_type: 'RemovedModel')

    comment.update!(commentable: article, state: 'published')

    assert_equal 1, article.comments_count
  end

  # -- eager-loaded :counters --

  def test_eager_loaded_counters_answer_a_missing_row_without_a_query
    user = User.includes(:counters).find(@user.id)
    assert_equal 0, count_queries { assert_equal 0, user.published_count }
  end

  def test_eager_loaded_counters_reflect_an_update_to_an_existing_row
    @user.articles.create!(state: 'published')
    user = User.includes(:counters).find(@user.id)
    assert_equal 1, user.published_count

    user.articles.create!(state: 'published')

    assert_equal 2, user.published_count
    assert_equal 1, Counter.where(countable: user).count
  end

  def test_eager_loaded_counters_reflect_a_newly_created_row
    user = User.includes(:counters).find(@user.id)

    user.articles.create!(state: 'published')

    assert_equal 1, user.published_count
  end

  # Loading :counters while empty, then inserting the row, reproduces losing a create race.
  def test_virtual_counter_writer_updates_the_row_when_another_process_created_it_first
    article = Article.includes(:counters).find(@user.articles.create!.id)
    Counter.create!(countable: article, key: 'comments_count', value: 9)

    article.comments_count = 4

    assert_equal 4, article.comments_count
    assert_equal [4], Counter.where(countable: article, key: 'comments_count').pluck(:value)
  end

  def count_queries(&block)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name] == 'SCHEMA' }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &block)
    count
  end

end
