module CustomCounterCache::Model
  
  def self.included(base)
    base.extend ActsAsMethods
  end
  
  module ActsAsMethods
    def custom_counter_cache(cache_column, options = {})
      
    end
  end
  
end

ActiveRecord::Base.send :include, CustomCounterCache::Model
