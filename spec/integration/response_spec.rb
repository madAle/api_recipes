require 'spec_helper'

describe ApiRecipes::Response do
  let(:url) { "#{base_url}/things" }

  def configure(endpoint = {}, api = {})
    configure_test_apis(svc: { host: 'api.example.test' }.merge(api).merge(endpoints: { things: endpoint }))
    ApiRecipes.svc
  end

  def respond_with(body, content_type, status = 200)
    stub_request(:get, url).to_return(status: status, body: body, headers: { 'Content-Type' => content_type })
  end

  it 'is what run returns' do
    respond_with('{}', 'application/json')
    expect(configure.things.run).to be_a(described_class)
  end

  it 'parses a JSON object' do
    respond_with('{"login":"octocat","id":1}', 'application/json')
    expect(configure.things.run.data).to eq('login' => 'octocat', 'id' => 1)
  end

  it 'parses a JSON array' do
    respond_with('[{"id":1},{"id":2}]', 'application/json; charset=utf-8')
    expect(configure.things.run.data).to eq([{ 'id' => 1 }, { 'id' => 2 }])
  end

  it 'parses the body only once' do
    respond_with('{"id":1}', 'application/json')
    response = configure.things.run
    expect(response.original_response).to receive(:parse).once.and_call_original
    2.times { response.data }
  end

  it 'gives access to status, headers and body of the http.rb response' do
    respond_with('{"id":1}', 'application/json', 201)
    response = configure(ok_code: 201).things.run

    expect(response.code).to eq(201)
    expect(response.status.success?).to eq(true)
    expect(response.headers['Content-Type']).to eq('application/json')
    expect(response.body.to_s).to eq('{"id":1}')
    expect(response.original_response).to be_a(HTTP::Response)
  end

  describe 'with a content type that is not JSON' do
    before { respond_with('{"id":1}', 'text/plain') }

    it 'cannot parse data, but the body is available' do
      response = configure.things.run
      expect { response.data }.to raise_error(HTTP::Error)
      expect(response.body.to_s).to eq('{"id":1}')
    end

    it 'parses data with the mime_type of the endpoint' do
      expect(configure(mime_type: 'application/json').things.run.data).to eq('id' => 1)
    end

    it 'parses data with the mime_type of the api' do
      expect(configure({}, mime_type: 'application/json').things.run.data).to eq('id' => 1)
    end
  end

  it 'cannot parse data when the body is empty' do
    stub_request(:get, url).to_return(status: 204, body: '')
    response = configure.things.run
    expect { response.data }.to raise_error(HTTP::Error)
    expect(response.body.to_s).to eq('')
  end

  describe '#fill' do
    let(:user_class) { Struct.new(:login, :id) }

    def response_for(body)
      respond_with(body, 'application/json')
      configure.things.run
    end

    it 'assigns the attributes of a JSON object to the given object' do
      user = response_for('{"login":"octocat","id":1}').fill(user_class.new)
      expect(user.login).to eq('octocat')
      expect(user.id).to eq(1)
    end

    it 'skips the keys the object has no writer for' do
      user = response_for('{"login":"octocat","unknown":true}').fill(user_class.new)
      expect(user.login).to eq('octocat')
    end

    it 'builds one object per element of a JSON array when given a class' do
      users = response_for('[{"login":"a"},{"login":"b"}]').fill(user_class)
      expect(users.map(&:login)).to eq(%w[a b])
      expect(users).to all(be_a(user_class))
    end

    it 'yields the object, the data and the status to a block' do
      yielded = nil
      response_for('{"login":"octocat"}').fill(user_class.new) { |object, data, status| yielded = [object, data, status] }
      expect(yielded[0].login).to eq('octocat')
      expect(yielded[1]).to eq('login' => 'octocat')
      expect(yielded[2].code).to eq(200)
    end

    it 'lets an error raised by a setter through' do
      strict = Class.new do
        def login=(_value)
          raise ArgumentError, 'no'
        end
      end
      expect { response_for('{"login":"x"}').fill(strict.new) }.to raise_error(ArgumentError, 'no')
    end
  end

  it 'tells what it can do' do
    respond_with('{"id":1}', 'application/json')
    response = configure.things.run
    expect(response).to respond_to(:code, :status, :headers, :body, :data, :fill, :success?)
    expect(response).not_to respond_to(:request)
    expect(response.inspect).to eq('#<ApiRecipes::Response 200 OK application/json>')
  end

  it 'says whether the response passed the rule of the endpoint' do
    respond_with('', 'text/plain', 500)
    expect(configure(on_bad_code: 'ignore').things.run.success?).to eq(false)
  end

  describe '#uri' do
    def build(url, **options)
      request = HTTP::Request.new(verb: :get, uri: url)
      http = HTTP::Response.new(status: 200, version: '1.1', body: '', request: request)
      described_class.new(http, **options)
    end

    it 'returns the uri of the http.rb response when no parameter is hidden' do
      expect(build("#{base_url}/a?k=1&x=2").uri.to_s).to eq("#{base_url}/a?k=1&x=2")
    end

    it 'removes only the hidden query parameter' do
      expect(build("#{base_url}/a?k=1&x=2&y=a%20b", hidden_param: 'k').uri.to_s).to eq("#{base_url}/a?x=2&y=a%20b")
    end

    it 'drops the query when the hidden parameter is the only one' do
      expect(build("#{base_url}/a?k=1", hidden_param: :k).uri.to_s).to eq("#{base_url}/a")
    end

    it 'leaves a uri without that parameter alone' do
      expect(build("#{base_url}/a?x=2", hidden_param: 'k').uri.to_s).to eq("#{base_url}/a?x=2")
    end
  end
end
