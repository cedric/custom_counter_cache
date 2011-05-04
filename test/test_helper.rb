$: << File.join(File.dirname(__FILE__), '..', 'lib')
$: << File.join(File.dirname(__FILE__))

require 'rubygems'
require 'test/unit'
require 'active_support'
require 'action_controller'
require 'action_controller/test_case'
require 'action_view'
require 'active_record'
require 'custom_counter_cache'
