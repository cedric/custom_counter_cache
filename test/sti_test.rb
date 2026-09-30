require File.join(File.dirname(__FILE__), 'test_helper')

class StiTest < Minitest::Test
  def setup
    ActiveRecord::Base.lease_connection.begin_transaction(joinable: false)
    @store = CustomCounterCache.cache_store = ActiveSupport::Cache::MemoryStore.new
  end

  def teardown
    ActiveRecord::Base.lease_connection.rollback_transaction
    CustomCounterCache.cache_store = nil
  end

  def test_counters_rows_of_a_subclass_owner_use_the_base_class_as_countable_type
    member = Member.create!
    PersonNote.create!(person: member)
    member.update_badges_count

    assert_equal %w[Person], Counter.where(countable_id: member.id).distinct.pluck(:countable_type)
    assert_equal %w[badges_count notes_count], Counter.where(countable_id: member.id).order(:key).pluck(:key)
  end

  def test_the_value_reads_the_same_through_the_subclass_and_the_base_class
    member = Member.create!
    2.times { PersonNote.create!(person: member) }

    assert_equal 2, member.reload.notes_count
    assert_equal 2, Person.find(member.id).notes_count
    assert_equal 2, Member.find(member.id).notes_count
  end

  def test_a_counter_defined_only_on_a_subclass_is_absent_from_the_parent
    refute_respond_to Person.new, :badges_count
    refute_includes Person.custom_counter_cache_names, 'badges_count'
    assert_respond_to Member.new, :badges_count
    assert_includes Member.custom_counter_cache_names, 'badges_count'
  end

  def test_a_subclass_inherits_its_parents_counters
    assert_includes Member.custom_counter_cache_names, 'notes_count'
    assert_respond_to Member.new, :notes_count
    assert_equal :cache, Member.custom_counter_cache_options.dig('cached_notes_count', :store)
    assert_equal :counters, Member.custom_counter_cache_storage(:notes_count)
  end

  def test_a_child_subclass_triggers_the_callback_declared_on_its_base_class
    member = Member.create!
    note = PersonSpecialNote.create!(person: member)
    assert_equal 1, member.reload.notes_count

    note.destroy!
    assert_equal 0, member.reload.notes_count
  end

  def test_a_child_subclass_moving_between_owners_recounts_both
    member = Member.create!
    person = Person.create!
    note = PersonSpecialNote.create!(person: member)
    note.update!(person: person)

    assert_equal 0, member.reload.notes_count
    assert_equal 1, person.reload.notes_count
  end

  def test_the_cache_key_of_a_subclass_owner_uses_the_base_class_name
    member = Member.create!
    key = "custom_counter_cache/v1/Person/#{member.id}/cached_notes_count"
    assert_equal key, CustomCounterCache.cache_key(member, :cached_notes_count)

    assert_equal 0, member.cached_notes_count
    assert @store.exist?(key)
    PersonNote.create!(person: member)
    refute @store.exist?(key)
    assert_equal 1, Person.find(member.id).cached_notes_count
  end
end
