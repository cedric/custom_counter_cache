require File.join(File.dirname(__FILE__), 'test_helper')

# Regression test for a destroy loop that occurs when a consumer's Counter
# model mistakenly adds `dependent: :destroy` to its `belongs_to :countable`
# (see test_helper.rb's Counter class and the README "Note" on this).
#
# On a belongs_to, dependent: :destroy means "when I am destroyed, also
# destroy the record I belong to" -- the opposite of what a counter cache
# needs. Combined with the has_many :counters this gem defines on the
# countable side, that mistake used to create a destroy loop: destroying a
# countable record cascaded into destroying its Counters, and each Counter's
# (wrongly configured) belongs_to cascaded back into destroying the same
# countable record again, re-running its full before_destroy chain against
# already-destroyed associations.
#
# has_many :counters now uses dependent: :delete_all, which deletes Counter
# rows with a single SQL statement and never instantiates them or runs their
# callbacks -- so a misconfigured Counter#belongs_to (like the one in this
# test suite's fixtures, deliberately) can no longer cause the loop.
class DestroyLoopTest < Minitest::Test

  def setup
    @user = User.create!
    @user.articles.create!(state: 'published') # gives the user a real Counter row
    @note = UserNote.create!(user: @user)
  end

  def test_destroying_a_countable_record_with_a_dependent_association_does_not_recurse
    @user.destroy!

    assert @user.destroyed?
    refute UserNote.exists?(@note.id)
  end

  def test_counters_are_removed_via_a_single_delete_without_instantiating_them
    assert_equal 1, Counter.where(countable: @user).count

    # dependent: :delete_all must never call Counter#destroy -- prove it by
    # making Counter#destroy raise, then destroying the user anyway.
    Counter.define_method(:destroy) { raise 'Counter#destroy should not be called' }

    @user.destroy!

    assert_equal 0, Counter.where(countable_type: 'User', countable_id: @user.id).count
  ensure
    Counter.send(:remove_method, :destroy) if Counter.instance_methods(false).include?(:destroy)
  end

end
