require 'spec_helper'

describe 'with' do
  let(:json) { { 'Content-Type' => 'application/json' } }

  before do
    configure_test_apis(svc: { host: 'api.example.test', timeout: 3, endpoints: { things: { timeout: 30 }, other: nil } })
    stub_request(:any, /example\.test/).to_return(status: 200, body: '{}', headers: json)
  end

  it 'returns a copy and leaves the original alone' do
    svc = ApiRecipes.svc
    copy = svc.with(authorization: 'Bearer chain')
    expect(copy).to be_a(ApiRecipes::Api)
    expect(copy).not_to equal(svc)
    copy.other.run
    svc.other.run
    expect(WebMock).to have_requested(:get, "#{base_url}/other").with(headers: { 'Authorization' => 'Bearer chain' }).once
    expect(WebMock).to have_requested(:get, "#{base_url}/other").twice
  end

  it 'follows the precedence of options' do
    expect_timeout(60)
    ApiRecipes.svc.with(timeout: 10).things.with(timeout: 60).run
  end

  it 'applies an endpoint option to that request only' do
    stub_request(:get, "#{base_url}/other").to_return(status: 500)
    expect(ApiRecipes.svc.other.with(on_bad_code: 'ignore').run.code).to eq(500)
    expect { ApiRecipes.svc.other.run }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected)
  end

  it 'drops an endpoint option given again as nil, and does not pass it to the children' do
    configure_test_apis(svc: { host: 'api.example.test', endpoints: { other: { endpoints: { child: nil } } } })
    stub_request(:get, "#{base_url}/other").to_return(status: 500)
    stub_request(:get, "#{base_url}/other/child").to_return(status: 500)
    lenient = ApiRecipes.svc.other.with(on_bad_code: 'ignore')
    expect(lenient.run.code).to eq(500)
    expect { lenient.with('on_bad_code' => nil).run }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected)
    expect { lenient.child.run }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected)
  end

  it 'refuses the writers on a copy made by with, and leaves the shared levels alone' do
    copy = ApiRecipes.svc.with(timeout: 5)
    expect { copy.authorization = 'Bearer copy' }.to raise_error(ApiRecipes::Error, /with\(authorization: \.\.\.\)/)
    expect { copy.basic_auth = { user: 'u', pass: 'p' } }.to raise_error(ApiRecipes::Error, /with\(basic_auth: \.\.\.\)/)
    expect { copy.variables = { region: 'eu' } }.to raise_error(ApiRecipes::Error, /with\(variables: \.\.\.\)/)
    expect([ApiRecipes.svc.authorization, ApiRecipes.svc.basic_auth, ApiRecipes.svc.variables]).to eq([nil, nil, {}])
    ApiRecipes.svc.authorization = 'Bearer shared'
    expect(copy.authorization).to eq('Bearer shared')
  end

  it 'refuses what it does not know' do
    expect { ApiRecipes.svc.with(endpoints: {}) }.to raise_error(ApiRecipes::ConfigurationError)
    expect { ApiRecipes.svc.other.with(path: '/x') }.to raise_error(ApiRecipes::ConfigurationError)
  end

  it 'keeps two threads apart' do
    seen = Queue.new
    stub_request(:get, "#{base_url}/other").to_return do |request|
      seen << request.headers['Authorization']
      { status: 200, body: '{}', headers: json }
    end
    %w[a b].map { |t| Thread.new { 20.times { ApiRecipes.svc.with(authorization: "Bearer #{t}").other.run } } }.each(&:join)
    expect(Array.new(seen.size) { seen.pop }.tally).to eq('Bearer a' => 20, 'Bearer b' => 20)
  end
end
