require "net/http"
require "uri"

module Cybort
  HttpResponse = Struct.new(:status, :headers, :body, keyword_init: true)

  class HttpClient
    def initialize(transport: NetHttpTransport.new)
      @transport = transport
    end

    def get(url, headers: {})
      response = @transport.get(url, headers: headers)
      status = response.status.to_i
      raise SourceError, "HTTP request failed with status #{status}" unless status.between?(200, 299)

      HttpResponse.new(status: status, headers: response.headers, body: response.body)
    end
  end

  class NetHttpTransport
    def get(url, headers: {})
      uri = URI.parse(url)
      request = Net::HTTP::Get.new(uri)
      headers.each { |name, value| request[name] = value }
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(request)
      end
      HttpResponse.new(
        status: response.code.to_i,
        headers: response.each_header.to_h,
        body: response.body
      )
    rescue URI::InvalidURIError, SocketError, SystemCallError => error
      raise SourceError, error.message
    end
  end
end

