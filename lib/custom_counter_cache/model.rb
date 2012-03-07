module CustomCounterCache::Model
  
  def self.included(base)
    base.extend ActsAsMethods
  end
  
  module ActsAsMethods
    
    def define_counter_cache(cache_column, &block)
      # counter accessors
      unless column_names.include?(cache_column) # Object.const_defined?(:Counter)
        has_many :counters, :as => :countable, :dependent => :destroy
        define_method "#{cache_column}" do
          counters.find(:first, :conditions => { :key => cache_column.to_s }).value rescue 0
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
        update_attribute cache_column, block.call(self)
      end
    end
    
    def update_counter_cache(association_id, cache_column, options = {}) 
      association_id = association_id.to_sym
      cache_column   = cache_column.to_sym
      method_name    = "callback_#{cache_column}".to_sym
      reflection     = reflect_on_association(association_id)
      foreign_key    = reflection.options[:foreign_key] || reflection.association_foreign_key
      # define callback
      define_method method_name do
        # update old association
        if send("#{foreign_key}_changed?")
          old_assoc_id = send("#{foreign_key}_was")
          if ( old_assoc_id && old_assoc = reflection.klass.find(old_assoc_id))
            old_assoc.send("update_#{cache_column}")
          end
        end
        # update new association
        new_assoc_id = send(foreign_key)
        if ( new_assoc_id && new_assoc = reflection.klass.find(new_assoc_id) )
          new_assoc.send("update_#{cache_column}")
        end
      end
      # set callbacks
      after_create  method_name
      after_update  method_name, :if => options[:if]
      after_destroy method_name, :if => options[:if]
    end
    
  end
  
end

ActiveRecord::Base.send :include, CustomCounterCache::Model
