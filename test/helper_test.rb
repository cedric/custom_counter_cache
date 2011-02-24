require File.join(File.dirname(__FILE__), 'test_helper')

class HelperTest < ActionView::TestCase

  def setup
    controller.class_eval do
      stubs('before_filter').returns(true)
      spamtrap :create, :sarah_palin_walks_with_dinosaurs
    end
    # controller.stubs('before_filter')
  end

  def test_foobar
    debugger
    form = form_tag('') { |f| f.spamtrap }
    assert true
  end

end
