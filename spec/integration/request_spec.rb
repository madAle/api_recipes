require 'spec_helper'

describe 'HTTP requests' do
  before { configure_test_apis }
  let(:klass) { new_client_class }
  let(:json)  { { 'Content-Type' => 'application/json' } }

  it 'returns parsed data for a 200 JSON response' do
    stub_request(:get, "#{base_url}/users").to_return(status: 200, body: '[{"login":"a"}]', headers: json)
    expect(klass.svc.users.run.data).to eq([{ 'login' => 'a' }])
  end

  it 'yields the response to the block' do
    stub_request(:get, "#{base_url}/users").to_return(status: 200, body: '[]', headers: json)
    code = nil
    klass.svc.users { |response| code = response.code }
    expect(code).to eq(200)
  end

  it 'sends default headers' do
    stub_request(:get, "#{base_url}/users").to_return(status: 200, body: '[]', headers: json)
    klass.svc.users.run
    expect(WebMock).to have_requested(:get, "#{base_url}/users").with(headers: { 'Accept' => 'application/json' })
  end

  it 'raises ResponseCodeNotAsExpected on a 500' do
    stub_request(:get, "#{base_url}/users").to_return(status: 500, body: 'boom')
    expect { klass.svc.users.run }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected) do |error|
      expect(error.response.code).to eq(500)
      expect(error.path).to eq('/users')
    end
  end

  it 'does not raise when on_bad_code is ignore' do
    stub_request(:get, "#{base_url}/lenient").to_return(status: 500, body: 'boom')
    expect(klass.svc.lenient.run.code).to eq(500)
  end

  it 'checks ok_code and sends request params with the configured verb' do
    stub_request(:post, "#{base_url}/users").to_return(status: 201, body: '{}', headers: json)
    klass.svc.create(json: { name: 'x' }).run
    expect(WebMock).to have_requested(:post, "#{base_url}/users").with(body: '{"name":"x"}')

    stub_request(:post, "#{base_url}/users").to_return(status: 200, body: '{}', headers: json)
    expect { klass.svc.create.run }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected)
  end

  it 'delegates the check to verify_with' do
    stub_request(:get, "#{base_url}/checked").to_return(status: 200, body: 'SECRET')
    klass.define_singleton_method(:response_ok?) { |_response| false }
    expect { klass.svc.checked.run }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected)

    klass.define_singleton_method(:response_ok?) { |_response| true }
    expect(klass.svc.checked.run.code).to eq(200)
  end

  it 'sends the authorization set on the global api' do
    stub_request(:get, "#{base_url}/users").to_return(status: 200, body: '[]', headers: json)
    ApiRecipes.svc.authorization = 'Bearer g'
    ApiRecipes.svc.users.run
    expect(WebMock).to have_requested(:get, "#{base_url}/users").with(headers: { 'Authorization' => 'Bearer g' })
  end

  it 'lets network errors through as HTTP::Error' do
    stub_request(:get, "#{base_url}/users").to_raise(HTTP::ConnectionError)
    expect { klass.svc.users.run }.to raise_error(HTTP::Error)
  end
end
