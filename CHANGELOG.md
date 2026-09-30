# Changelog

## 0.4.0

### Breaking

- Requires Ruby >= 3.3 and Rails (Active Record) >= 8.0.
- `:if`/`:unless` on `update_counter_cache` now only gate the create and update callbacks; a
  destroy always recounts. Use `except: [:destroy]` to skip it.
- Column counters are written with `update_column`: recounts no longer save other unsaved
  changes on the owner, touch its `updated_at`, run its callbacks or bump `lock_version`.
- `update_counter_cache` raises `ArgumentError` for associations other than `belongs_to`
  (they have never worked).
- Every model that calls `define_counter_cache` gets the `counters` association, not only models
  with a counter that has no column.
- Defining counters on a table that doesn't exist no longer silently defines nothing.
- Recounts triggered by `update_counter_cache` callbacks run after the saving transaction commits
  instead of inside it: once per owner and counter per transaction, not at all on rollback, and
  under a short lock on the owner's row. Counting inside the transaction couldn't see a concurrent
  save's uncommitted child, so concurrent saves to the same owner left a stale count (on
  PostgreSQL, 399 of 400 concurrent test runs). The counter now changes at commit rather than at
  save; call `update_<name>` directly to recount immediately inside a transaction. Rails'
  transactional tests commit each save within the test transaction, so tests see the recount.
- A counter stored in the counters table raises `ArgumentError` for a value that isn't a whole
  number (e.g. `2.5`, `'many'`, infinity) instead of silently truncating it with `to_i`. `nil`
  still means 0, and whole values like `4.0` or `BigDecimal('4')` are still accepted. Use a column
  of a suitable type or `store: :cache` for fractional values.

### Changed

- Whether a counter uses a column or the counters table is decided when it's read or written, so
  loading models never queries the database, and a column added after the model has loaded is
  picked up. The Heroku `DATABASE_URL` workaround is gone.
- Counter rows are deleted on destroy only when the model has a counter without a column, so
  column-only models never touch the counters table.
- A recount that raises after commit is passed to `ActiveSupport.error_reporter.unexpected` (with
  the owner and counter as context) and logged, instead of propagating: the save has already
  committed, and one failure no longer skips the other recounts queued for that commit. In
  development and test Rails' debug mode still raises it. Direct `update_<name>` calls,
  `recount_counter_caches` and `CustomCounterCache::RecountJob` still raise.
- Paranoia's `restore` now recounts the owner for callbacks declared after `acts_as_paranoid`; it
  didn't before. Add `except: [:restore]` to keep the old behavior.

### Added

- `CustomCounterCache.counter_class_name` (default `'Counter'`) sets the model behind the
  counters table.
- `define_counter_cache :name, touch: true` (or `touch: :column`) sets a timestamp on the owner
  whenever the counter is recounted. A column counter is written in the same UPDATE, and no
  callbacks run.
- `define_counter_cache :name, store: :cache, expires_in:` keeps a counter in
  `CustomCounterCache.cache_store` (defaults to `Rails.cache`). It is computed on a miss and
  deleted after commit when a child changes, instead of being recounted. Destroying the owner
  deletes its keys.
- `update_counter_cache ..., on_change: [:attr]` recounts on update only when a listed attribute
  or the association's key columns changed. Create and destroy always recount.
- `update_counter_cache [:article, :user], :comments_count` follows a path of `belongs_to`
  associations and recounts both the old and the new owner at the end of it (grandparent counters).
- `update_counter_cache ..., recount: :later` recounts in `CustomCounterCache::RecountJob`
  (Active Job), enqueued after commit, once per owner and counter per transaction.
- `CustomCounterCache.batch { }` recounts each owner and counter once after the block ends.
- `CustomCounterCache.skip { }` drops recounts inside the block.
- `Model.recount_counter_caches(*names, scope:, batch_size:)` recounts every record (or a scope) in
  batches, repairing drift from `update_all`, `delete_all` and imports.
- The `custom_counter_cache:recount` rake task (`MODEL=`, `COUNTERS=`, `BATCH_SIZE=`) wraps
  `recount_counter_caches`.
- Composite primary keys: owners and `belongs_to` associations with composite keys work with
  column and cache counters, reassignment (including a change to only some key columns),
  `on_change:`, `recount: :later` and `recount_counter_caches`. The counters table can't hold a
  composite key, so a counter there raises `ArgumentError` naming the alternatives.
- `only:` and `except:` on `update_counter_cache` accept `:restore`, the event fired by Paranoia's
  `restore`.

### Upgrading

- If an `:if`/`:unless` condition was meant to skip destroys, add `except: [:destroy]`.
- If you relied on a recount updating the owner's `updated_at`, pass `touch: true` to
  `define_counter_cache`. Owner callbacks no longer run on a recount; call them explicitly if needed.
- If a migration adds a counter column and backfills it, call `reset_column_information` on the
  model before backfilling.
- Counters now change when the saving transaction commits. Code that saves a child and reads the
  owner's counter inside the same transaction should call `update_<name>` first.
- A counters-table counter whose block can return a fractional value (an average, a sum of
  decimals) now raises: move it to a column of a suitable type or to `store: :cache`.
- On a model with a string or UUID primary key, the counters table's `countable_id` must be that
  type (`t.references :countable, polymorphic: true, type: :uuid`).

## 0.3.2

### Fixed

- Moving a record between owners now recounts the old owner when `belongs_to` uses a custom
  `primary_key:`.
- Polymorphic `belongs_to` with custom `foreign_key:`/`foreign_type:` no longer raises
  `NoMethodError` on save.
- Moving a record away from a polymorphic type whose class no longer exists no longer raises
  `NameError`; the new owner is still recounted.
- With `includes(:counters)`, counters stay current after an update, and a missing counter
  returns 0 without a query.
- Two saves creating the same virtual counter at once no longer fail with
  `ActiveRecord::RecordNotUnique`; the second updates the row instead.
- `update_counter_cache` without its `belongs_to` raises a clear `ArgumentError` instead of
  `NoMethodError ... for nil`.

### Changed

- Depend on `activerecord` and `activesupport` instead of all of `rails`.
- Require Ruby >= 3.1 in the gemspec, matching the README and Rails 7.2.
- Test against every non-EOL Ruby (3.3, 3.4, 4.0) and Rails (8.0, 8.1).
- Expand the test suite to cover all branches.
- README: fix the `:if` example (`state_changed?` is always false in after callbacks)
  and note that `:if` also applies to `after_destroy`.
