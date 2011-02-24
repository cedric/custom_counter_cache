module CustomCounterCache::Model
  
  def self.included(base)
    base.extend ActsAsMethods
  end
  
  module ActsAsMethods
    def custom_counter_cache(association_id, options = {}, &block)
      association_id = association_id.to_sym
      cache_column   = options.delete(:cache_column) || "#{table_name}_count".to_sym
      method_name    = "calculate_#{cache_column}".to_sym
      counter_scope  = "#{cache_column}_scope".to_sym
      named_scope counter_scope, options
      define_method method_name do
        # association = send(association_id)
        # association.update_attribute(cache_column, self.class.send(counter_scope).count)
      end
      after_save    method_name # maybe increment instead
      after_destroy method_name # maybe decrement instead
    end
  end
  
end

ActiveRecord::Base.send :include, CustomCounterCache::Model
