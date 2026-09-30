require_relative 'lib/custom_counter_cache/version'

Gem::Specification.new do |s|
  s.name = 'custom_counter_cache'
  s.version = CustomCounterCache::VERSION
  s.license = 'MIT'
  s.authors = 'Cedric Howe'
  s.email = 'cedric@howe.net'
  s.homepage = 'https://github.com/cedric/custom_counter_cache'
  s.summary = 'Custom counter_cache functionality that supports conditions and multiple models.'
  s.description = 'Define counter caches computed by an arbitrary block (e.g. a scoped count), ' \
                  'refreshed by callbacks on any number of associated models, and stored in a ' \
                  'column or a shared polymorphic counters table.'
  s.metadata = {
    'source_code_uri' => 'https://github.com/cedric/custom_counter_cache',
    'changelog_uri' => 'https://github.com/cedric/custom_counter_cache/blob/main/CHANGELOG.md',
    'rubygems_mfa_required' => 'true',
  }
  s.files = Dir['lib/**/*.rb', 'lib/**/*.rake', 'LICENSE', 'README.md', 'CHANGELOG.md']
  s.required_ruby_version = '>= 3.3'
  s.add_dependency('activerecord', '>= 8.0', '< 9.0')
  s.add_dependency('activesupport', '>= 8.0', '< 9.0')
  s.add_development_dependency('activejob', '>= 8.0', '< 9.0')
  s.add_development_dependency('discard', '~> 2.0')
  s.add_development_dependency('minitest', '>= 5.0', '< 7')
  s.add_development_dependency('paranoia', '~> 3.1')
  s.add_development_dependency('rake', '~> 13.0')
  s.add_development_dependency('sqlite3', '~> 2.0')
end
