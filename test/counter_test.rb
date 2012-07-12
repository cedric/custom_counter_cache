require File.join(File.dirname(__FILE__), 'test_helper')

class CounterTest < Test::Unit::TestCase

  def setup
    @user = User.create
  end
  
  def test_default_counter_value
    assert_equal 0, @user.published_count
  end
  
  def test_create_and_destroy_counter
    @user.articles.create(:state => 'published')
    assert_equal 1, Counter.count
    @user.articles.delete_all
    assert_equal 0, Counter.count
  end
  
  def test_increment_and_decrement_counter_with_conditions
    @article = @user.articles.create(:state => 'unpublished')
    assert_equal 0, @user.published_count
    @article.update_attribute :state, 'published'
    assert_equal 1, @user.published_count
    3.times { |i| @user.articles.create(:state => 'published') }
    assert_equal 4, @user.published_count
    @user.articles.update_all "state = 'unpublished'"
    assert_equal 0, @user.published_count
  end
  
end
