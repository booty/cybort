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
  lib/cybort/apple_health_archive_acquirer.rb
  lib/cybort/apple_health_canonical.rb
  lib/cybort/apple_health_error.rb
  lib/cybort/apple_health_export_parser.rb
  lib/cybort/apple_health_zip.rb
  lib/cybort/adapters/apple_health.rb
].freeze

desc "Run the staged correctness and performance lint baseline"
task :quality do
  sh "bundle exec rubocop --config .rubocop.yml --only Lint,Security,Performance #{QUALITY_FILES.join(" ")}"
end

task default: :test
