module Cybort
  VERSION = "0.1.0"

  class ConfigurationError < StandardError; end
  class ValidationError < StandardError; end
  class SourceError < StandardError; end
end

require "cybort/configuration"
require "cybort/item"
require "cybort/fetch_result"
