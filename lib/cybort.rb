module Cybort
  VERSION = "0.1.0"

  class ConfigurationError < StandardError; end
  class ValidationError < StandardError; end
  class SourceError < StandardError; end
end

require "cybort/configuration"
require "cybort/item"
require "cybort/fetch_result"
require "cybort/schema"
require "cybort/persistence"
require "cybort/http_client"
require "cybort/adapters/base"
require "cybort/adapters/rss"
require "cybort/adapter_registry"
require "cybort/orchestrator"
require "cybort/cli"
