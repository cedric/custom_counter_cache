require File.join(File.dirname(__FILE__), 'test_helper')

class CounterTest < Test::Unit::TestCase

  def setup
    @user = User.create
    @box = Box.create
  end

  def test_default_counter_value
    assert_equal 0, @user.published_count
    assert_equal 0, @box.green_balls_count
  end

  def test_create_and_destroy_counter
    @user.articles.create(:state => 'published')
    assert_equal 1, Counter.count
    @user.destroy
    assert_equal 0, Counter.count
  end

  def test_increment_and_decrement_counter_with_conditions
    @article = @user.articles.create(:state => 'unpublished')
    assert_equal 0, @user.published_count
    @article.update_attribute :state, 'published'
    assert_equal 1, @user.published_count
    3.times { |i| @user.articles.create(:state => 'published') }
    assert_equal 4, @user.published_count
    @user.articles.each {|a| a.update_attributes(:state => 'unpublished') }
    assert_equal 0, @user.published_count
  end

  def test_increment_and_decrement_counter_with_conditions_on_model_with_counter_column
    @ball = @box.balls.create(:color => 'red')
    assert_equal 0, @box.reload.green_balls_count
    @ball.update_attribute :color, 'green'
    assert_equal 1, @box.reload.green_balls_count
    3.times { |i| @box.balls.create(color: 'green') }
    assert_equal 4, @box.reload.green_balls_count
    @box.balls.each {|b| b.update_attributes(:color => 'red') }
    assert_equal 0, @box.reload.green_balls_count
  end

  # Test that an eager loaded
  def test_eager_loading_with_no_counter
    @article = @user.articles.create(:state => 'unpublished')
    user = User.includes(:counters).first
    assert_equal 0, user.published_count

  end

  def test_eager_loading_with_counter
    @article = @user.articles.create(:state => 'published')
    @user = User.includes(:counters).find(@user.id)
    assert_equal 1, @user.published_count
  end

end
