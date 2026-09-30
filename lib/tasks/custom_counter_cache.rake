namespace :custom_counter_cache do
  desc 'Recount counter caches: MODEL=User [COUNTERS=articles_count,comments_count] [BATCH_SIZE=1000]'
  task recount: :environment do
    abort 'MODEL is required, e.g. MODEL=User' if ENV['MODEL'].to_s.empty?
    model = ENV['MODEL'].safe_constantize
    abort "#{ENV['MODEL']} is not a model with counter caches" unless model.respond_to?(:recount_counter_caches)

    names = ENV['COUNTERS'].to_s.split(',').map(&:strip).reject(&:empty?)
    batch_size = Integer(ENV.fetch('BATCH_SIZE', 1000))
    puts "Recounted #{model.recount_counter_caches(*names, batch_size: batch_size)} #{model} records"
  end
end
