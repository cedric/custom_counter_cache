require File.join(File.dirname(__FILE__), 'test_helper')

class ControllerTest < Test::Unit::TestCase

  def setup
    @comment = Comment.new
  end

  def teardown
  end

  def test_foobar
    assert true
    assert_equal "hello", "hello"
  end

end
