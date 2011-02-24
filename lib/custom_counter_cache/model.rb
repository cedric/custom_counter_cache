module CustomCounterCache::Model
  
  def self.included(base)
    base.extend ClassMethods
  end
  
  module ClassMethods
    def custom_counter_cache()
      
    end
  end
  
end

ActionController::Base.send :include, CustomCounterCache::Model
