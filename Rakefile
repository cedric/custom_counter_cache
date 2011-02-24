$LOAD_PATH.unshift File.expand_path('../lib', __FILE__)
require 'rake/testtask'
require 'lib/custom_counter_cache/version'

namespace :gem do

  desc 'Run tests.'
  Rake::TestTask.new(:test) do |test|
    test.libs << 'lib' << 'test'
    test.pattern = 'test/**/*_test.rb'
    test.verbose = true
  end

  desc 'Build gem.'
  task :build => :test do
    system "gem build custom_counter_cache.gemspec"
  end

  desc 'Build, tag and push gem.'
  task :release => :build do
    # tag and push
    system "git tag v#{CustomCounterCache::VERSION}"
    system "git push origin --tags"
    # push gem
    system "gem push custom_counter_cache-#{CustomCounterCache::VERSION}.gem"
  end

end

task :default => 'gem:test'