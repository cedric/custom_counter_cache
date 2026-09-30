require 'minitest/autorun'
require 'sqlite3'
require 'active_record'
require 'custom_counter_cache'

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

  create_table :teams do |t|
    t.string :code
    t.integer :players_count, default: 0
  end

  create_table :players do |t|
    t.string :team_code
  end

  create_table :user_notes do |t|
    t.belongs_to :user
  end

  create_table :user_note_logs do |t|
    t.belongs_to :user_note
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
