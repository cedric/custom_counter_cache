module CustomCounterCache::Model

  def self.included(base)
    base.extend ActsAsMethods
  end

  module ActsAsMethods

    def define_counter_cache(cache_column, &block)
      return unless table_exists?
      # counter accessors
      unless column_names.include?(cache_column) # Object.const_defined?(:Counter)
        has_many :counters, :as => :countable, :dependent => :destroy
        define_method "#{cache_column}" do
          # Check if the counter is already loaded (e.g. eager-loaded)
          if counters.loaded? && counter = counters.detect{|c| c.key == cache_column.to_s }
            counter.value
          else
            counters.find(:first, :conditions => { :key => cache_column.to_s }).value rescue 0
          end
        end
        define_method "#{cache_column}=" do |count|
          if ( counter = counters.find(:first, :conditions => { :key => cache_column.to_s }) )
            counter.update_attribute :value, count.to_i
          else
            counters.create :key => cache_column.to_s, :value => count.to_i
          end
        end
      end
      # counter update method
      define_method "update_#{cache_column}" do
        send "#{cache_column}=", block.call(self)
      end
    end

    def update_counter_cache(association, cache_column, options = {})
      association  = association.to_sym
      cache_column = cache_column.to_sym
      method_name  = "callback_#{cache_column}".to_sym
      reflection   = reflect_on_association(association)
      foreign_key  = reflection.options[:foreign_key] || reflection.association_foreign_key
      # define callback
      define_method method_name do
        # update old association
        if send("#{foreign_key}_changed?") || ( !respond_to?("#{association}_type") || send("#{association}_type_changed?") )
          old_id = send("#{foreign_key}_was")
          klass = if reflection.options[:polymorphic]
            ( send("#{association}_type_was") || send("#{association}_type") ).constantize
          else
            reflection.klass
          end
          if ( old_id && record = klass.find(old_id) )
            record.send("update_#{cache_column}")
          end
        end
        # update new association
        if ( record = send(association) )
          record.send("update_#{cache_column}")
        end
      end
      # set callbacks
      after_create  method_name, options
      after_update  method_name, options
      after_destroy method_name, options
    end

  end

end

ActiveRecord::Base.send :include, CustomCounterCache::Model
