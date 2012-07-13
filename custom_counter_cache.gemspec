# -*- encoding: utf-8 -*-
lib = File.expand_path('../lib/', __FILE__)
$:.unshift lib unless $:.include?(lib)
require 'custom_counter_cache/version'

spec = Gem::Specification.new do |s|
  s.name = 'custom_counter_cache'
  s.version = CustomCounterCache::VERSION
  s.platform = Gem::Platform::RUBY
  s.author = 'Cedric Howe'
  s.email = 'cedric@freezerbox.com'
  s.homepage = 'http://github.com/cedric/custom_counter_cache/'
  s.summary = 'Custom counter_cache functionality that supports conditions and multiple models.'
  s.description = ''
  s.require_paths = ['lib']
  s.files = Dir['lib/**/*.rb']
  s.required_rubygems_version = '>= 1.3.6'
  s.add_dependency('rails', '>= 2.3')
  s.add_development_dependency('sqlite3-ruby')
  s.add_development_dependency('debugger')
  s.test_files = Dir['test/**/*.rb']
  s.rubyforge_project = 'custom_counter_cache'
  s.has_rdoc = true
end
