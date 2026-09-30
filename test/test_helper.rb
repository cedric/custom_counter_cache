require 'minitest/autorun'
require 'sqlite3'
require 'active_record'
require 'bigdecimal'
require 'discard'
require 'paranoia'
require 'custom_counter_cache'
require 'active_job'

ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.logger = Logger.new(nil)

ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')

ActiveRecord::Migration.verbose = false

ActiveRecord::Schema.define(version: 1) do
  create_table :users do |t|
  end

  create_table :articles do |t|
    t.belongs_to :user
    t.string :state, default: 'unpublished'
  end

  create_table :comments do |t|
    t.belongs_to :user
    t.references :commentable, polymorphic: true
    t.string :state, default: "unpublished"
  end

  create_table :counters do |t|
    t.references :countable, polymorphic: true
    t.string :key, null: false
    t.integer :value, null: false, default: 0
  end
  add_index :counters, [ :countable_id, :countable_type, :key ], unique: true

  create_table :boxes do |t|
    t.integer :green_balls_count, default: 0
    t.integer :lifetime_balls_count, default: 0
    t.integer :destroyed_balls_count, default: 0
  end

  create_table :balls do |t|
    t.belongs_to :box
    t.string :color, default: 'red'
  end

  create_table :libraries do |t|
    t.integer :books_count, default: 0
    t.string :name
    t.integer :lock_version, default: 0
    t.timestamps
  end

  create_table :books do |t|
    t.belongs_to :library
  end

  create_table :photos do |t|
  end

  create_table :tags do |t|
    t.integer :target_ref
    t.string :target_kind
  end

  create_table :forums do |t|
    t.integer :votes_count, default: 0
    t.integer :replies_count, default: 0
  end

  create_table :topics do |t|
    t.belongs_to :forum
  end

  create_table :polls do |t|
  end

  create_table :votes do |t|
    t.belongs_to :topic
  end

  create_table :replies do |t|
    t.references :parent, polymorphic: true
  end

  create_table :shops do |t|
    t.integer :orders_count, default: 0
    t.integer :receipts_count, default: 0
  end

  create_table :orders do |t|
    t.belongs_to :shop
  end

  create_table :receipts do |t|
    t.belongs_to :shop
  end

  create_table :blogs do |t|
    t.integer :authors_count, default: 0
    t.timestamps
  end

  create_table :entries do |t|
    t.belongs_to :blog
    t.boolean :draft, default: false
  end

  create_table :stores, primary_key: [:region, :number] do |t|
    t.string :region
    t.integer :number
    t.integer :sales_count, default: 0
    t.integer :refunds_count, default: 0
  end

  create_table :sales do |t|
    t.string :store_region
    t.integer :store_number
    t.integer :amount, default: 0
  end

  create_table :refunds do |t|
    t.string :store_region
    t.integer :store_number
  end

  create_table :gadgets do |t|
  end

  create_table :gadget_counters do |t|
    t.references :countable, polymorphic: true
    t.string :key, null: false
    t.integer :value, null: false, default: 0
  end

  # No parts_count column: tests add it at runtime.
  create_table :widgets do |t|
  end

  create_table :teams do |t|
    t.string :code
    t.integer :players_count, default: 0
  end

  create_table :players do |t|
    t.string :team_code
  end

  create_table :shelves do |t|
    t.integer :items_count, default: 0
    t.integer :plain_items_count, default: 0
    t.datetime :refreshed_at
    t.timestamps
  end

  create_table :items do |t|
    t.belongs_to :shelf
  end

  create_table :projects do |t|
    t.integer :done_count, default: 0
  end

  create_table :sprints do |t|
    t.integer :done_count, default: 0
  end

  create_table :tasks do |t|
    t.belongs_to :project
    t.string :title
    t.string :state, default: 'todo'
  end

  create_table :tickets do |t|
    t.references :target, polymorphic: true
    t.string :title
    t.string :state, default: 'todo'
  end

  create_table :user_notes do |t|
    t.belongs_to :user
  end

  create_table :user_note_logs do |t|
    t.belongs_to :user_note
  end

  create_table :notebooks do |t|
    t.integer :pages_count, default: 0
  end

  create_table :pages do |t|
    t.belongs_to :notebook
    t.string :state, default: 'draft'
    t.datetime :discarded_at
  end

  create_table :crates do |t|
    t.integer :parcels_count, default: 0
  end

  create_table :parcels do |t|
    t.belongs_to :crate
    t.datetime :deleted_at
  end

  create_table :people do |t|
    t.string :type
    t.string :name
  end

  create_table :person_notes do |t|
    t.belongs_to :person
    t.string :type
  end

  create_table :vaults, id: false do |t|
    t.string :code, primary_key: true
    t.integer :deposits_count, default: 0
    t.integer :later_deposits_count, default: 0
  end

  create_table :deposits do |t|
    t.string :vault_code
  end

  create_table :lockers, id: false do |t|
    t.string :code, primary_key: true
  end

  create_table :locker_items do |t|
    t.string :locker_code
  end

  create_table :string_counters do |t|
    t.references :countable, polymorphic: true, type: :string
    t.string :key, null: false
    t.integer :value, null: false, default: 0
  end

  create_table :districts do |t|
    t.integer :ballots_count, default: 0
  end

  create_table :precincts do |t|
    t.belongs_to :district
  end

  create_table :ballots do |t|
    t.belongs_to :precinct
    t.integer :weight, default: 0
    t.string :note
  end

  create_table :gauges do |t|
    t.integer :foo_count, default: 0
  end
end

class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
  include CustomCounterCache::Model
end

class User < ApplicationRecord
  has_many :articles, dependent: :destroy
  has_one :user_note, dependent: :destroy
  define_counter_cache :published_count do |user|
    user.articles.where(articles: { state: 'published' }).count
  end
end

class Article < ApplicationRecord
  belongs_to :user
  update_counter_cache :user, :published_count, if: Proc.new { |article| article.saved_change_to_attribute?(:state) }
  has_many :comments, as: :commentable, dependent: :destroy
  define_counter_cache :comments_count do |article|
    article.comments.where(state: "published").count
  end
end

class Comment < ApplicationRecord
  belongs_to :commentable, polymorphic: true
  update_counter_cache :commentable, :comments_count, if: Proc.new { |comment| comment.saved_change_to_attribute?(:state) }
end

# Second commentable sharing Article's virtual :comments_count key.
class Photo < ApplicationRecord
  has_many :comments, as: :commentable
  has_many :tags, as: :target, foreign_key: :target_ref, foreign_type: :target_kind
  define_counter_cache :comments_count do |photo|
    photo.comments.where(state: 'published').count
  end
  define_counter_cache(:tags_count) { |photo| photo.tags.count }
end

# Polymorphic belongs_to with non-default key and type columns.
class Tag < ApplicationRecord
  belongs_to :target, polymorphic: true, foreign_key: :target_ref, foreign_type: :target_kind
  update_counter_cache :target, :tags_count
end

# Grandparent counters: Vote -> Topic -> Forum, and Reply -> (Topic | Poll) -> Forum.
class Forum < ApplicationRecord
  has_many :topics
  define_counter_cache(:votes_count) { |forum| Vote.where(topic_id: forum.topics.select(:id)).count }
  define_counter_cache(:replies_count) { |forum| Reply.where(parent_type: 'Topic', parent_id: forum.topics.select(:id)).count }
end

class Topic < ApplicationRecord
  belongs_to :forum, optional: true
  has_many :votes
  has_many :replies, as: :parent
  # A topic moving between forums changes both forums' grandchild counts.
  update_counter_cache :forum, :votes_count
  update_counter_cache :forum, :replies_count
end

# Has no forum: replies on a poll stop at the polymorphic step.
class Poll < ApplicationRecord
  has_many :replies, as: :parent
end

# Its :forum isn't a belongs_to, so a reply's path can't continue through it.
class Quiz < ApplicationRecord
  self.table_name = 'polls'
  has_many :replies, as: :parent
  has_many :forum, class_name: 'Forum'
end

class Vote < ApplicationRecord
  belongs_to :topic
  update_counter_cache [:topic, :forum], :votes_count
end

# Topic has no :galaxy; declaring is fine, the first save raises.
class MisdirectedVote < ApplicationRecord
  self.table_name = 'votes'
  belongs_to :topic
  update_counter_cache [:topic, :galaxy], :votes_count
end

class Reply < ApplicationRecord
  belongs_to :parent, polymorphic: true
  update_counter_cache [:parent, :forum], :replies_count
end

# Deferred recounts; exercised by DeferredRecountTest, which commits for real.
class Shop < ApplicationRecord
  define_counter_cache(:orders_count) { |shop| Order.where(shop: shop).count }
  define_counter_cache(:receipts_count) { |shop| Receipt.where(shop: shop).count }
end

class Order < ApplicationRecord
  belongs_to :shop
  update_counter_cache :shop, :orders_count, recount: :after_commit
end

class Receipt < ApplicationRecord
  belongs_to :shop
  update_counter_cache :shop, :receipts_count, recount: :later
end

# Cache-stored counters; exercised by CacheStoreTest, which commits for real.
class Blog < ApplicationRecord
  has_many :entries
  define_counter_cache(:entries_count, store: :cache, expires_in: 1.hour) { |blog| blog.entries.count }
  define_counter_cache(:drafts_count, store: :cache, touch: true) { |blog| blog.entries.where(draft: true).count }
  define_counter_cache(:authors_count) { |blog| 1 } # a column counter alongside the cached ones
end

class Entry < ApplicationRecord
  belongs_to :blog
  update_counter_cache :blog, :entries_count
  update_counter_cache :blog, :drafts_count
end

# Composite primary key owner, children with composite foreign keys.
class Store < ApplicationRecord
  has_many :sales, foreign_key: [:store_region, :store_number]
  define_counter_cache(:sales_count) { |store| store.sales.count }
  define_counter_cache(:refunds_count) { |store| Refund.where(store_region: store.region, store_number: store.number).count }
  define_counter_cache(:cached_sales_count, store: :cache) { |store| store.sales.count }
end

class Sale < ApplicationRecord
  belongs_to :store, foreign_key: [:store_region, :store_number]
  update_counter_cache :store, :sales_count, on_change: [:amount]
  update_counter_cache :store, :cached_sales_count
end

class Refund < ApplicationRecord
  belongs_to :store, foreign_key: [:store_region, :store_number]
  update_counter_cache :store, :refunds_count, recount: :later
end

# The counters table's single countable_id can't hold a composite key.
class Kiosk < ApplicationRecord
  self.table_name = 'stores'
  define_counter_cache(:tallies_count) { |kiosk| 0 }
end

# Destroys its entries with it, so their recounts target an owner that's already gone.
class CascadeBlog < ApplicationRecord
  self.table_name = 'blogs'
  has_many :entries, class_name: 'CascadeEntry', foreign_key: :blog_id, dependent: :destroy, inverse_of: :blog
  define_counter_cache(:drafts_count, store: :cache, touch: true) { |blog| blog.entries.where(draft: true).count }
end

class CascadeEntry < ApplicationRecord
  self.table_name = 'entries'
  belongs_to :blog, class_name: 'CascadeBlog', inverse_of: :entries
  update_counter_cache :blog, :drafts_count
end

# Its counter block raises for a library named 'broken', to exercise recount failures.
class FlakyLibrary < ApplicationRecord
  self.table_name = 'libraries'
  define_counter_cache(:books_count) do |library|
    raise 'count failed' if library.name == 'broken'
    Book.where(library_id: library.id).count
  end
end

class FlakyBook < ApplicationRecord
  self.table_name = 'books'
  belongs_to :library, class_name: 'FlakyLibrary'
  update_counter_cache :library, :books_count
end

class GadgetCounter < ApplicationRecord
  belongs_to :countable, polymorphic: true
end

# Stores its counters in GadgetCounter via the global setting, restored right after.
CustomCounterCache.counter_class_name = 'GadgetCounter'
class Gadget < ApplicationRecord
  define_counter_cache(:clicks_count) { |gadget| 2 }
end
CustomCounterCache.counter_class_name = 'Counter'

class Widget < ApplicationRecord
  define_counter_cache(:parts_count) { |widget| 3 }
end

# belongs_to via a non-id primary key.
class Team < ApplicationRecord
  has_many :players, primary_key: :code, foreign_key: :team_code
  define_counter_cache(:players_count) { |team| team.players.count }
end

class Player < ApplicationRecord
  belongs_to :team, primary_key: :code, foreign_key: :team_code
  update_counter_cache :team, :players_count
end

# Column-only counter: must not get a :counters association.
class Library < ApplicationRecord
  has_many :books
  define_counter_cache(:books_count) { |library| library.books.count }
end

class Book < ApplicationRecord
  belongs_to :library, optional: true
  update_counter_cache :library, :books_count
end

# Deliberately misconfigured (dependent: :destroy on belongs_to); the destroy-loop tests rely on it.
class Counter < ApplicationRecord
  belongs_to :countable, polymorphic: true, dependent: :destroy
end

class Box < ApplicationRecord
  has_many :balls
  define_counter_cache :green_balls_count do |box|
    box.balls.green.count
  end
  define_counter_cache :lifetime_balls_count do |box|
    box.lifetime_balls_count + 1
  end
  define_counter_cache :destroyed_balls_count do |box|
    box.destroyed_balls_count + 1
  end
  define_counter_cache :non_green_balls_count do |box|
    box.balls.where.not(color: 'green').count
  end
  define_counter_cache :marker_a_count do |box|
    0
  end
  define_counter_cache :marker_b_count do |box|
    0
  end
  define_counter_cache :create_destroy_events_count do |box|
    box.create_destroy_events_count + 1
  end
  define_counter_cache :update_events_count do |box|
    box.update_events_count + 1
  end
end

class Ball < ApplicationRecord
  belongs_to :box
  scope :green, lambda { where(color: 'green') }
  update_counter_cache :box, :green_balls_count, if: Proc.new { |ball| ball.saved_change_to_attribute?(:color) }
  update_counter_cache :box, :lifetime_balls_count, except: [:update, :destroy]
  update_counter_cache :box, :destroyed_balls_count, only: [:destroy]
  update_counter_cache :box, :non_green_balls_count, unless: Proc.new { |ball| ball.color == 'green' }
  update_counter_cache :box, :marker_a_count, only: [:create]
  update_counter_cache :box, :marker_b_count, only: [:create], prepend: true
  update_counter_cache :box, :create_destroy_events_count, only: [:create, :destroy]
  update_counter_cache :box, :update_events_count, except: [:create, :destroy]
end

# touch: on a column counter (touch: true) and on virtual counters (a named column, string or symbol).
class Shelf < ApplicationRecord
  has_many :items
  define_counter_cache(:items_count, touch: true) { |shelf| shelf.items.count }
  define_counter_cache(:plain_items_count) { |shelf| shelf.items.count }
  define_counter_cache(:notes_count, touch: :refreshed_at) { |shelf| 7 }
  define_counter_cache(:stamped_count, touch: 'refreshed_at') { |shelf| 8 }
  define_counter_cache(:stamped_by_default_count, touch: true) { |shelf| 9 }
end

class Item < ApplicationRecord
  belongs_to :shelf
  update_counter_cache :shelf, :items_count
end

# on_change: with an array on a plain belongs_to, and with a single symbol on a polymorphic one.
class Project < ApplicationRecord
  has_many :tasks
  has_many :tickets, as: :target
  define_counter_cache(:done_count) { |project| project.tasks.where(state: 'done').count + project.tickets.where(state: 'done').count }
end

class Sprint < ApplicationRecord
  has_many :tickets, as: :target
  define_counter_cache(:done_count) { |sprint| sprint.tickets.where(state: 'done').count }
end

class Task < ApplicationRecord
  belongs_to :project, optional: true
  update_counter_cache :project, :done_count, on_change: [:state]
end

class GatedTask < ApplicationRecord
  self.table_name = 'tasks'
  belongs_to :project, optional: true
  update_counter_cache :project, :done_count, on_change: [:state], if: ->(task) { task.title == 'go' }
end

class Ticket < ApplicationRecord
  belongs_to :target, polymorphic: true, optional: true
  update_counter_cache :target, :done_count, on_change: :state
end

# Stands in for `audited`: has_one whose destroy writes a log from before_destroy, so a
# recursive owner destroy fails on the second pass (the record is no longer persisted).
class UserNote < ApplicationRecord
  belongs_to :user
  has_many :logs, class_name: 'UserNoteLog', foreign_key: :user_note_id, dependent: :destroy
  before_destroy :write_log

  def write_log
    logs.create!
  end
end

class UserNoteLog < ApplicationRecord
  belongs_to :user_note
end

# Discard soft-deletes with an ordinary update, so the callbacks already fire.
class Notebook < ApplicationRecord
  has_many :pages
  define_counter_cache(:pages_count) { |notebook| notebook.pages.kept.count }
end

class Page < ApplicationRecord
  include Discard::Model
  belongs_to :notebook
  update_counter_cache :notebook, :pages_count
end

# discarded_at isn't listed, so discard and undiscard don't recount.
class StatePage < ApplicationRecord
  self.table_name = 'pages'
  include Discard::Model
  belongs_to :notebook
  update_counter_cache :notebook, :pages_count, on_change: [:state]
end

class TrackedPage < ApplicationRecord
  self.table_name = 'pages'
  include Discard::Model
  belongs_to :notebook
  update_counter_cache :notebook, :pages_count, on_change: [:state, :discarded_at]
end

# Paranoia's destroy runs callbacks; restore has its own :restore callback.
class Crate < ApplicationRecord
  has_many :parcels
  define_counter_cache(:parcels_count) { |crate| crate.parcels.count }
end

class Parcel < ApplicationRecord
  acts_as_paranoid
  belongs_to :crate
  update_counter_cache :crate, :parcels_count
end

class QuietParcel < ApplicationRecord
  self.table_name = 'parcels'
  acts_as_paranoid
  belongs_to :crate
  update_counter_cache :crate, :parcels_count, except: [:restore]
end

class CreatedParcel < ApplicationRecord
  self.table_name = 'parcels'
  acts_as_paranoid
  belongs_to :crate
  update_counter_cache :crate, :parcels_count, only: [:create]
end

# Declared before acts_as_paranoid: the :restore callback isn't there yet, so restore is missed.
class EarlyParcel < ApplicationRecord
  self.table_name = 'parcels'
  belongs_to :crate
  update_counter_cache :crate, :parcels_count
  acts_as_paranoid
end

# Single-table inheritance: Member adds a counter; PersonSpecialNote inherits its parent's callback.
class Person < ApplicationRecord
  define_counter_cache(:notes_count) { |person| PersonNote.where(person_id: person.id).count }
  define_counter_cache(:cached_notes_count, store: :cache) { |person| PersonNote.where(person_id: person.id).count }
end

class Member < Person
  define_counter_cache(:badges_count) { |member| 4 }
end

class PersonNote < ApplicationRecord
  belongs_to :person
  update_counter_cache :person, :notes_count
  update_counter_cache :person, :cached_notes_count
end

class PersonSpecialNote < PersonNote
end

# Owner with a string primary key that isn't id.
class Vault < ApplicationRecord
  self.primary_key = 'code'
  has_many :deposits, foreign_key: :vault_code
  define_counter_cache(:deposits_count) { |vault| vault.deposits.count }
  define_counter_cache(:later_deposits_count) { |vault| vault.deposits.count }
  define_counter_cache(:cached_deposits_count, store: :cache) { |vault| vault.deposits.count }
end

class Deposit < ApplicationRecord
  belongs_to :vault, foreign_key: :vault_code, primary_key: :code
  update_counter_cache :vault, :deposits_count
  update_counter_cache :vault, :cached_deposits_count
end

class LaterDeposit < ApplicationRecord
  self.table_name = 'deposits'
  belongs_to :vault, foreign_key: :vault_code, primary_key: :code
  update_counter_cache :vault, :later_deposits_count, recount: :later
end

class StringCounter < ApplicationRecord
  belongs_to :countable, polymorphic: true
end

# String primary key with a counters table whose countable_id is a string, via the global setting, restored right after.
CustomCounterCache.counter_class_name = 'StringCounter'
class Locker < ApplicationRecord
  self.primary_key = 'code'
  has_many :locker_items, foreign_key: :locker_code
  define_counter_cache(:items_count) { |locker| locker.locker_items.count }
end
CustomCounterCache.counter_class_name = 'Counter'

class LockerItem < ApplicationRecord
  belongs_to :locker, foreign_key: :locker_code, primary_key: :code
  update_counter_cache :locker, :items_count
end

# Grandparent path whose on_change: lists an attribute of the child.
class District < ApplicationRecord
  define_counter_cache(:ballots_count) { |district| Ballot.where(precinct_id: district.precincts.select(:id)).count }
  has_many :precincts
end

class Precinct < ApplicationRecord
  belongs_to :district
end

class Ballot < ApplicationRecord
  belongs_to :precinct
  update_counter_cache [:precinct, :district], :ballots_count, on_change: [:weight]
end

# Child of Blog's cached counter that recounts :later.
class LaterEntry < ApplicationRecord
  self.table_name = 'entries'
  belongs_to :blog
  update_counter_cache :blog, :entries_count, recount: :later
end

# A cached counter sharing its name with a real column.
class Gauge < ApplicationRecord
  define_counter_cache(:foo_count, store: :cache) { |gauge| 42 }
end
