begin
  require 'active_job'
rescue LoadError
  raise LoadError, "custom_counter_cache: recount: :later needs Active Job; add 'activejob' to your Gemfile"
end

module CustomCounterCache
  # Enqueued by update_counter_cache ..., recount: :later. Takes plain values, not the record, so no GlobalID is needed.
  class RecountJob < ActiveJob::Base
    def perform(class_name, id, name)
      klass = class_name.safe_constantize
      owner = klass&.find_by(CustomCounterCache.key_conditions(klass.primary_key, id))
      Dispatcher.locked_recount(owner, name) if owner
    end
  end
end
