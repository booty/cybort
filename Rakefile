require "rake/testtask"

Rake::TestTask.new(:test) do |task|
  task.libs << "lib" << "test"
  task.pattern = "test/**/*_test.rb"
end

QUALITY_FILES = %w[
  lib/cybort/configuration.rb
  lib/cybort/http_client.rb
  lib/cybort/reddit_client.rb
  lib/cybort/reddit_rate_limit_coordinator.rb
  lib/cybort/adapters/gmail.rb
].freeze

desc "Run the staged correctness and performance lint baseline"
task :quality do
  sh "bundle exec rubocop --config .rubocop.yml --only Lint,Security,Performance #{QUALITY_FILES.join(" ")}"
end

task default: :test
