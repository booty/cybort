require "test_helper"

class HttpClientTest < Minitest::Test
  Response = Struct.new(:status, :headers, :body, keyword_init: true)

  class Transport
    attr_reader :calls

    def initialize(response)
      @response = response
      @calls = []
    end

    def get(url, headers:)
      @calls << [url, headers]
      @response
    end
  end

  class ExtendedTransport
    attr_reader :calls

    def initialize(response)
      @response = response
      @calls = []
    end

    def get(url, headers:, timeout_seconds: nil, deadline_monotonic: nil)
      @calls << {
        method: :get, url: url, headers: headers,
        timeout_seconds: timeout_seconds, deadline_monotonic: deadline_monotonic
      }
      @response
    end

    def post_form(url, form:, headers:, timeout_seconds: nil, deadline_monotonic: nil)
      @calls << {
        method: :post_form,
        url: url,
        form: form,
        headers: headers,
        timeout_seconds: timeout_seconds,
        deadline_monotonic: deadline_monotonic
      }
      @response
    end
  end

  class FakeClock
    attr_reader :now

    def initialize(now = 0.0)
      @now = now
    end

    def call
      @now
    end

    def advance(seconds)
      @now += seconds
    end
  end

  class StreamingResponse
    def initialize(clock, chunks)
      @clock = clock
      @chunks = chunks
    end

    def code
      "200"
    end

    def each_header
      {}.each
    end

    def read_body
      @chunks.each do |delay, chunk|
        @clock.advance(delay)
        yield chunk
      end
    end
  end

  class StreamingHttp
    attr_reader :start_options, :read_timeouts

    def initialize(response)
      @response = response
      @start_options = nil
      @read_timeouts = []
    end

    def start(_host, _port, **options)
      @start_options = options
      yield self
    end

    def request(_request)
      yield @response
    end

    def read_timeout=(value)
      @read_timeouts << value
    end
  end

  def test_delegates_url_and_headers_and_returns_response
    transport = Transport.new(Response.new(status: 200, headers: { "etag" => "abc" }, body: "body"))
    client = Cybort::HttpClient.new(transport: transport)

    response = client.get("https://example.test/feed", headers: { "X-Test" => "yes" })

    assert_equal "body", response.body
    assert_equal 200, response.status
    assert_equal [["https://example.test/feed", { "X-Test" => "yes" }]], transport.calls
  end

  def test_raises_source_error_for_non_success_response
    transport = Transport.new(Response.new(status: 503, headers: {}, body: "unavailable"))
    client = Cybort::HttpClient.new(transport: transport)

    error = assert_raises(Cybort::HttpError) do
      client.get("https://example.test/feed")
    end

    assert_includes error.message, "503"
  end

  def test_posts_form_with_a_per_call_timeout_without_putting_form_values_in_url
    transport = ExtendedTransport.new(Response.new(status: 200, headers: {}, body: "token"))
    client = Cybort::HttpClient.new(transport: transport)

    response = client.post_form(
      "https://www.reddit.com/api/v1/access_token",
      form: { grant_type: "refresh_token", refresh_token: "a+b secret" },
      headers: { "Authorization" => "Basic opaque" },
      timeout_seconds: 4.5
    )

    assert_equal "token", response.body
    call = transport.calls.last
    assert_equal :post_form, call.fetch(:method)
    assert_equal 4.5, call.fetch(:timeout_seconds)
    assert_nil call.fetch(:deadline_monotonic)
    assert_equal "a+b secret", call.fetch(:form).fetch(:refresh_token)
    refute_includes call.fetch(:url), "secret"
  end

  def test_forwards_an_optional_absolute_deadline
    transport = ExtendedTransport.new(Response.new(status: 200, headers: {}, body: "body"))
    client = Cybort::HttpClient.new(transport: transport)

    client.get("https://example.test/feed", deadline_monotonic: 123.5)

    assert_equal 123.5, transport.calls.last.fetch(:deadline_monotonic)
  end

  def test_rejects_a_response_body_over_the_configured_limit
    transport = ExtendedTransport.new(
      Response.new(status: 200, headers: {}, body: "x" * 11)
    )
    client = Cybort::HttpClient.new(transport: transport, max_response_body_bytes: 10)

    error = assert_raises(Cybort::HttpTransportError) do
      client.get("https://example.test/feed")
    end

    assert_equal({ category: :response_too_large }, error.safe_metadata)
    refute_includes error.message, "example.test"
  end

  def test_maps_timeout_failures_to_safe_transport_errors
    transport = ExtendedTransport.new(Response.new(status: 200, headers: {}, body: "body"))
    transport.define_singleton_method(:get) { |_url, **| raise Net::ReadTimeout, "secret URL" }
    client = Cybort::HttpClient.new(transport: transport)

    error = assert_raises(Cybort::HttpTransportError) do
      client.get("https://example.test/secret")
    end

    assert_equal({ category: :timeout }, error.safe_metadata)
    refute_includes error.message, "secret URL"
    refute_includes error.message, "example.test"
  end

  def test_maps_network_failures_to_safe_transport_errors
    network_errors = [EOFError.new("secret body"), IOError.new("secret body"), Net::HTTPBadResponse.new("secret body"), OpenSSL::SSL::SSLError.new("secret body"), SocketError.new("secret body")]

    network_errors.each do |failure|
      transport = ExtendedTransport.new(Response.new(status: 200, headers: {}, body: "body"))
      transport.define_singleton_method(:get) { |_url, **| raise failure }
      client = Cybort::HttpClient.new(transport: transport)

      error = assert_raises(Cybort::HttpTransportError) do
        client.get("https://example.test/secret")
      end

      assert_equal({ category: :network }, error.safe_metadata)
      refute_includes error.message, "secret body"
    end
  end

  def test_net_http_streaming_respects_one_absolute_deadline_across_chunks
    clock = FakeClock.new
    response = StreamingResponse.new(clock, [[0.4, "first"], [0.4, "second"], [0.4, "third"]])
    http = StreamingHttp.new(response)
    transport = Cybort::NetHttpTransport.new(
      http_class: http,
      monotonic_clock: clock.method(:call),
      read_timeout_seconds: 30
    )

    error = assert_raises(Cybort::HttpTransportError) do
      transport.get("https://example.test/stream", deadline_monotonic: 1.0)
    end

    assert_equal({ category: :timeout }, error.safe_metadata)
    assert_in_delta 1.2, clock.now, 0.000001
    assert_operator http.read_timeouts.length, :>=, 2
  end
end
