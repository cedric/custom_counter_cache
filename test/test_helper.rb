$: << File.join(File.dirname(__FILE__), '..', 'lib')
$: << File.join(File.dirname(__FILE__))

require 'rubygems'
require 'test/unit'
require 'sqlite3'
require 'mocha'
require 'active_support'
require 'action_controller'
require 'action_controller/test_case'
require 'action_view'
require 'active_record'
require 'ruby-debug'
require 'spamtrap'

ActiveRecord::Base.establish_connection(:adapter => 'sqlite3', :database => ':memory:')

ActiveRecord::Schema.define(:version => 1) do
  create_table :comments
end

class Comment < ActiveRecord::Base
end

class CommentsController < ActionController::Base
  spamtrap :create, :sarah_palin_walks_with_dinosaurs
end
