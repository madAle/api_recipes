require 'spec_helper'

describe ApiRecipes::Request do
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:base) { { host: 'api.example.test', endpoints: { users: { endpoints: { show: { path: '/:id' } } }, group: { route: false } } } }

  before { stub_request(:any, /api\.example\.test/).to_return(status: 200, body: '{}', headers: json) }

  it 'builds the url only, without a query' do
    request = new_request(base, %i[users show], [7], options: { params: { a: 1 } })
    expect(request.url).to be_a(URI::HTTPS)
    expect(request.url.to_s).to eq('https://api.example.test/users/7')
    expect(WebMock).not_to have_requested(:any, /example/)
  end

  it 'has no url and cannot run without a route' do
    request = new_request(base, %i[group])
    expect(request.url).to be_nil
    expect { request.perform }.to raise_error(ApiRecipes::NoRouteExists)
  end

  it 'accepts underscores in the host with any uri gem' do
    request = new_request({ protocol: 'http', host: 'web_service_1', port: 3000, endpoints: { ping: nil } }, %i[ping])
    expect(request.url.to_s).to eq('http://web_service_1:3000/ping')
  end

  it 'accepts a list of ok codes' do
    config = base.merge(endpoints: { users: { ok_code: [200, 202] } })
    stub_request(:get, 'https://api.example.test/users').to_return(status: 202)
    expect(new_request(config, %i[users]).perform.success?).to eq(true)
    stub_request(:get, 'https://api.example.test/users').to_return(status: 201)
    expect { new_request(config, %i[users]).perform }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected)
  end

  it 'puts the credential where auth says' do
    ApiRecipes::LevelSet.write(ApiRecipes, :svc) { |l| l.with(credential: ApiRecipes::Credential.authorization('KEY')) }
    new_request(base.merge(auth: { type: 'header', name: 'X-Api-Key' }), %i[users]).perform
    expect(WebMock).to have_requested(:get, 'https://api.example.test/users').with(headers: { 'X-Api-Key' => 'KEY' })
    request = new_request(base.merge(auth: { type: 'query', name: 'api_key' }), %i[users], options: { params: { page: 2 } })
    response = request.perform
    expect(WebMock).to have_requested(:get, 'https://api.example.test/users').with(query: { 'api_key' => 'KEY', 'page' => '2' })
    expect(request.url.to_s).not_to include('KEY')
    expect(response.uri.to_s).not_to include('KEY')
    expect(response.inspect).not_to include('KEY')
  end

  it 'sends basic_auth, but not where auth wants a header or a query' do
    basic = { basic_auth: { user: 'u', pass: 'p' } }
    new_request(base, %i[users], overrides: basic).perform
    expect(WebMock).to have_requested(:get, 'https://api.example.test/users').with(basic_auth: %w[u p])
    %w[header query].each do |type|
      request = new_request(base.merge(auth: { type: type, name: 'k' }), %i[users], overrides: basic)
      expect { request.perform }.to raise_error(ApiRecipes::InvalidCredential)
    end
    expect(WebMock).to have_requested(:get, 'https://api.example.test/users').once
  end

  it 'does not put the body in the error of verify_with' do
    stub_request(:get, 'https://api.example.test/users').to_return(status: 200, body: 'SECRET BODY')
    owner = Class.new { def self.check(_response) = false }
    request = new_request(base.merge(verify_with: :check), %i[users], owner: owner)
    expect { request.perform }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected) { |e|
      expect(e.message).not_to include('SECRET BODY')
      expect(e.response.body.to_s).to eq('SECRET BODY')
    }
  end

  it 'refuses to send when the host is not the validated one' do
    stub_request(:any, /evil\.test/).to_return(status: 200)
    request = new_request(base, %i[users])
    allow(request).to receive(:url).and_return(URI('https://evil.test/users'))
    expect { request.perform }.to raise_error(ApiRecipes::InvalidUrl)
    expect(WebMock).not_to have_requested(:any, /evil\.test/)
  end
end
