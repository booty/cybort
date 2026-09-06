class GmailHttpFixture
  attr_reader :calls

  def initialize(responses:)
    @responses = responses.dup
    @calls = []
  end

  def get(url, **options)
    record(:get, url, options)
  end

  def post_form(url, **options)
    record(:post_form, url, options)
  end

  private

  def record(method, url, options)
    @calls << { method: method, url: url }.merge(options)
    raise "unexpected fixture request" if @responses.empty?

    result = @responses.shift
    raise result if result.is_a?(Exception)

    result
  end
end
