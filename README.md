# Custom Counter Cache

[![CI](https://github.com/cedric/custom_counter_cache/actions/workflows/ci.yml/badge.svg)](https://github.com/cedric/custom_counter_cache/actions/workflows/ci.yml)

Custom Counter Cache is a Rails gem for counter caches whose value comes from any block you give
it, kept up to date by callbacks on any number of models:

- **Any value** — the block recomputes the counter from scratch, so it can count with any
  conditions (`user.articles.where(state: 'published').count`), sum, or anything else.
- **Any number of triggers** — each model that can change the counter declares it, including
  polymorphic associations, custom and composite keys, and grandparent owners.
- **Three places to keep it** — a column, a shared counters table (no migration per counter), or
  a cache store such as Redis or Memcached.
- **Correct under concurrency** — recounts run after the transaction commits, once per owner and
  counter, under a short row lock, so concurrent saves can't leave a stale count.
- **Bulk tools** — batch or skip recounts during imports, and repair drift with
  `recount_counter_caches` or a rake task.

Because every recount recomputes the value, a late, repeated or batched recount still ends at the
right number. Counter caches that add and subtract 1 (Rails' built-in `counter_cache`,
counter_culture) are faster per update but drift after bulk operations, races or bugs; this gem
trades a count query per recount for that property.

## Installation

Requires Ruby 3.3 or newer and Rails (Active Record) 8.0 or newer. CI runs Ruby 3.3, 3.4 and 4.0
against Rails 8.0 and 8.1, the versions that are not yet end-of-life.

Add the following to your Gemfile:

```ruby
gem 'custom_counter_cache'
```

Then include the module in the models that define or update counters, usually all of them:

```ruby
class ApplicationRecord < ActiveRecord::Base
  include CustomCounterCache::Model
  primary_abstract_class
end
```

## Defining a counter

The block calculates the counter's value from its owner. It's called whenever a model that
declares `update_counter_cache` (see below) changes.

```ruby
class User < ApplicationRecord
  has_many :articles

  define_counter_cache :articles_count do |user|
    user.articles.where(state: 'published').count
  end
end
```

This defines `user.articles_count`, `user.articles_count=` and `user.update_articles_count`, which
recounts immediately.

Pass `touch: true` (or a column name, e.g. `touch: :counted_at`) to also set that timestamp,
`updated_at` for `true`, on every recount. A column counter is written in the same UPDATE, and no
callbacks run.

Where the value is kept depends on the counter: a column of the same name, a row in a shared
counters table, or a cache store (`store: :cache`). See [Choosing storage](#choosing-storage).

## Triggering recounts

Declare which models change the counter with `update_counter_cache`, naming a `belongs_to`
association and the counter on its owner:

```ruby
class Article < ApplicationRecord
  belongs_to :user

  update_counter_cache :user, :articles_count, on_change: [:state]
end
```

This registers after_create, after_update and after_destroy callbacks (plus after_restore for
Paranoia, see [Soft deletes](#soft-deletes)). Any number of models can update the same counter.
When a record moves to another owner, both the old and the new owner are recounted.

| Option | Effect |
|---|---|
| `on_change: [:state]` | Recount on update only when a listed attribute changed. The association's key columns (plus the type column for a polymorphic one) are always watched, so moving the record to another owner recounts both. Create and destroy always recount. Prefer it to `:if` for plain attribute checks. |
| `if:` / `unless:` | Limit when the create and update callbacks run, e.g. `if: -> { saved_change_to_state? }`. They don't apply to destroy or restore: those have no saved changes, and an extra recount is never wrong. Combined with `on_change:`, both must allow the update. |
| `only:` / `except:` | Limit the events, any of `:create`, `:update`, `:destroy` and `:restore`, e.g. `only: [:create, :destroy]` or `except: [:destroy]`. |
| `prepend: true` | Prepend the callbacks instead of appending them. |
| `recount: :later` | Recount in a background job instead of right after commit. See [Background jobs](#background-jobs). |

The callbacks run after the record is saved, so in an `:if` use `saved_change_to_state?` rather
than `state_changed?`, which is always false by then.

## Grandparent counters

Pass a path of `belongs_to` associations to recount an owner further up. For a `comments_count`
on User across all of a user's articles:

```ruby
class User < ApplicationRecord
  has_many :articles
  has_many :comments, through: :articles
  define_counter_cache(:comments_count) { |user| user.comments.count }
end

class Comment < ApplicationRecord
  belongs_to :article
  update_counter_cache [:article, :user], :comments_count
end

class Article < ApplicationRecord
  belongs_to :user
  update_counter_cache :user, :comments_count # an article moving users changes both counts
end
```

Moving a comment recounts the old and the new user, once if they're the same user. The second
declaration is needed because an Article changing user also changes both users' counts, and only
Article's own callbacks see that. A step after a polymorphic one is skipped for records whose
class has no such association; any other missing or non-`belongs_to` step raises `ArgumentError`.

## Soft deletes

### Discard

Discard soft-deletes with an ordinary update, so the callbacks already fire. Filter with `.kept`
in the counter block, and if you use `on_change:`, include `:discarded_at`, or discarding won't
recount:

```ruby
define_counter_cache(:pages_count) { |notebook| notebook.pages.kept.count }
update_counter_cache :notebook, :pages_count, on_change: [:state, :discarded_at]
```

### Paranoia

Paranoia's `destroy` runs the destroy callbacks, and `restore` is recounted too, provided
`acts_as_paranoid` is declared before `update_counter_cache`. Skip it with `except: [:restore]`
(`only:` accepts `:restore` too).

```ruby
class Parcel < ApplicationRecord
  acts_as_paranoid
  belongs_to :crate
  update_counter_cache :crate, :parcels_count
end
```

## Batching and skipping

Every triggering save recounts its owner. For bulk work, batch the recounts so each owner and
counter is recounted once, when the block ends (or when its transaction commits):

```ruby
CustomCounterCache.batch do
  rows.each { |row| article.comments.create!(row) } # one recount of article.comments_count
end
```

Batches nest (the outermost one flushes) and still flush if the block raises, since a recount
reflects whatever is in the database. To skip recounts entirely, e.g. for an import you'll
recount afterwards:

```ruby
CustomCounterCache.skip { import_comments }
```

Both are per thread (and per fiber).

## When recounts run

Recounts triggered by these callbacks run after the saving transaction commits, once per owner
and counter per transaction, and not at all if it rolls back. Each takes a short lock on the
owner's row while it counts, so two saves committing at once can't leave a stale value: the later
recount always counts after the earlier commit. (Counting inside the saving transaction can't see
a concurrent save's uncommitted child, so one of them would overwrite the other.)

The counter therefore changes when the transaction commits, not when the child is saved. Inside a
transaction, call the update method yourself if you need the new value straight away:

```ruby
Article.transaction do
  user.articles.create!(attrs)
  user.update_articles_count # recounts now; update_* and recount_counter_caches never wait
end
```

### Failures

If a recount raises after commit, the save has already succeeded and the count can be rebuilt, so
the error doesn't propagate to the caller or stop the other recounts queued for that commit. It's
passed to `Rails.error.unexpected`, which raises in development and test (with
`consider_all_requests_local`, as by default) and in production reports it to your error tracker
with the owner and counter in the context. It's also logged.

Calling `update_<name>` or `recount_counter_caches` yourself raises as usual, and so does
`CustomCounterCache::RecountJob`, so your queue's retries apply.

### Background jobs

To recount in a background job instead, enqueued after commit:

```ruby
update_counter_cache :user, :articles_count, recount: :later
```

This enqueues `CustomCounterCache::RecountJob` (Active Job) once per owner and counter per
transaction. To pick a queue:

```ruby
CustomCounterCache::RecountJob.queue_as :low
```

## Choosing storage

| Storage | How | Trade-offs |
|---|---|---|
| Column | Add a column with the counter's name. | Fastest to read, and you can sort and filter by it in SQL. Needs a migration per counter. |
| Counters table | Used automatically when there's no column. See [The counters table](#the-counters-table). | One shared table, no migration per counter; preload with `includes(:counters)`. Whole numbers only. |
| Cache | `define_counter_cache :x, store: :cache, expires_in: 12.hours` | Kept in `CustomCounterCache.cache_store` (defaults to `Rails.cache`: Redis, Memcached, Solid Cache...). Reads compute on a miss; a child change deletes the key after commit instead of recounting, so writes are cheap and never lock the owner's row. Destroying the owner deletes its keys. Not visible to SQL, and a delete racing a concurrent read can leave a stale value for up to `expires_in`. |

Column or counters table is decided when the counter is read or written, not when the model
loads, so defining counters never touches the database, and a column added later is picked up.

To use a column, add one:

```ruby
def change
  add_column :users, :articles_count, :integer, default: 0, null: false
end
```

## The counters table

To store counters in a single shared table, use this migration:

```ruby
create_table :counters do |t|
  t.references :countable, polymorphic: true
  t.string :key, null: false
  t.integer :value, null: false, default: 0
  t.timestamps
end
add_index :counters, [:countable_id, :countable_type, :key], unique: true
```

and this model:

```ruby
class Counter < ActiveRecord::Base
  belongs_to :countable, polymorphic: true
  validates :countable, presence: true
end
```

To use a different model name (for example if `Counter` is already taken), set
`CustomCounterCache.counter_class_name` (see [Configuration](#configuration)).

When a record is destroyed, its counter rows are removed with a single DELETE, without loading
them or running Counter's callbacks. Don't add `dependent: :destroy` to the `belongs_to` above: on
a `belongs_to` it means "destroying this Counter also destroys its owner".

### Whole numbers only

The table holds whole numbers. A block result of `nil` is stored as 0, and whole values such as
`4.0` or `BigDecimal('4')` are converted, but a fractional result such as an average raises
`ArgumentError` rather than being truncated: give that counter a column of a suitable type (e.g.
decimal) or use `store: :cache`.

### Primary key types

`countable_id` must match your models' primary key type. For string or UUID keys, use
`t.references :countable, polymorphic: true, type: :uuid` (or `:string`).

A model with a composite primary key can't use this table, since `countable_id` holds one value:
give its counters a column or `store: :cache` (it raises `ArgumentError` otherwise). Composite keys
work everywhere else, including composite foreign keys on the `belongs_to` side.

## Backfilling and repairing

To backfill your counters, or repair them later, recount every record from the console or a
migration:

```ruby
User.recount_counter_caches
```

or only some counters and records:

```ruby
User.recount_counter_caches(:articles_count, scope: User.where(id: 1..1000), batch_size: 500)
```

It returns the number of records processed. The same is available as a rake task, where
`COUNTERS` (comma-separated, default all) and `BATCH_SIZE` (default 1000) are optional:

```
bin/rails custom_counter_cache:recount MODEL=User COUNTERS=articles_count
```

Callbacks can't see `update_all`, `delete_all`, `insert_all` or SQL imports, so counts drift after
them. Run the recount periodically, or after an import, to repair that. It calls `update_<name>`
directly, so it also works inside `CustomCounterCache.skip { }`.

In a migration that also adds the column, call `User.reset_column_information` first so the
backfill writes to the new column.

## Configuration

Set these in an initializer, before your models load:

```ruby
# config/initializers/custom_counter_cache.rb

# The model behind the counters table. Default: 'Counter'.
CustomCounterCache.counter_class_name = 'CounterCache'

# The store for store: :cache counters. Default: Rails.cache.
CustomCounterCache.cache_store = ActiveSupport::Cache::MemoryStore.new
```

## Testing

Rails' transactional tests commit each save within the test transaction, so recounts happen after
each save as they do in production; inside an explicit `transaction` block they wait for its end.
A recount that raises fails the test, since Rails' error reporter raises in the test environment.

With `recount: :later`, run the enqueued jobs (e.g. `perform_enqueued_jobs`) before asserting on
the counter.
