require File.join(File.dirname(__FILE__), 'test_helper')

class CounterTest < Test::Unit::TestCase

  def setup
    @user = User.create
  end
  
  def test_default_counter_value
    assert @user.published_count, 0
  end
  
  def test_create_and_destroy_counter
    @user.articles.create(:state => 'published')
    assert Counter.count, 1
    @user.articles.delete_all
    assert Counter.count, 0
  end
  
  def test_increment_and_decrement_counter_with_conditions
    @article = @user.articles.create(:state => 'unpublished')
    assert @user.published_count, 0
    @article.update_attribute :state, 'published'
    assert @user.published_count, 1
    3.times { |i| @user.articles.create(:state => 'published') }
    assert @user.published_count, 4
    @user.articles.update_all "state = 'unpublished'"
    assert @user.published_count, 0
  end
  
end
