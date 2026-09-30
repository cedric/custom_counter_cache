class CustomCounterCache::Railtie < Rails::Railtie
  rake_tasks { load File.expand_path('../tasks/custom_counter_cache.rake', __dir__) }
end
