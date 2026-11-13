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

  describe 'Route#fill' do
    let(:user_class) { Struct.new(:login, :id) }

    def route_after(body)
      respond_with(body, 'application/json')
      endpoint = configure.things
      endpoint.run
      endpoint.route
    end

    it 'assigns the attributes of a JSON object to the given object' do
      user = route_after('{"login":"octocat","id":1}').fill(user_class.new)
      expect(user.login).to eq('octocat')
      expect(user.id).to eq(1)
    end

    it 'skips the keys the object has no writer for' do
      user = route_after('{"login":"octocat","unknown":true}').fill(user_class.new)
      expect(user.login).to eq('octocat')
    end

    it 'builds one object per element of a JSON array when given a class' do
      users = route_after('[{"login":"a"},{"login":"b"}]').fill(user_class)
      expect(users.map(&:login)).to eq(%w[a b])
      expect(users).to all(be_a(user_class))
    end

    it 'yields the object, the data and the status to a block' do
      yielded = nil
      route_after('{"login":"octocat"}').fill(user_class.new) { |object, data, status| yielded = [object, data, status] }
      expect(yielded[0].login).to eq('octocat')
      expect(yielded[1]).to eq('login' => 'octocat')
      expect(yielded[2].code).to eq(200)
    end
  end
end
