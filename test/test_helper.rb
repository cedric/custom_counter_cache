require 'rubygems'
require 'minitest/autorun'
require 'sqlite3'
require 'action_view'
require 'active_record'
require 'custom_counter_cache'

ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')

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
end

class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
  include CustomCounterCache::Model
  @@rails_5_1_or_newer = ActiveModel.version >= Gem::Version.new('5.1.0')

  def saved_change_to_attribute_compat?(attr)
    if @@rails_5_1_or_newer
      saved_change_to_attribute?(attr)
    else
      attribute_changed?(attr)
    end
  end
end

class User < ApplicationRecord
  has_many :articles, dependent: :destroy
  define_counter_cache :published_count do |user|
    user.articles.where(articles: { state: 'published' }).count
  end
end

class Article < ApplicationRecord
  belongs_to :user
  update_counter_cache :user, :published_count, if: Proc.new { |article| article.saved_change_to_attribute_compat?(:state) }
  has_many :comments, as: :commentable, dependent: :destroy
  define_counter_cache :comments_count do |article|
    article.comments.where(state: "published").count
  end
end

class Comment < ApplicationRecord
  belongs_to :commentable, polymorphic: true
  update_counter_cache :commentable, :comments_count, if: Proc.new { |comment| comment.saved_change_to_attribute_compat?(:state) }
end

class Counter < ApplicationRecord
  belongs_to :countable, polymorphic: true
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
end

class Ball < ApplicationRecord
  belongs_to :box
  scope :green, lambda { where(color: 'green') }
  update_counter_cache :box, :green_balls_count, if: Proc.new { |ball| ball.saved_change_to_attribute_compat?(:color) }
  update_counter_cache :box, :lifetime_balls_count, except: [:update, :destroy]
  update_counter_cache :box, :destroyed_balls_count, only: [:destroy]
end
