require File.join(File.dirname(__FILE__), 'test_helper')

class CounterTest < Test::Unit::TestCase

  def setup
    @user = User.create
  end

  def test_default_counter_value
    assert_equal 0, @user.published_count
  end

  def test_create_and_destroy_counter
    @user.articles.create(state: 'published')
    assert_equal 1, Counter.count
    @user.destroy
    assert_equal 0, Counter.count
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

end
