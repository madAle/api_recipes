require 'spec_helper'

describe 'Request options' do
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:url)  { "#{base_url}/things" }

  def configure(endpoint = {}, api = {})
    configure_test_apis(svc: { host: 'api.example.test' }.merge(api).merge(endpoints: { things: endpoint }))
    ApiRecipes.svc
  end

  describe 'verb' do
    %w[get post put patch delete head options].each do |verb|
      it "sends a #{verb.upcase} request" do
        stub_request(verb.to_sym, url).to_return(status: 200)
        configure(verb: verb).things.run
        expect(WebMock).to have_requested(verb.to_sym, url)
      end
    end

    it 'accepts the verb as a Symbol' do
      stub_request(:put, url).to_return(status: 200)
      configure(verb: :put).things.run
      expect(WebMock).to have_requested(:put, url)
    end

    it 'defaults to GET' do
      stub_request(:get, url).to_return(status: 200)
      configure.things.run
      expect(WebMock).to have_requested(:get, url)
    end
  end

  describe 'request parameters' do
    before { stub_request(:any, /api\.example\.test/).to_return(status: 200, body: '{}', headers: json) }

    it 'sends params as a query string' do
      configure.things(params: { q: 'ruby', page: 2 }).run
      expect(WebMock).to have_requested(:get, url).with(query: { 'q' => 'ruby', 'page' => '2' })
    end

    it 'sends json as a JSON body' do
      configure(verb: :post).things(json: { name: 'x', tags: %w[a b] }).run
      expect(WebMock).to have_requested(:post, url)
        .with(body: '{"name":"x","tags":["a","b"]}', headers: { 'Content-Type' => /application\/json/ })
    end

    it 'sends form as a form encoded body' do
      configure(verb: :post).things(form: { name: 'x' }).run
      expect(WebMock).to have_requested(:post, url)
        .with(body: 'name=x', headers: { 'Content-Type' => 'application/x-www-form-urlencoded' })
    end

    it 'sends body as it is' do
      configure(verb: :put).things(body: 'raw text').run
      expect(WebMock).to have_requested(:put, url).with(body: 'raw text')
    end

    it 'sends headers given with the request' do
      configure.things(headers: { 'X-Request-Id' => 'abc123' }).run
      expect(WebMock).to have_requested(:get, url).with(headers: { 'X-Request-Id' => 'abc123' })
    end

    it 'takes the options after the path parameters' do
      configure_test_apis(svc: { host: 'api.example.test', endpoints: { users: { endpoints: { show: { path: '/:id' } } } } })
      ApiRecipes.svc.users.show(7, params: { full: true }).run
      expect(WebMock).to have_requested(:get, "#{base_url}/users/7").with(query: { 'full' => 'true' })
    end

    it 'works with the block form too, which returns the endpoint' do
      code = nil
      result = configure.things(params: { page: 3 }) { |response| code = response.code }
      expect(code).to eq(200)
      expect(result).to be_a(ApiRecipes::Endpoint)
      expect(WebMock).to have_requested(:get, url).with(query: { 'page' => '3' })
    end
  end

  describe 'headers' do
    before { stub_request(:get, url).to_return(status: 200, body: '{}', headers: json) }

    it 'sends the default headers of the api' do
      configure({}, default_headers: { 'Accept' => 'application/json', 'User-Agent' => 'my-app' }).things.run
      expect(WebMock).to have_requested(:get, url)
        .with(headers: { 'Accept' => 'application/json', 'User-Agent' => 'my-app' })
    end

    it 'lets a request header replace a default header' do
      configure({}, default_headers: { 'Accept' => 'application/json' })
        .things(headers: { 'Accept' => 'text/plain' }).run
      expect(WebMock).to have_requested(:get, url).with(headers: { 'Accept' => 'text/plain' })
    end

    it 'adds the default headers a class declares to those of the api' do
      configure({}, default_headers: { 'Accept' => 'application/json' })
      klass = Class.new do
        include ApiRecipes
        api :svc, default_headers: { 'Authorization' => 'Bearer class-token' }
      end
      klass.svc.things.run
      expect(WebMock).to have_requested(:get, url)
        .with(headers: { 'Accept' => 'application/json', 'Authorization' => 'Bearer class-token' })
    end
  end

  describe 'authorization' do
    before { stub_request(:get, url).to_return(status: 200, body: '{}', headers: json) }

    it 'sends no Authorization header when no credentials are set' do
      configure.things.run
      expect(WebMock).to(have_requested(:get, url).with { |request| !request.headers.key?('Authorization') })
    end

    it 'sends the authorization of the global api' do
      configure
      ApiRecipes.svc.authorization = 'Bearer token'
      ApiRecipes.svc.things.run
      expect(WebMock).to have_requested(:get, url).with(headers: { 'Authorization' => 'Bearer token' })
    end

    it 'sends the basic auth of the global api' do
      configure
      ApiRecipes.svc.basic_auth = { user: 'me', pass: 'secret' }
      ApiRecipes.svc.things.run
      expect(WebMock).to have_requested(:get, url).with(headers: { 'Authorization' => 'Basic bWU6c2VjcmV0' })
    end

    it 'lets a request header replace the authorization of the api' do
      configure
      ApiRecipes.svc.authorization = 'Bearer global'
      ApiRecipes.svc.things(headers: { 'Authorization' => 'Bearer user' }).run
      expect(WebMock).to have_requested(:get, url).with(headers: { 'Authorization' => 'Bearer user' })
    end
  end

  describe 'timeout' do
    # The client is built when the request is sent.
    before { stub_request(:get, url).to_return(status: 200, body: '{}', headers: json) }

    # The value reaches http.rb through HTTP::Client#timeout.
    def expect_timeout(seconds)
      expect_any_instance_of(HTTP::Client).to receive(:timeout).with(seconds).and_call_original
    end

    it 'is 3 seconds by default' do
      svc = configure
      expect_timeout(3)
      svc.things.run
    end

    it 'takes the value of the api' do
      svc = configure({}, timeout: 10)
      expect_timeout(10)
      svc.things.run
    end

    it 'takes the value of the endpoint over that of the api' do
      svc = configure({ timeout: 1 }, timeout: 10)
      expect_timeout(1)
      svc.things.run
    end

    it 'takes the value a class gives to api' do
      configure
      klass = Class.new do
        include ApiRecipes
        api :svc, timeout: 10
      end
      expect_timeout(10)
      klass.svc.things.run
    end

    it 'raises HTTP::TimeoutError when the request times out' do
      stub_request(:get, url).to_timeout
      expect { configure.things.run }.to raise_error(HTTP::TimeoutError)
    end
  end
end
