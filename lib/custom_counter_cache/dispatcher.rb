require 'active_support/isolated_execution_state'

module CustomCounterCache
  # Recounts each owner and counter once after the outermost batch ends (after commit, if inside a transaction).
  def self.batch(&block)
    Dispatcher.batch(&block)
  end

  # Drops recounts inside the block, e.g. for an import followed by recount_counter_caches.
  def self.skip(&block)
    Dispatcher.skip(&block)
  end

  # Single path from update_counter_cache's callbacks to an owner's recount.
  module Dispatcher
    # Always after commit: inside the saving transaction a recount can't see a concurrent save's
    # uncommitted child, and the later of the two overwrites the count with a stale one.
    def self.recount(owner, name, timing = :after_commit)
      return if state[:skip]
      # A cached counter is invalidated after commit, never recounted in place.
      timing = :invalidate if owner.class.custom_counter_cache_storage(name) == :cache
      # Keep the first instance seen, so loaded counters on it stay current.
      return state[:batch][[owner.class, owner.id, name]] ||= [owner, timing] if state[:batch]
      defer(owner, name, timing)
    end

    # Serializes recounts of one owner on its row, so each counts after any concurrent commit.
    # Locks by query rather than with_lock, which would reload the owner and drop its unsaved changes.
    def self.locked_recount(owner, name)
      klass = owner.class
      klass.transaction do
        # Owner deleted meanwhile: nothing left to recount.
        next unless klass.where(CustomCounterCache.key_conditions(klass.primary_key, owner.id)).lock.pick(*Array(klass.primary_key).first(1))
        owner.public_send("update_#{name}")
      end
    end

    def self.batch
      outermost = state[:batch].nil?
      state[:batch] ||= {}
      yield
    ensure
      # A recount reflects whatever is in the database, so flushing after an exception is still correct.
      if outermost
        pending = state.delete(:batch)
        pending.each { |(_, _, name), (owner, timing)| recount(owner, name, timing) }
      end
    end

    def self.skip
      skipping = state[:skip]
      state[:skip] = true
      yield
    ensure
      state[:skip] = skipping
    end

    # Once per owner and counter per transaction. A recount reads committed state, so running it late is still correct.
    def self.defer(owner, name, timing)
      key = [owner.class, owner.id, name, timing]
      deferred = state[:deferred] ||= {}
      return if deferred.key?(key)

      transaction = owner.class.current_transaction
      deferred[key] = true if transaction.open?
      # A rolled-back savepoint drops its after_commit, so forget the key and let a later save schedule it again.
      transaction.after_rollback { deferred.delete(key) }
      transaction.after_commit do
        deferred.delete(key)
        perform(owner, name, timing)
      rescue StandardError => error
        failed(error, owner, name)
      end
    end

    # The save has committed and the count can be rebuilt, so don't make the save look failed or
    # stop the other recounts queued for this commit. unexpected still raises in development and test.
    def self.failed(error, owner, name)
      context = { owner: owner.class.name, owner_id: owner.id, counter: name.to_s }
      owner.class.logger&.error("custom_counter_cache: recount of #{context[:owner]} #{context[:owner_id].inspect} " \
                                "#{context[:counter]} failed: #{error.class}: #{error.message}")
      ActiveSupport.error_reporter.unexpected(error, context: context, source: 'custom_counter_cache')
    end

    def self.perform(owner, name, timing)
      case timing
      when :later then RecountJob.perform_later(owner.class.name, owner.id, name.to_s)
      when :invalidate
        CustomCounterCache.cache_store.delete(CustomCounterCache.cache_key(owner, name))
        touch_column = owner.class.custom_counter_cache_touch_column(name)
        # A cascade destroy invalidates after the owner is gone; there's nothing left to touch.
        owner.update_column(touch_column, Time.current) if touch_column && !owner.destroyed?
      else locked_recount(owner, name)
      end
    end

    def self.state
      ActiveSupport::IsolatedExecutionState[:custom_counter_cache] ||= {}
    end
  end
end
