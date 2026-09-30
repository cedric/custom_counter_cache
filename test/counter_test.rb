require File.join(File.dirname(__FILE__), 'test_helper')
require 'rake'

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

  # -- defining counters never touches the database --

  def test_defining_counters_does_not_query_the_database
    klass = nil
    queries = count_queries do
      klass = Class.new(ApplicationRecord) do
        self.table_name = 'nonexistent_table_xyz'
        belongs_to :user
        define_counter_cache(:whatever) { |r| 0 }
        update_counter_cache :user, :published_count
      end
    end
    assert_equal 0, queries
    assert klass.method_defined?(:update_whatever)
    assert klass.method_defined?(:callback_user_published_count)
  end

  # e.g. a migration that adds the column and backfills it after the model has loaded.
  def test_a_counter_column_added_after_the_schema_loaded_is_used
    Widget.column_names
    ActiveRecord::Base.lease_connection.add_column :widgets, :parts_count, :integer, default: 0
    Widget.reset_column_information
    widget = Widget.create!

    widget.update_parts_count

    assert_equal 3, Widget.find(widget.id).parts_count
    assert_equal 0, Counter.where(countable: widget).count
  ensure
    Widget.reset_column_information
  end

  def test_column_counter_accessors_behave_like_plain_attributes
    @box.green_balls_count = 5

    assert_equal 5, @box.green_balls_count
    assert @box.green_balls_count_changed?
    @box.save!
    assert_equal 5, @box.reload.green_balls_count
  end

  def test_counters_are_stored_in_the_configured_counter_class
    gadget = Gadget.create!

    gadget.update_clicks_count

    assert_equal 2, gadget.clicks_count
    assert_equal 1, GadgetCounter.where(countable: gadget).count
    assert_equal 0, Counter.where(countable: gadget).count
  end

  def test_destroying_a_model_with_only_column_counters_leaves_the_counters_table_alone
    library = Library.create!
    sql = capture_sql { library.destroy! }
    refute sql.any? { |s| s.include?('"counters"') }, sql.inspect
  end

  # -- update_counter_cache: :unless option --

  def test_unless_option_skips_the_callback_when_true
    @ball = @box.balls.create(color: 'red')
    assert_equal 1, @box.reload.non_green_balls_count
    @ball.update(color: 'green')
    # Stale (1, not 0) proves :unless suppressed the recount.
    assert_equal 1, @box.reload.non_green_balls_count
  end

  def test_if_option_does_not_suppress_the_recount_on_destroy
    article = @user.articles.create!(state: 'published')
    assert_equal 1, @user.published_count

    Article.find(article.id).destroy!

    assert_equal 0, @user.published_count
  end

  def test_unless_option_does_not_suppress_the_recount_on_destroy
    @box.balls.create!(color: 'red')
    green = @box.balls.create!(color: 'green')
    @box.non_green_balls_count = 99

    green.destroy!

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

  def test_virtual_counter_writer_accepts_whole_values
    article = @user.articles.create!

    { '3' => 3, nil => 0, 4.0 => 4, BigDecimal('5') => 5, Rational(6, 1) => 6 }.each do |given, stored|
      article.comments_count = given
      assert_equal stored, article.comments_count, "for #{given.inspect}"
    end
    assert_equal 1, Counter.where(countable: article).count
  end

  # The counters table holds integers; truncating 2.5 to 2 would silently store a wrong value.
  def test_virtual_counter_writer_rejects_values_it_would_have_to_truncate
    article = @user.articles.create!

    [2.5, BigDecimal('0.1'), Float::INFINITY, Float::NAN, '3.5', 'many', true].each do |given|
      error = assert_raises(ArgumentError, "for #{given.inspect}") { article.comments_count = given }
      assert_match(/Article#comments_count/, error.message)
      assert_match(/store: :cache/, error.message)
    end
    assert_equal 0, Counter.where(countable: article).count
  end

  def test_update_method_rejects_a_fractional_block_result_for_the_counters_table
    klass = Class.new(Article) { define_counter_cache(:average_score) { |article| 2.5 } }
    error = assert_raises(ArgumentError) { klass.find(@user.articles.create!.id).update_average_score }
    assert_match(/average_score/, error.message)
  end

  # Declared up front because whether a counter is a column is only known at runtime.
  def test_every_model_with_counter_caches_gets_one_counters_association
    assert Library.reflect_on_association(:counters)
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

  # -- recounts run after commit --

  def test_a_recount_waits_for_the_saving_transaction_to_commit
    library = Library.create!

    ActiveRecord::Base.transaction do
      Book.create!(library: library)
      assert_equal 0, library.reload.books_count
    end

    assert_equal 1, library.reload.books_count
  end

  def test_a_rolled_back_save_never_recounts_a_column_counter
    library = Library.create!

    ActiveRecord::Base.transaction(requires_new: true) do
      Book.create!(library: library)
      raise ActiveRecord::Rollback
    end

    assert_equal 0, library.reload.books_count
  end

  def test_a_rolled_back_save_never_recounts_a_virtual_counter
    article = @user.articles.create!

    ActiveRecord::Base.transaction(requires_new: true) do
      article.comments.create!(state: 'published')
      raise ActiveRecord::Rollback
    end

    assert_equal 0, article.comments_count
    assert_equal 0, Counter.where(countable: article).count
  end

  def test_calling_the_update_method_directly_recounts_immediately
    library = Library.create!
    ActiveRecord::Base.transaction do
      Book.create!(library: library)
      library.update_books_count
      assert_equal 1, library.reload.books_count
    end
  end

  def test_after_commit_recount_keeps_the_owners_unsaved_changes
    library = Library.create!(name: 'original')
    library.name = 'unsaved edit'
    Book.create!(library: library)
    assert_equal 'unsaved edit', library.name
    assert_equal 1, library.books_count
  end

  def test_after_commit_recount_skips_an_owner_deleted_before_it_ran
    library = Library.create!
    ActiveRecord::Base.transaction do
      Book.create!(library: library)
      Library.where(id: library.id).delete_all
    end
    refute Library.exists?(library.id)
  end

  # -- generated methods --

  def test_update_method_for_a_column_counter_persists_the_recomputed_value
    library = Library.create!
    Book.insert_all([{ library_id: library.id }, { library_id: library.id }]) # skips callbacks
    assert_equal 0, library.reload.books_count

    library.update_books_count

    assert_equal 2, library.reload.books_count
  end

  def test_column_counter_update_writes_only_the_counter_column
    library = Library.create!(name: 'original')
    other_copy = Library.find(library.id)
    updated_at = Library.find(library.id).updated_at
    library.name = 'unsaved edit'

    Book.create!(library: library)

    persisted = Library.find(library.id)
    assert_equal 1, persisted.books_count
    assert_equal 'original', persisted.name
    assert_equal updated_at, persisted.updated_at
    assert_equal 'unsaved edit', library.name
    other_copy.update!(name: 'other copy') # no StaleObjectError: lock_version untouched
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

  def test_update_counter_cache_on_a_non_belongs_to_association_raises
    klass = Class.new(ApplicationRecord) { self.table_name = 'users'; has_many :articles }
    error = assert_raises(ArgumentError) { klass.update_counter_cache(:articles, :whatever) }
    assert_match(/belongs_to :articles/, error.message)
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

  # -- grandparent counters --

  def test_grandparent_counter_recounts_on_create_move_and_destroy
    forum_a, forum_b = Forum.create!, Forum.create!
    topic_a1, topic_a2 = forum_a.topics.create!, forum_a.topics.create!
    topic_b = forum_b.topics.create!

    vote = Vote.create!(topic: topic_a1)
    assert_equal 1, forum_a.reload.votes_count

    vote.update!(topic: topic_b)
    assert_equal 0, forum_a.reload.votes_count
    assert_equal 1, forum_b.reload.votes_count

    vote.destroy!
    assert_equal 0, forum_b.reload.votes_count
    assert_equal 0, topic_a2.votes.count
  end

  def test_moving_within_the_same_grandparent_recounts_it_once
    forum = Forum.create!
    topic1, topic2 = forum.topics.create!, forum.topics.create!
    vote = Vote.create!(topic: topic1)

    sql = capture_sql { vote.update!(topic: topic2) }

    assert_equal 1, sql.count { |statement| statement.start_with?('UPDATE "forums"') }
    assert_equal 1, forum.reload.votes_count
  end

  def test_moving_the_intermediate_record_recounts_both_grandparents
    forum_a, forum_b = Forum.create!, Forum.create!
    topic = forum_a.topics.create!
    2.times { Vote.create!(topic: topic) }
    assert_equal 2, forum_a.reload.votes_count

    topic.update!(forum: forum_b)

    assert_equal 0, forum_a.reload.votes_count
    assert_equal 2, forum_b.reload.votes_count
  end

  def test_grandparent_path_stops_at_a_nil_step
    topic = Topic.create!
    vote = Vote.create!(topic: topic)
    vote.destroy!
    assert vote.destroyed?
  end

  def test_grandparent_path_through_a_polymorphic_step
    forum = Forum.create!
    topic = forum.topics.create!
    poll = Poll.create!

    reply = Reply.create!(parent: topic)
    assert_equal 1, forum.reload.replies_count

    reply.update!(parent: poll) # Poll has no forum: that side of the path stops
    assert_equal 0, forum.reload.replies_count

    Reply.create!(parent: poll)
    assert_equal 0, forum.reload.replies_count
  end

  def test_grandparent_path_with_an_unknown_later_step_raises_on_first_use
    error = assert_raises(ArgumentError) { MisdirectedVote.create!(topic: Topic.create!) }
    assert_match(/Topic must declare belongs_to :galaxy/, error.message)
  end

  def test_grandparent_path_past_a_polymorphic_step_requires_belongs_to
    error = assert_raises(ArgumentError) { Reply.create!(parent: Quiz.create!) }
    assert_match(/Quiz must declare belongs_to :forum/, error.message)
  end

  # -- batch / skip --

  def test_batch_recounts_each_owner_once_when_the_block_ends
    library = Library.create!
    sql = capture_sql do
      CustomCounterCache.batch do
        100.times { Book.create!(library: library) }
        assert_equal 0, library.reload.books_count
      end
    end

    assert_equal 100, library.reload.books_count
    assert_equal 1, sql.count { |statement| statement.start_with?('UPDATE "libraries"') }
  end

  def test_batch_recounts_every_owner_and_counter_it_saw
    library1, library2 = Library.create!, Library.create!
    article = @user.articles.create!(state: 'unpublished')

    CustomCounterCache.batch do
      Book.create!(library: library1)
      2.times { Book.create!(library: library2) }
      article.update!(state: 'published')
    end

    assert_equal [1, 2], [library1.reload.books_count, library2.reload.books_count]
    assert_equal 1, @user.published_count
  end

  def test_nested_batches_flush_when_the_outermost_ends
    library = Library.create!
    CustomCounterCache.batch do
      CustomCounterCache.batch { Book.create!(library: library) }
      assert_equal 0, library.reload.books_count
    end
    assert_equal 1, library.reload.books_count
  end

  def test_batch_still_recounts_when_the_block_raises
    library = Library.create!
    assert_raises(RuntimeError) do
      CustomCounterCache.batch do
        Book.create!(library: library)
        raise 'boom'
      end
    end
    assert_equal 1, library.reload.books_count
  end

  def test_skip_drops_recounts_until_recounted_explicitly
    library = Library.create!
    CustomCounterCache.skip { 3.times { Book.create!(library: library) } }
    assert_equal 0, library.reload.books_count

    Book.create!(library: library)
    assert_equal 4, library.reload.books_count
  end

  def test_skip_inside_a_batch_drops_those_recounts
    library1, library2 = Library.create!, Library.create!
    CustomCounterCache.batch do
      Book.create!(library: library1)
      CustomCounterCache.skip { Book.create!(library: library2) }
    end
    assert_equal [1, 0], [library1.reload.books_count, library2.reload.books_count]
  end

  # -- recount_counter_caches --

  def test_recount_repairs_a_column_counter_after_bulk_writes
    library = Library.create!
    Book.insert_all([{ library_id: library.id }] * 3)
    assert_equal 0, library.reload.books_count

    Library.recount_counter_caches
    assert_equal 3, library.reload.books_count

    Book.where(library_id: library.id).limit(1).delete_all
    Library.recount_counter_caches
    assert_equal 2, library.reload.books_count
  end

  def test_recount_repairs_a_virtual_counter_after_bulk_writes
    Article.insert_all([{ user_id: @user.id, state: 'published' }] * 3)
    assert_equal 0, @user.published_count

    User.recount_counter_caches
    assert_equal 3, @user.published_count

    Article.where(user_id: @user.id).update_all(state: 'unpublished')
    User.recount_counter_caches
    assert_equal 0, @user.published_count

    Article.delete_all
    User.recount_counter_caches
    assert_equal 0, @user.published_count
  end

  def test_recount_only_touches_the_named_counters
    Ball.insert_all([{ box_id: @box.id, color: 'green' }, { box_id: @box.id, color: 'red' }])
    @box.update_columns(green_balls_count: 99)
    @box.non_green_balls_count = 42

    Box.recount_counter_caches(:green_balls_count)
    assert_equal [1, 42], [@box.reload.green_balls_count, @box.non_green_balls_count]

    @box.update_columns(green_balls_count: 99)
    Box.recount_counter_caches('non_green_balls_count')
    assert_equal [99, 1], [@box.reload.green_balls_count, @box.non_green_balls_count]
  end

  def test_recount_scope_limits_the_records
    library1, library2 = Library.create!, Library.create!
    Book.insert_all([{ library_id: library1.id }, { library_id: library2.id }])

    assert_equal 1, Library.recount_counter_caches(scope: Library.where(id: library1.id))
    assert_equal [1, 0], [library1.reload.books_count, library2.reload.books_count]
  end

  def test_recount_with_an_unknown_counter_raises_naming_the_model
    error = assert_raises(ArgumentError) { Library.recount_counter_caches(:books_count, :nope_count) }
    assert_match(/Library.*nope_count/, error.message)
    assert_raises(ArgumentError) { Library.recount_counter_caches('published_count') }
  end

  def test_recount_returns_the_number_of_records_processed
    3.times { Library.create! }
    assert_equal 3, Library.recount_counter_caches
    assert_equal 3, Library.recount_counter_caches(:books_count, batch_size: 1)
    assert_equal 0, Library.recount_counter_caches(scope: Library.none)
  end

  def test_recount_preloads_counters_so_queries_do_not_grow_with_the_records
    counters_selects = lambda do |users|
      users.times { User.create!.tap { |user| Article.insert_all([{ user_id: user.id, state: 'published' }]) } }
      capture_sql { User.recount_counter_caches }.count { |statement| statement.match?(/SELECT .* FROM "counters"/) }
    end

    small = counters_selects.call(2)
    large = counters_selects.call(4)
    assert_equal small, large
    assert_operator small, :<=, 1
  end

  def test_recount_repairs_counts_inside_skip
    library = Library.create!
    CustomCounterCache.skip do
      Book.insert_all([{ library_id: library.id }] * 2)
      Article.insert_all([{ user_id: @user.id, state: 'published' }])
      Library.recount_counter_caches
      User.recount_counter_caches
    end

    assert_equal 2, library.reload.books_count
    assert_equal 1, @user.published_count
  end

  # -- custom_counter_cache:recount rake task --

  # Loaded once, in its own Rake application: reloading the file would reset its coverage each time.
  RECOUNT_TASK = begin
    application = Rake::Application.new
    previous = Rake.application
    Rake.application = application
    begin
      Rake::Task.define_task(:environment)
      load File.expand_path('../lib/tasks/custom_counter_cache.rake', __dir__)
    ensure
      Rake.application = previous
    end
    application['custom_counter_cache:recount']
  end

  # Runs the task with only the given ENV variables set, restoring ENV afterwards.
  def run_recount_task(env)
    keys = %w[MODEL COUNTERS BATCH_SIZE]
    saved = ENV.to_h.slice(*keys)
    keys.each { |key| ENV.delete(key) }
    env.each { |key, value| ENV[key] = value }
    RECOUNT_TASK.reenable
    RECOUNT_TASK.invoke
  ensure
    keys.each { |key| ENV.delete(key) }
    saved.each { |key, value| ENV[key] = value }
  end

  def test_rake_task_recounts_the_model_and_reports_it
    library = Library.create!
    Book.insert_all([{ library_id: library.id }] * 2)

    assert_output("Recounted 1 Library records\n") { run_recount_task('MODEL' => 'Library') }
    assert_equal 2, library.reload.books_count
  end

  def test_rake_task_honours_counters_and_batch_size
    Ball.insert_all([{ box_id: @box.id, color: 'green' }])
    @box.update_columns(green_balls_count: 99)
    @box.non_green_balls_count = 42

    assert_output("Recounted 1 Box records\n") do
      run_recount_task('MODEL' => 'Box', 'COUNTERS' => 'green_balls_count, ', 'BATCH_SIZE' => '1')
    end
    assert_equal [1, 42], [@box.reload.green_balls_count, @box.non_green_balls_count]
  end

  def test_rake_task_aborts_without_a_model
    assert_output(nil, /MODEL is required/) do
      assert_raises(SystemExit) { run_recount_task({}) }
    end
  end

  def test_rake_task_aborts_for_an_unknown_model
    assert_output(nil, /NoSuchModel is not a model/) do
      assert_raises(SystemExit) { run_recount_task('MODEL' => 'NoSuchModel') }
    end
    assert_output(nil, /String is not a model/) do
      assert_raises(SystemExit) { run_recount_task('MODEL' => 'String') }
    end
  end

  def test_the_railtie_is_only_loaded_with_rails
    refute defined?(Rails::Railtie)
    refute defined?(CustomCounterCache::Railtie)
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

  # -- touch: on define_counter_cache --

  def test_column_counter_with_touch_writes_the_counter_and_the_timestamp_in_one_update
    shelf = Shelf.create!
    Shelf.where(id: shelf.id).update_all(updated_at: 1.day.ago)
    before = Shelf.find(shelf.id).updated_at
    Item.insert_all([{ shelf_id: shelf.id }, { shelf_id: shelf.id }]) # skips callbacks

    sql = capture_sql { shelf.update_items_count }

    assert_equal 1, sql.grep(/\AUPDATE "shelves"/).size
    persisted = Shelf.find(shelf.id)
    assert_equal 2, persisted.items_count
    assert_operator persisted.updated_at, :>, before
  end

  def test_touch_runs_on_every_recount_even_when_the_value_is_unchanged
    shelf = Shelf.create!
    Shelf.where(id: shelf.id).update_all(updated_at: 1.day.ago)
    before = Shelf.find(shelf.id).updated_at

    shelf.update_items_count # still 0

    assert_operator Shelf.find(shelf.id).updated_at, :>, before
  end

  def test_touch_runs_no_callbacks_and_leaves_unsaved_edits_alone
    shelf = Shelf.create!
    shelf.refreshed_at = 1.day.ago
    shelf.update_items_count
    assert_nil Shelf.find(shelf.id).refreshed_at
    assert_equal 1.day.ago.to_i, shelf.refreshed_at.to_i
  end

  def test_child_callbacks_touch_the_owner_through_the_counter
    shelf = Shelf.create!
    Shelf.where(id: shelf.id).update_all(updated_at: 1.day.ago)
    before = Shelf.find(shelf.id).updated_at

    Item.create!(shelf: shelf)

    persisted = Shelf.find(shelf.id)
    assert_equal 1, persisted.items_count
    assert_operator persisted.updated_at, :>, before
  end

  def test_column_counter_without_touch_leaves_the_timestamp_alone
    shelf = Shelf.create!
    Shelf.where(id: shelf.id).update_all(updated_at: 1.day.ago)
    before = Shelf.find(shelf.id).updated_at

    sql = capture_sql { shelf.update_plain_items_count }

    assert_equal 1, sql.grep(/\AUPDATE "shelves"/).size
    assert_equal before, Shelf.find(shelf.id).updated_at
  end

  def test_virtual_counter_with_a_named_touch_column_bumps_that_column
    shelf = Shelf.create!
    Shelf.where(id: shelf.id).update_all(refreshed_at: 1.day.ago)
    before = Shelf.find(shelf.id)

    shelf.update_notes_count

    persisted = Shelf.find(shelf.id)
    assert_equal 7, persisted.notes_count
    assert_operator persisted.refreshed_at, :>, before.refreshed_at
    assert_equal before.updated_at, persisted.updated_at
  end

  def test_virtual_counter_accepts_the_touch_column_as_a_string
    shelf = Shelf.create!
    Shelf.where(id: shelf.id).update_all(refreshed_at: 1.day.ago)
    before = Shelf.find(shelf.id).refreshed_at

    shelf.update_stamped_count

    assert_equal 8, Shelf.find(shelf.id).stamped_count
    assert_operator Shelf.find(shelf.id).refreshed_at, :>, before
  end

  def test_virtual_counter_with_touch_true_bumps_updated_at
    shelf = Shelf.create!
    Shelf.where(id: shelf.id).update_all(updated_at: 1.day.ago)
    before = Shelf.find(shelf.id).updated_at

    shelf.update_stamped_by_default_count

    assert_equal 9, Shelf.find(shelf.id).stamped_by_default_count
    assert_operator Shelf.find(shelf.id).updated_at, :>, before
  end

  def test_touch_options_are_stored_per_counter
    assert_equal true, Shelf.custom_counter_cache_options['items_count'][:touch]
    assert_equal :refreshed_at, Shelf.custom_counter_cache_options['notes_count'][:touch]
    assert_nil Shelf.custom_counter_cache_options['plain_items_count'][:touch]
    assert_nil Library.custom_counter_cache_options['books_count'][:touch]
  end

  # -- on_change: on update_counter_cache --
  # The point: keys are watched automatically, unlike an :if on a listed attribute.

  def test_on_change_skips_an_update_that_touches_only_unrelated_attributes
    project = Project.create!
    task = Task.create!(project: project, state: 'done')
    project.update_column(:done_count, 99) # stale on purpose

    task.update!(title: 'renamed')

    assert_equal 99, project.reload.done_count
  end

  def test_on_change_recounts_when_a_listed_attribute_changes
    project = Project.create!
    task = Task.create!(project: project)
    assert_equal 0, project.reload.done_count

    task.update!(state: 'done')

    assert_equal 1, project.reload.done_count
  end

  def test_on_change_recounts_both_owners_on_reassignment_without_a_state_change
    project = Project.create!
    other = Project.create!
    task = Task.create!(project: project, state: 'done')
    assert_equal 1, project.reload.done_count
    other.update_column(:done_count, 5) # stale on purpose

    task.update!(project: other) # state unchanged

    assert_equal 0, project.reload.done_count
    assert_equal 1, other.reload.done_count
  end

  def test_on_change_recounts_on_create_when_state_keeps_its_default
    project = Project.create!
    project.update_column(:done_count, 99)

    Task.create!(project: project)

    assert_equal 0, project.reload.done_count
  end

  def test_on_change_recounts_on_destroy
    project = Project.create!
    task = Task.create!(project: project, state: 'done')
    assert_equal 1, project.reload.done_count

    task.destroy!

    assert_equal 0, project.reload.done_count
  end

  def test_on_change_accepts_a_single_attribute_and_recounts_a_polymorphic_type_change
    project = Project.create!
    sprint = Sprint.create!
    ticket = Ticket.create!(target: project, state: 'done')
    assert_equal 1, project.reload.done_count
    project.update_column(:done_count, 99)
    ticket.update!(title: 'unrelated')
    assert_equal 99, project.reload.done_count

    ticket.update!(target: sprint) # type and id change, state does not

    assert_equal 0, project.reload.done_count
    assert_equal 1, sprint.reload.done_count
  end

  def test_on_change_recounts_a_polymorphic_id_change_within_the_same_type
    sprint = Sprint.create!
    other = Sprint.create!
    ticket = Ticket.create!(target: sprint, state: 'done')

    ticket.update!(target: other)

    assert_equal 0, sprint.reload.done_count
    assert_equal 1, other.reload.done_count
  end

  def test_on_change_combines_with_if_using_and_semantics
    project = Project.create!
    task = GatedTask.create!(project: project, title: 'no')
    project.update_column(:done_count, 99)

    task.update!(state: 'done') # listed attribute changed, :if false
    assert_equal 99, project.reload.done_count

    task.update!(title: 'go') # :if true, nothing listed changed
    assert_equal 99, project.reload.done_count

    task.update!(state: 'todo') # both hold
    assert_equal 0, project.reload.done_count
  end

  def test_discard_and_undiscard_recount_the_kept_pages
    notebook = Notebook.create!
    page = Page.create!(notebook: notebook)
    Page.create!(notebook: notebook)
    assert_equal 2, notebook.reload.pages_count

    page.discard
    assert_equal 1, notebook.reload.pages_count

    page.undiscard
    assert_equal 2, notebook.reload.pages_count
  end

  def test_discard_needs_discarded_at_in_on_change
    notebook = Notebook.create!
    page = StatePage.create!(notebook: notebook)
    assert_equal 1, notebook.reload.pages_count

    page.discard
    assert_equal 1, notebook.reload.pages_count # stale: discarded_at isn't watched

    page.update!(state: 'live')
    assert_equal 0, notebook.reload.pages_count
  end

  def test_discard_recounts_when_discarded_at_is_in_on_change
    notebook = Notebook.create!
    page = TrackedPage.create!(notebook: notebook)

    page.discard
    assert_equal 0, notebook.reload.pages_count

    page.undiscard
    assert_equal 1, notebook.reload.pages_count
  end

  def test_paranoid_destroy_and_restore_recount
    crate = Crate.create!
    parcel = Parcel.create!(crate: crate)
    Parcel.create!(crate: crate)
    assert_equal 2, crate.reload.parcels_count

    parcel.destroy
    assert_equal 1, crate.reload.parcels_count

    parcel.restore
    assert_equal 2, crate.reload.parcels_count
  end

  def test_paranoid_restore_is_skipped_by_except_restore
    crate = Crate.create!
    parcel = QuietParcel.create!(crate: crate)

    parcel.destroy
    assert_equal 0, crate.reload.parcels_count

    parcel.restore
    assert_equal 0, crate.reload.parcels_count
  end

  def test_paranoid_restore_is_skipped_by_only_create
    crate = Crate.create!
    parcel = CreatedParcel.create!(crate: crate)
    assert_equal 1, crate.reload.parcels_count

    parcel.destroy # not in :only, so the count stays
    parcel.restore
    assert_equal 1, crate.reload.parcels_count
  end

  def test_paranoid_restore_is_missed_when_acts_as_paranoid_comes_last
    crate = Crate.create!
    parcel = EarlyParcel.create!(crate: crate)

    parcel.destroy
    assert_equal 0, crate.reload.parcels_count

    parcel.restore
    assert_equal 0, crate.reload.parcels_count
  end

  def count_queries(&block)
    capture_sql(&block).size
  end

  def capture_sql(&block)
    sql = []
    collector = ->(*, payload) { sql << payload[:sql] }
    ActiveSupport::Notifications.subscribed(collector, 'sql.active_record', &block)
    sql
  end

end
