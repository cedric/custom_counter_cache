require 'active_support/concern'

module CustomCounterCache::Model
  extend ActiveSupport::Concern

  module ClassMethods
    def define_counter_cache(cache_column, &block)
      return unless table_exists?

      # counter accessors
      unless column_names.include?(cache_column.to_s)
        # Only declare the :counters association once per class -- a model
        # can have multiple virtual (non-column) counter caches, and
        # redeclaring has_many :counters for each one just redefines the
        # same reader/writer methods again, which Ruby warns about under -w.
        has_many :counters, as: :countable, dependent: :delete_all unless reflect_on_association(:counters)
        define_method "#{cache_column}" do
          # check if the counter is loaded
          if counters.loaded? && counter = counters.detect{|c| c.key == cache_column.to_s }
            counter.value
          else
            counters.find_by(key: cache_column.to_s).try(:value).to_i
          end
        end
        define_method "#{cache_column}=" do |count|
          if ( counter = counters.find_by(key: cache_column.to_s) )
            counter.update_attribute :value, count.to_i
          else
            counters.create key: cache_column.to_s, value: count.to_i
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
      foreign_key  = reflection.try(:foreign_key) || reflection.association_foreign_key

      # define callback
      define_method method_name do
        # update old association
        if reflection.options[:polymorphic]
          type_key = "#{association}_type"
          id_key   = "#{association}_id"
          if send("saved_change_to_#{id_key}?") || send("saved_change_to_#{type_key}?")
            old_type = send("saved_change_to_#{type_key}?") ? send("#{type_key}_before_last_save") : send(type_key)
            old_id   = send("saved_change_to_#{id_key}?")   ? send("#{id_key}_before_last_save")   : send(id_key)
            if ( old_type && old_id && record = old_type.constantize.find_by(id: old_id) )
              record.send("update_#{cache_column}")
            end
          end
        else
          if send("saved_change_to_#{foreign_key}?")
            old_id = send("#{foreign_key}_before_last_save")
            if ( old_id && record = reflection.klass.find_by(id: old_id) )
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
