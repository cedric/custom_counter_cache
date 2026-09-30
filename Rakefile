require 'rake/testtask'
require_relative 'lib/custom_counter_cache/version'

namespace :gem do

  desc 'Run tests.'
  Rake::TestTask.new(:test) do |test|
    test.libs << 'lib' << 'test'
    test.pattern = 'test/**/*_test.rb'
    test.verbose = false
  end

  desc 'Build gem.'
  task build: :test do
    sh 'gem build custom_counter_cache.gemspec'
  end

  desc 'Build, tag and push gem.'
  task release: :build do
    # sh (not system) so a failed tag or push stops before publishing.
    sh "git tag v#{CustomCounterCache::VERSION}"
    sh 'git push origin --tags'
    sh "gem push custom_counter_cache-#{CustomCounterCache::VERSION}.gem"
  end

end

task default: 'gem:test'
