require 'active_support/concern'

module CustomCounterCache::Model
  extend ActiveSupport::Concern

  module ClassMethods
    def define_counter_cache(cache_column, &block)
      return unless table_exists?

      # counter accessors
      unless column_names.include?(cache_column.to_s)
        # Declare once per class: redeclaring for each virtual counter triggers method-redefinition warnings.
        has_many :counters, as: :countable, dependent: :delete_all unless reflect_on_association(:counters)
        define_method "#{cache_column}" do
          # Once loaded (e.g. includes(:counters)), a missing row means 0, not a query.
          if counters.loaded?
            counters.detect { |c| c.key == cache_column.to_s }.try(:value).to_i
          else
            counters.find_by(key: cache_column.to_s).try(:value).to_i
          end
        end
        define_method "#{cache_column}=" do |count|
          # Update the loaded Counter itself, or the reader keeps returning its stale value.
          counter = counters.loaded? ? counters.detect { |c| c.key == cache_column.to_s } : counters.find_by(key: cache_column.to_s)
          if counter
            counter.update_attribute :value, count.to_i
          else
            begin
              # Savepoint: on PostgreSQL a failed INSERT would otherwise abort the caller's whole transaction.
              self.class.transaction(requires_new: true) { counters.create key: cache_column.to_s, value: count.to_i }
            rescue ActiveRecord::RecordNotUnique
              # Lost a create race. A locking read sees the winner's row even under REPEATABLE READ (MySQL).
              counters.reset
              counters.lock.find_by!(key: cache_column.to_s).update_attribute :value, count.to_i
            end
          end
        end
      end

      # counter update method
      define_method "update_#{cache_column}" do
        if self.class.column_names.include?(cache_column.to_s)
          update_attribute cache_column, block.call(self)
        else
          send "#{cache_column}=", block.call(self)
        end
      end

    rescue StandardError => e
      # Support Heroku's database-less assets:precompile pre-deploy step:
      raise e unless ENV['DATABASE_URL'].to_s.include?('//user:pass@127.0.0.1/')
    end

    def update_counter_cache(association, cache_column, options = {})
      return unless table_exists?

      association  = association.to_sym
      cache_column = cache_column.to_sym
      method_name  = "callback_#{association}_#{cache_column}".to_sym
      reflection   = reflect_on_association(association)
      raise ArgumentError, "#{self} must declare belongs_to :#{association} before update_counter_cache" unless reflection
      foreign_key  = reflection.foreign_key

      # define callback
      define_method method_name do
        # update old association
        if reflection.polymorphic?
          type_key = reflection.foreign_type
          id_key   = foreign_key
          if saved_change_to_attribute?(id_key) || saved_change_to_attribute?(type_key)
            old_type = saved_change_to_attribute?(type_key) ? attribute_before_last_save(type_key) : self[type_key]
            old_id   = saved_change_to_attribute?(id_key)   ? attribute_before_last_save(id_key)   : self[id_key]
            # safe_: the stored type may name a class that has since been renamed or removed.
            old_klass = old_type&.safe_constantize
            if ( old_klass && old_id && record = old_klass.find_by(reflection.association_primary_key(old_klass) => old_id) )
              record.send("update_#{cache_column}")
            end
          end
        else
          if saved_change_to_attribute?(foreign_key)
            old_id = attribute_before_last_save(foreign_key)
            if ( old_id && record = reflection.klass.find_by(reflection.association_primary_key => old_id) )
              record.send("update_#{cache_column}")
            end
          end
        end
        # update new association
        if ( record = send(association) )
          record.send("update_#{cache_column}")
        end
      end

      skip_callback = Proc.new { |callback, opts|
        (opts[:except].present? && opts[:except].include?(callback)) ||
        (opts[:only].present?   && !opts[:only].include?(callback))
      }

      # set callbacks
      callback_opts = options.slice(:if, :unless, :prepend)
      after_create  method_name, **callback_opts unless skip_callback.call(:create, options)
      after_update  method_name, **callback_opts unless skip_callback.call(:update, options)
      after_destroy method_name, **callback_opts unless skip_callback.call(:destroy, options)

    rescue StandardError => e
      # Support Heroku's database-less assets:precompile pre-deploy step:
      raise e unless ENV['DATABASE_URL'].to_s.include?('//user:pass@127.0.0.1/')
    end
  end
end
