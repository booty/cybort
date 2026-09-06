# Cybort

Cybort is a personal information collector, filterer, and insight-generator.

It's job is to help John deal with a deluge of information from various sources.

## Audience

This is a personal app for John. He is the only developer and user as of this time. Work on a single branch, `main`, unless told otherwise.

Stated goals are not hard requirements. We have no external stakeholders, etc. Masters of our own destiny.

## Project Structure

- lib/cybort.rb
  - lib/adapters
    - base_adapter.rb (abstract base class)
    - reddit.rb
    - twitter.rb
    - gmail.rb
    - slack.rb
    - apple_health.rb
    - github.rb
    - apple_music.rb
    - rss.rb
    - weather.rb
    - linear.rb
    - news.rb
    - etc

## Broad Architecture Goals

Primary Goals:
- simple and lean: It should be simple to read, maintain, and extend. Generally speaking, less code = better
- idiomatic: Follow Ruby conventions and best practices
- concurrent: Should fetch data from multiple local and remote courses simultaneously
- correct: it should work, obviously
- don't reinvent wheel: we can be flexible with our design. we are the the only user and only developer. no outside stakeholders. if there's an existing library or gem that does *almost* what we want, it may be worth deviating from our stated design goals if there is an existing near-plug-and-play solution... we should talk it out.

Secondary Goals:
- performance: should be fast

DO NOT "OVERENGINEER" If you find yourself struggling or feeling you need more than ~100 LOC per file, STOP and let's talk it out.

We can trade some performance for simplicity

"Don't reinvent the wheel" extends to the usage of common command line utilities. Are we implementing pure-Ruby versions of functionality that already exists in tools like `rg`, `jq`, etc? If so, let's just use them and name them as dependencies. We should ensure they are present at startup and give the user steps to install them if not found.



## Architecture Non-Goals

For now, we don't need scheduled fetches via systemd or cron jobs.

We don't need total ACID compliance. We mostly need to make sure that things run "fast enough" and that we don't corrupt our datastore.

## Commit Cycle

If doing hacks, kludges or any other unintuitive things

After staging a commit, consider: does README.md, AGENTS.md, or any other metadata file need updating?

## cybort.rb

Initializes datastore if needed, if specified via invocation

Iterates over configured adapters and instances in the config file

Concatenates their output into a single JSON file or stream like the following:

```json
{
  "info": { ... },
  "instances": {
    "John's Home Gmail": {
      "adapter": "gmail",
      "last_successful_fetch": "2026-08-16T10:10:08-12:00 UTC−12:00",
      "errors": {
        "2026-08-16T10:10:08-11:00 UTC−12:00": "hostname not found",
      },
      "items": [],
    },
    "John's Work Gmail": {
      "adapter": "gmail",
      "last_successful_fetch": "2026-08-16T10:10:08-13:00 UTC−12:00",
      "errors": [],
      "items": [],
    },
    "Slack": {
      "adapter": "slack",
      "last_successful_fetch": "2026-08-16T10:10:08-12:00 UTC−12:00",
      "errors": [],
      "items": [],
    },
  }

}
```


## Model: "Adapter"

An adapter is a Ruby module like "gmail.rb" or "slack.rb" that knows how to fetch and store information from a single source.

There may be multiple instances of each adapter specified in the configuration file. For example, a user may have 3 Gmail accounts and 4 Github accounts.

REQUIREMENT: All adapter instances will be queried concurrently via ractors or threads. If there are 3 Gmail accounts and 5 Slack workspaces, we will launch 8 ractors/threads. Potentially these might all do concurrent remote fetches and writes to local storage. We must make sure concurrent writers don't corrupt our data store. However, some latency is fine. The write locks will be brief, so it's no big deal if ractor/thread 123 has to wait for ractor/thread 122.


```ruby
# lib/adapters/base_adapter.rb
class base_adapter
  def initialize(ttl_minutes:, configuration:)
    # raise unless ttl_minutes and num_items_to_return have been supplied
    # raise unless `configuration` contains all the keys in @@required_configuration_keys
  end

  def fetch_from_disk_or_source()
    # If force_fetch_from_source is true, or the age of data on disk has exceeded ttl_minutes, perform a fetch_from_source
    fetch_from_disk(num_items:)
  end

  def fetch_from_disk()
    # Should be ultra fast. Fetch cached data from disk
    # Returns JSON
  end

  def fetch_from_source()
    # Perform longer work like fetching from a remote API, etc
    # Writes data to disk in JSON format
  end

  def canonical_id_for_item(item:)
    # returns a canonical id that is unique for this item for the current adapter instance
    # ideally, this is provided by the remote source
    # alternatively, we could synthesize one as a fallback
    #   example: suppose an RSS feed does not supply a canonical article ID.
    #   we could use a fallback of `sha256(published_at)` or something
    #   implementation will vary by adapter
  end
end

# Example adapter: gmail
# lib/adapters/gmail.rb
class gmail
  @@required_configuration_keys = ["api_login", "api_key"]

  def initialize(ttl_minutes:, configuration:)
    super
    # any other initialization work required
  end

  def fetch_from_disk_or_source(num_items:, :force_fetch_from_source = false)
    # If force_fetch_from_source is true, or the age of data on disk has exceeded ttl_minutes, perform a fetch_from_source
    # Then, fetch from disk
  end

  def fetch_from_disk(num_items:)
    # Should be ultra fast. Fetch cached data from disk
    # Returns JSON
  end

  def fetch_from_source(num_items:)
    # Perform longer work like fetching from a remote API, etc
    # Writes data to disk in JSON format
  end

  def canonical_id_for_item(item:)
    # example: item.id || md5("#{item.title[0..3]}#{item.created_at}")
  end
end
```

## Adapter Remote Fetch History Log

We should store a log for each adapter, with a history of successful and unsuccessful remote fetches and other optional debugging information.

- Purposes
  - Debugging aid
  - Allows us to calculate exponential backoffs for external sources
  - Lets us know how fresh the data is

## Configuration File Format

Configuration is stored in ~/.cybort/cybort.toml

In this case, the user has 4 instances defined. Two instances use the same adapter (gmail).

```toml
schema_version=1

# These are sample key/value pairs; key names may vary greatly

[John's Personal Gmail] # friendly name
adapter = "gmail"
api_login = "ABC"
api_key = "123"
num_items = 25
ttl_minutes = 60

[John's Work Gmail]
adapter = "gmail"
api_login = "DEF"
api_key = "756"
ttl_minutes = 30
num_items = 10

[Hacker News]
adapter = "rss"
url = "http://foo/bar.rss"
num_items = 25

[John's Personal Github]
adapter = "github"
login = "somebody"
key = "foobar"
num_items = 100
```

## Model: "Item"

An `Item` is a unit of data returned by an adapter.

Examples of an item:
- One email fetched from Gmail
- One article link from an RSS feed
- One github notification

### Item Attributes:

- adapter_name (required)
  - name of the adapter, e.g. "github" or "rss"
- canonical_id (required)
  - this could be a GUID, canonical URL, or something else returned by a remote source
  - these must be unique per adapter/instance pair
  - however they may not be unique globally
    - example: two articles fetched from two different `rss` feeds might both have an ID of 12345
  - used for deduplication
  - must be filesystem name safe
- urls
  - array of strings
  - most will have 0 or 1 urls, but some may have multiple
    - example: a Hacker News item might have URL linking to the linked article, and another URL linking to the HN discussion
- fetched_at (required)
  - the local timestamp at which the item was fetched (UTC)
- remote_created_at
  - if available, the creation time of the remote item
- title (required)
  - examples: the title of an RSS article, or an email subject
- body
  - examples: the body of an email
- priority
  - integer between 0 (lowest) and 100 (highest)
- action_item?
  - true if this requires action by the user
- info
  - a hash or JSON object of optional supplemental metadata that is not shared by enough adapters to warrant its own column


## Commands

- `cybort [--force-fetch]`
  - Has ~/.cybort has been initialized?
    - No: prompt the user to run `cybort init`
    - Yes: is --force-fetch supplied?
      - No: return cached information from each configured input source
      - Yes: ignore TTLs, fetch everything
- `cybort init [location]`
  - Default location is ~/.cybort
  - If an existing installation is found in [location]
    - ask the user what they want to do
      - back up the current install, keep config.toml, reset everything else? (DEFAULT)
      - back up the current install, reset everything else?
      - nuke the current install without backup?
        - ask them a second confirmation if this is chosen?
    - if backing up current install, just .zip/tar.gz it and give it a timestampped filename


## Open Architecture Questions

- Threads or ractors?
- What should we use for a datastore? Options:
  - One sqlite database for everything
    - Pros:
      - Relational joins on reads are trivial
    - Cons:
      - Must manage concurrency issues w.r.t. multiple writers?
        - Perhaps this is not a problem?
          - We'll never have more than a handful of writers
          - The write locks they hold will be brief
          - It's okay if writer A waits a little bit for writer B
  - One sqlite database per adapter
    - Pros:
      - Must use `ATTACH_DATABASE` so relational joins on reads take slightly more work, but still easy
      - We don't have to worry about multiple concurrent writers
  - One JSON/JSONL file per adapater/instance, plus JSON/JSONL debug logs
    - Pros:
      - Trivially human readable
      - No concurrent write issues
    - Cons:
      - Can't trivially do cross-database relational stuff
        - HOWEVER, not sure we'll need that... future use
      - Manual log rotation & stale item trimming is more work than simple SQLite delete statements
        - Though, perhaps ruby logging libraries handle this?
  - One JSON file per adapter item
    - Pros:
      - If we name files by timestamp, the filesystem itself is the index
    - Cons:
      - Some adapters might have thousands of items (e.g. gmail)
      - The other cons of "One JSON/JSONL file per adapater/instance, plus JSON/JSONL debug logs" apply here too

## Future Plans

- Periodic scheduled fetches
- LLM summarization / classification
- Deeper LLM-powered insights spanning multiple data sources
- Consumable via LLM via MCP or similar
- HTML dashboard
