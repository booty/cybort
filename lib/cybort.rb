module Cybort
  VERSION = "0.1.0"

  class ConfigurationError < StandardError; end
  class ValidationError < StandardError; end
  class SourceError < StandardError; end
end

require "cybort/configuration"
require "cybort/item"
require "cybort/fetch_result"
require "cybort/rate_limit_headers"
require "cybort/errors"
require "cybort/reddit_rate_limit_coordinator"
require "cybort/reddit_activity"
require "cybort/command_runner"
require "cybort/dependency"
require "cybort/dependency_checker"
require "cybort/schema"
require "cybort/persistence"
require "cybort/http_client"
require "cybort/reddit_client"
require "cybort/adapters/base"
require "cybort/adapters/rss"
require "cybort/adapters/github"
require "cybort/adapters/gmail"
require "cybort/adapters/reddit"
require "cybort/adapter_registry"
require "cybort/orchestrator"
require "cybort/installer"
require "cybort/cli"
