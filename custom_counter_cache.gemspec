# -*- encoding: utf-8 -*-
$LOAD_PATH << File.dirname(__FILE__) + '/lib'
require 'custom_counter_cache/version'

spec = Gem::Specification.new do |s|
  s.name = 'custom_counter_cache'
  s.version = CustomCounterCache::VERSION
  s.platform = Gem::Platform::RUBY
  s.license = 'MIT'
  s.authors = 'Cedric Howe'
  s.email = 'cedric@howe.net'
  s.homepage = 'http://github.com/cedric/custom_counter_cache/'
  s.summary = 'Custom counter_cache functionality that supports conditions and multiple models.'
  s.description = ''
  s.require_paths = ['lib']
  s.files = Dir['lib/**/*.rb']
  s.required_rubygems_version = '>= 1.3.6'
  s.add_dependency('rails', RUBY_VERSION < '1.9.3' ? '~> 3.1' : '>= 3.1')
  s.add_development_dependency('sqlite3')
  s.add_development_dependency('minitest')
  s.test_files = Dir['test/**/*.rb']
  s.rubyforge_project = 'custom_counter_cache'
end
