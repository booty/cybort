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

    error = assert_raises(Cybort::SourceError) do
      client.get("https://example.test/feed")
    end

    assert_includes error.message, "503"
  end
end

