require File.join(File.dirname(__FILE__), 'test_helper')

class CounterTest < MiniTest::Unit::TestCase

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
    @user.articles.each {|a| a.update_attributes(state: 'unpublished') }
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
    @article.comments.each { |c| c.update_attributes(state: "unpublished") }
    assert_equal 0, @article.comments_count
  end

  def test_increment_and_decrement_counter_with_conditions_on_model_with_counter_column
    @ball = @box.balls.create(color: 'red')
    assert_equal 0, @box.reload.green_balls_count
    @ball.update_attribute :color, 'green'
    assert_equal 1, @box.reload.green_balls_count
    3.times { |i| @box.balls.create(color: 'green') }
    assert_equal 4, @box.reload.green_balls_count
    @box.balls.each {|b| b.update_attributes(color: 'red') }
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

end
