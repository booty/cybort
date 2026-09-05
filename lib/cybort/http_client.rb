require "net/http"
require "uri"

module Cybort
  HttpResponse = Struct.new(:status, :headers, :body, keyword_init: true)

  class HttpClient
    DEFAULT_OPEN_TIMEOUT_SECONDS = 10
    DEFAULT_READ_TIMEOUT_SECONDS = 30
    DEFAULT_WRITE_TIMEOUT_SECONDS = 30
    DEFAULT_MAX_RESPONSE_BODY_BYTES = 1_048_576

    def initialize(transport: nil,
                   open_timeout_seconds: DEFAULT_OPEN_TIMEOUT_SECONDS,
                   read_timeout_seconds: DEFAULT_READ_TIMEOUT_SECONDS,
                   write_timeout_seconds: DEFAULT_WRITE_TIMEOUT_SECONDS,
                   max_response_body_bytes: DEFAULT_MAX_RESPONSE_BODY_BYTES)
      @open_timeout_seconds = positive_number(open_timeout_seconds, :open_timeout_seconds)
      @read_timeout_seconds = positive_number(read_timeout_seconds, :read_timeout_seconds)
      @write_timeout_seconds = positive_number(write_timeout_seconds, :write_timeout_seconds)
      @max_response_body_bytes = positive_integer(max_response_body_bytes, :max_response_body_bytes)
      @transport = transport || NetHttpTransport.new(
        open_timeout_seconds: @open_timeout_seconds,
        read_timeout_seconds: @read_timeout_seconds,
        write_timeout_seconds: @write_timeout_seconds,
        max_response_body_bytes: @max_response_body_bytes
      )
    end

    def get(url, headers: {}, timeout_seconds: nil)
      response = invoke(:get, url, headers: headers, timeout_seconds: timeout_seconds)
      response = normalize_response(response)
      raise HttpTransportError.new(category: :response_too_large) if response.body.bytesize > @max_response_body_bytes

      status = response.status.to_i
      raise HttpError.new(status: status, headers: response.headers) unless status.between?(200, 299)

      response
    rescue HttpError, HttpTransportError
      raise
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error
      raise HttpTransportError.new(category: :timeout)
    end

    def post_form(url, form:, headers: {}, timeout_seconds: nil)
      response = invoke(:post_form, url, form: form, headers: headers, timeout_seconds: timeout_seconds)
      response = normalize_response(response)
      raise HttpTransportError.new(category: :response_too_large) if response.body.bytesize > @max_response_body_bytes

      status = response.status.to_i
      raise HttpError.new(status: status, headers: response.headers) unless status.between?(200, 299)

      response
    rescue HttpError, HttpTransportError
      raise
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error
      raise HttpTransportError.new(category: :timeout)
    end

    private

    def invoke(method, url, headers:, timeout_seconds:, form: nil)
      timeout_seconds = positive_number(timeout_seconds, :timeout_seconds) unless timeout_seconds.nil?
      arguments = { headers: headers }
      arguments[:timeout_seconds] = timeout_seconds unless timeout_seconds.nil?
      arguments[:form] = form unless form.nil?
      @transport.public_send(method, url, **arguments)
    rescue NoMethodError => error
      raise unless error.name == method

      raise HttpTransportError.new(category: :network)
    end

    def normalize_response(response)
      body = response.body.to_s
      HttpResponse.new(status: response.status.to_i, headers: response.headers || {}, body: body)
    rescue NoMethodError
      raise HttpTransportError.new(category: :network)
    end

    def positive_number(value, name)
      number = Float(value)
      raise ArgumentError, "#{name} must be positive and finite" unless number.finite? && number.positive?

      number
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{name} must be positive and finite"
    end

    def positive_integer(value, name)
      number = Integer(value)
      raise ArgumentError, "#{name} must be a positive integer" unless number.positive?

      number
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{name} must be a positive integer"
    end
  end

  class NetHttpTransport
    def initialize(open_timeout_seconds: HttpClient::DEFAULT_OPEN_TIMEOUT_SECONDS,
                   read_timeout_seconds: HttpClient::DEFAULT_READ_TIMEOUT_SECONDS,
                   write_timeout_seconds: HttpClient::DEFAULT_WRITE_TIMEOUT_SECONDS,
                   max_response_body_bytes: HttpClient::DEFAULT_MAX_RESPONSE_BODY_BYTES)
      @open_timeout_seconds = positive_number(open_timeout_seconds)
      @read_timeout_seconds = positive_number(read_timeout_seconds)
      @write_timeout_seconds = positive_number(write_timeout_seconds)
      @max_response_body_bytes = positive_integer(max_response_body_bytes)
    end

    def get(url, headers: {}, timeout_seconds: nil)
      request(:get, url, headers: headers, timeout_seconds: timeout_seconds)
    end

    def post_form(url, form:, headers: {}, timeout_seconds: nil)
      headers = headers.dup
      headers["Content-Type"] ||= "application/x-www-form-urlencoded"
      request(
        :post,
        url,
        headers: headers,
        body: URI.encode_www_form(form),
        timeout_seconds: timeout_seconds
      )
    end

    private

    def request(method, url, headers:, body: nil, timeout_seconds: nil)
      uri = URI.parse(url)
      request_class = method == :post ? Net::HTTP::Post : Net::HTTP::Get
      request = request_class.new(uri)
      headers.each { |name, value| request[name] = value }
      request.body = body unless body.nil?
      timeout_options = {
        open_timeout: capped_timeout(@open_timeout_seconds, timeout_seconds),
        read_timeout: capped_timeout(@read_timeout_seconds, timeout_seconds),
        write_timeout: capped_timeout(@write_timeout_seconds, timeout_seconds)
      }
      response_payload = nil
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", **timeout_options) do |http|
        http.request(request) do |streamed_response|
          response_body = +""
          streamed_response.read_body do |chunk|
            if response_body.bytesize + chunk.bytesize > @max_response_body_bytes
              raise HttpTransportError.new(category: :response_too_large)
            end

            response_body << chunk
          end
          response_payload = HttpResponse.new(
            status: streamed_response.code.to_i,
            headers: streamed_response.each_header.to_h,
            body: response_body
          )
        end
      end
      response_payload
    rescue HttpTransportError
      raise
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error
      raise HttpTransportError.new(category: :timeout)
    rescue URI::InvalidURIError, SocketError, SystemCallError
      raise HttpTransportError.new(category: :network)
    end

    def capped_timeout(default, requested)
      return default if requested.nil?

      timeout = positive_number(requested)
      [default, timeout].min
    end

    def positive_number(value)
      number = Float(value)
      raise ArgumentError unless number.finite? && number.positive?

      number
    rescue ArgumentError, TypeError
      raise ArgumentError, "HTTP timeout must be positive and finite"
    end

    def positive_integer(value)
      number = Integer(value)
      raise ArgumentError unless number.positive?

      number
    rescue ArgumentError, TypeError
      raise ArgumentError, "maximum response body must be a positive integer"
    end
  end
end
