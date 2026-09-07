$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "tempfile"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "cybort"
require_relative "support/reddit_rss_fixture"
