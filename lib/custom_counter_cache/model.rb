require 'active_support/concern'

module CustomCounterCache::Model
  extend ActiveSupport::Concern

  included do
    class_attribute :custom_counter_cache_names, instance_accessor: false, default: []
    # Per counter name; a new merged hash is assigned so subclasses never mutate their parent's.
    class_attribute :custom_counter_cache_options, instance_accessor: false, default: {}
  end

  module ClassMethods
    # Column or counters row is decided on each call, not here, so defining never queries the database.
    def define_counter_cache(cache_column, touch: nil, store: nil, expires_in: nil, &block)
      raise ArgumentError, "store: must be :cache or omitted" unless store.nil? || store == :cache
      name = cache_column.to_s
      define_counters_association
      define_cache_cleanup if store == :cache
      self.custom_counter_cache_names += [name]
      self.custom_counter_cache_options = custom_counter_cache_options.merge(name => { touch: touch, store: store, expires_in: expires_in })

      custom_counter_cache_methods.module_eval do
        define_method(name) do
          case self.class.custom_counter_cache_storage(name)
          when :column then super()
          when :cache
            CustomCounterCache.cache_store.fetch(CustomCounterCache.cache_key(self, name), expires_in: expires_in) { block.call(self) }
          else
            # Once loaded (e.g. includes(:counters)), a missing row means 0, not a query.
            counter = counters.loaded? ? counters.detect { |c| c.key == name } : counters.find_by(key: name)
            counter.try(:value).to_i
          end
        end

        define_method("#{name}=") do |count|
          case self.class.custom_counter_cache_storage(name)
          when :column then return super(count)
          when :cache then return CustomCounterCache.cache_store.write(CustomCounterCache.cache_key(self, name), count, expires_in: expires_in)
          end
          count = CustomCounterCache::Model.whole_number!(self, name, count)
          # Update the loaded Counter itself, or the reader keeps returning its stale value.
          counter = counters.loaded? ? counters.detect { |c| c.key == name } : counters.find_by(key: name)
          if counter
            counter.update_attribute :value, count
          else
            begin
              # Savepoint: on PostgreSQL a failed INSERT would otherwise abort the caller's whole transaction.
              self.class.transaction(requires_new: true) { counters.create key: name, value: count }
            rescue ActiveRecord::RecordNotUnique
              # Lost a create race. A locking read sees the winner's row even under REPEATABLE READ (MySQL).
              counters.reset
              counters.lock.find_by!(key: name).update_attribute :value, count
            end
          end
        end

        define_method("update_#{name}") do
          touch_column = self.class.custom_counter_cache_touch_column(name)
          value = block.call(self)
          if self.class.custom_counter_cache_storage(name) == :column
            # One statement, and no callbacks: update_columns, not touch.
            touch_column ? update_columns(name => value, touch_column => Time.current) : update_column(name, value)
          else
            send "#{name}=", value
            update_column touch_column, Time.current if touch_column
          end
        end
      end
    end

    # :cache when declared; otherwise a column if one exists, else a row in the counters table.
    def custom_counter_cache_storage(name) # :nodoc:
      return :cache if custom_counter_cache_options.dig(name.to_s, :store) == :cache
      return :column if column_names.include?(name.to_s)
      # The counters table's single countable_id can't hold a composite key.
      if composite_primary_key?
        raise ArgumentError, "#{self} has a composite primary key, so counter #{name} needs a column or store: :cache"
      end
      :counters
    end

    def custom_counter_cache_touch_column(name) # :nodoc:
      touch = custom_counter_cache_options.dig(name.to_s, :touch)
      touch == true ? 'updated_at' : (touch.to_s if touch)
    end

    # Repairs drift no callback can see (update_all, delete_all, imports). Returns the records processed.
    def recount_counter_caches(*names, scope: all, batch_size: 1000)
      names = names.empty? ? custom_counter_cache_names : names.map(&:to_s)
      unknown = names - custom_counter_cache_names
      raise ArgumentError, "#{self} has no counter cache named #{unknown.join(', ')}" if unknown.any?

      # Calls update_<name> directly, so CustomCounterCache.skip and .batch don't affect it.
      # Preload :counters, which the virtual counter writer uses once loaded, to avoid a query per record.
      scope = scope.includes(:counters) if names.any? { |name| custom_counter_cache_storage(name) == :counters }
      processed = 0
      scope.find_each(batch_size: batch_size) do |record|
        names.each { |name| record.public_send("update_#{name}") }
        processed += 1
      end
      processed
    end

    # association may be a belongs_to path, e.g. [:article, :user], to recount a grandparent.
    def update_counter_cache(association, cache_column, options = {})
      path         = Array(association).map(&:to_sym)
      association  = path.first
      cache_column = cache_column.to_sym
      method_name  = "callback_#{path.join('_')}_#{cache_column}".to_sym
      reflection   = reflect_on_association(association)
      raise ArgumentError, "#{self} must declare belongs_to :#{association} before update_counter_cache" unless reflection&.belongs_to?
      foreign_key  = reflection.foreign_key
      rest         = path.drop(1)
      path_checked = false
      timing       = CustomCounterCache.check_timing!(options.fetch(:recount, :after_commit))

      define_method method_name do
        # Later steps live on classes that may not be loaded at declaration time, so check them on first use.
        path_checked ||= CustomCounterCache::Model.check_path!(reflection, rest)
        owners = [CustomCounterCache::Model.previous_owner(self, reflection), public_send(association)]
        owners = owners.map { |record| CustomCounterCache::Model.follow_path(record, rest) }
        # Moving between two records under the same grandparent must recount it once, not twice.
        owners.compact.uniq { |owner| [owner.class, owner.id] }.each do |owner|
          CustomCounterCache::Dispatcher.recount(owner, cache_column, timing)
        end
      end

      skip_callback = Proc.new { |callback, opts|
        (opts[:except].present? && opts[:except].include?(callback)) ||
        (opts[:only].present?   && !opts[:only].include?(callback))
      }

      # set callbacks
      callback_opts = options.slice(:if, :unless, :prepend)
      update_opts   = callback_opts
      if options[:on_change]
        # The keys are always watched so a reassignment recounts the old owner too.
        watched = Array(options[:on_change]).map(&:to_s) + Array(foreign_key).map(&:to_s)
        watched << reflection.foreign_type.to_s if reflection.polymorphic?
        changed = ->(record) { watched.any? { |attribute| record.saved_change_to_attribute?(attribute) } }
        update_opts = callback_opts.merge(if: Array(options[:if]) + [changed])
      end
      # Create isn't gated by :on_change: column defaults aren't saved changes, so new records would be missed.
      after_create  method_name, **callback_opts unless skip_callback.call(:create, options)
      after_update  method_name, **update_opts unless skip_callback.call(:update, options)
      # Not :if/:unless: they test saved changes, which a destroy lacks. An extra recount is never wrong.
      after_destroy method_name, **options.slice(:prepend) unless skip_callback.call(:destroy, options)
      # Paranoia's restore skips update callbacks; it defines :restore only once acts_as_paranoid has run.
      after_restore method_name, **options.slice(:prepend) if respond_to?(:after_restore) && !skip_callback.call(:restore, options)
    end

    private

    # Included after Active Record's generated attribute methods, so super reaches a real column's accessor.
    def custom_counter_cache_methods
      @custom_counter_cache_methods ||= Module.new.tap { |mod| include mod }
    end

    def define_cache_cleanup
      return if @custom_counter_cache_cleanup
      @custom_counter_cache_cleanup = true
      after_destroy_commit do
        self.class.custom_counter_cache_names.each do |name|
          next unless self.class.custom_counter_cache_storage(name) == :cache
          CustomCounterCache.cache_store.delete(CustomCounterCache.cache_key(self, name))
        end
      end
    end

    def define_counters_association
      return if reflect_on_association(:counters)
      has_many :counters, as: :countable, class_name: CustomCounterCache.counter_class_name
      # Not dependent: :delete_all, which would query the counters table even when every counter is a column.
      before_destroy do
        in_table = self.class.custom_counter_cache_names.any? { |name| self.class.custom_counter_cache_storage(name) == :counters }
        counters.delete_all(:delete_all) if in_table
      end
    end
  end

  # The counters table holds integers. Converting 2.5 to 2 would store a wrong count without a word, so refuse.
  def self.whole_number!(record, name, value)
    number =
      case value
      when nil then 0
      when Integer then value
      when String then Integer(value, 10, exception: false)
      when Numeric then value.to_i if (!value.respond_to?(:finite?) || value.finite?) && value == value.to_i
      end
    return number if number
    raise ArgumentError, "#{record.class}##{name} is stored in the counters table, which holds whole numbers; got " \
      "#{value.inspect}. Give it a column of a suitable type, or use store: :cache"
  end

  # Checks each step up to the first polymorphic one, past which the class varies per record.
  def self.check_path!(reflection, steps)
    steps.each do |step|
      return true if reflection.polymorphic?
      owner_class = reflection.klass
      reflection = owner_class.reflect_on_association(step)
      raise ArgumentError, "#{owner_class} must declare belongs_to :#{step} for update_counter_cache" unless reflection&.belongs_to?
    end
    true
  end

  def self.follow_path(record, steps)
    steps.reduce(record) do |current, step|
      break unless current
      reflection = current.class.reflect_on_association(step)
      # Only reachable past a polymorphic step: this type has no such parent, so there's nothing to recount.
      break unless reflection
      raise ArgumentError, "#{current.class} must declare belongs_to :#{step} for update_counter_cache" unless reflection.belongs_to?
      current.public_send(step)
    end
  end

  # The owner record belonged to before its last save moved it, or nil if it didn't move.
  # Keys may be composite: only some of their columns may have changed.
  def self.previous_owner(record, reflection)
    keys = Array(reflection.foreign_key).map(&:to_s)
    keys += [reflection.foreign_type] if reflection.polymorphic?
    return unless keys.any? { |key| record.saved_change_to_attribute?(key) }

    old_values = keys.map { |key| record.saved_change_to_attribute?(key) ? record.attribute_before_last_save(key) : record[key] }
    return if old_values.any?(&:nil?)

    if reflection.polymorphic?
      # safe_: the stored type may name a class that has since been renamed or removed.
      old_klass = old_values.pop.safe_constantize
      old_klass&.find_by(CustomCounterCache.key_conditions(reflection.association_primary_key(old_klass), old_values))
    else
      reflection.klass.find_by(CustomCounterCache.key_conditions(reflection.association_primary_key, old_values))
    end
  end
end
