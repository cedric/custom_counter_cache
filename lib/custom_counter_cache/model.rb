module CustomCounterCache::Model
  
  def self.included(base)
    base.extend ActsAsMethods
  end
  
  module ActsAsMethods
    def custom_counter_cache(association_id, options = {}, &block)
      association_id = association_id.to_sym
      cache_column   = options.delete(:cache_column) || "#{table_name}_count".to_sym
      method_name    = "calculate_#{cache_column}".to_sym
      define_method method_name do
        send(association_id).update_attribute cache_column, block.call(self)
        # find association foreign_key, see if it's been changed
        # if it has, also update counter cache on old association
      end
      after_save    method_name
      after_destroy method_name
    end
  end
  
end

ActiveRecord::Base.send :include, CustomCounterCache::Model
