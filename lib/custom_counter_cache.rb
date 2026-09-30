require 'active_support'
require 'active_support/core_ext/module/attribute_accessors'

module CustomCounterCache
  # Model holding counters that have no column. Read when a model defines its first counter, so set it before models load.
  mattr_accessor :counter_class_name, default: 'Counter'
  mattr_writer :cache_store, default: nil

  # Where store: :cache counters live: the configured store, else Rails.cache.
  def self.cache_store
    store = @@cache_store || (::Rails.cache if defined?(::Rails) && ::Rails.respond_to?(:cache))
    store or raise ArgumentError, 'store: :cache needs a cache: set CustomCounterCache.cache_store (Rails.cache is used when available)'
  end

  def self.cache_key(owner, name)
    "custom_counter_cache/v1/#{owner.class.polymorphic_name}/#{Array(owner.id).join('-')}/#{name}"
  end

  # Conditions matching columns to values; each may be a single key or a composite one.
  def self.key_conditions(columns, values) # :nodoc:
    Array(columns).map(&:to_s).zip(Array(values)).to_h
  end

  # Callback recounts always run after commit; :later moves them into a job.
  TIMINGS = %i[after_commit later].freeze

  def self.check_timing!(timing) # :nodoc:
    raise ArgumentError, "recount: must be one of #{TIMINGS.join(', ')}" unless TIMINGS.include?(timing)
    # Fail at class load, not on the first save, if Active Job is missing.
    require 'custom_counter_cache/recount_job' if timing == :later
    timing
  end
end

require 'custom_counter_cache/dispatcher'
require 'custom_counter_cache/model'
require 'custom_counter_cache/railtie' if defined?(Rails::Railtie)
