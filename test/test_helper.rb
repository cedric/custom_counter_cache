require 'rubygems'
require 'test/unit'
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
  create_table :counters do |t|
    t.references :countable, polymorphic: true
    t.string :key, null: false
    t.integer :value, null: false, default: 0
  end
  add_index :counters, [ :countable_id, :countable_type, :key ], unique: true
end

class User < ActiveRecord::Base
  has_many :articles
  define_counter_cache :published_count do |user|
    user.articles.where(articles: { state: 'published' }).count
  end
end

class Article < ActiveRecord::Base
  belongs_to :user
  update_counter_cache :user, :published_count, if: Proc.new { |article| article.state_changed? }
end

class Counter < ActiveRecord::Base
  belongs_to :countable, polymorphic: true
end
