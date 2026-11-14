require 'spec_helper'

describe 'An api declared in a class' do
  before { configure_test_apis }
  let(:json) { { 'Content-Type' => 'application/json' } }

  it 'sends the authorization set on the global api' do
    stub_request(:get, "#{base_url}/users").to_return(status: 200, body: '[]', headers: json)
    ApiRecipes.svc.authorization = 'Bearer g'
    new_client_class.svc.users.run
    expect(WebMock).to have_requested(:get, "#{base_url}/users").with(headers: { 'Authorization' => 'Bearer g' })
  end

  it 'sends the basic auth set on the global api' do
    stub_request(:get, "#{base_url}/users").to_return(status: 200, body: '[]', headers: json)
    ApiRecipes.svc.basic_auth = { user: 'u', pass: 'p' }
    new_client_class.new.svc.users.run
    expect(WebMock).to have_requested(:get, "#{base_url}/users").with(headers: { 'Authorization' => 'Basic dTpw' })
  end

  it 'merges the configs given to api over the global ones' do
    klass = Class.new do
      include ApiRecipes
      api :svc, host: 'other.example.test', endpoints: { users: { path: '/people' } }
    end
    expect(klass.svc.users.url.to_s).to eq('https://other.example.test/people')
    expect(klass.svc.repos('rails').contributors.url.to_s)
      .to eq('https://other.example.test/repos/rails/contributors')
  end

  it 'adds the endpoints that a class gives without options' do
    klass = Class.new do
      include ApiRecipes
      api :svc, endpoints: { extra: nil, users: { endpoints: { more: nil } } }
    end
    expect(klass.svc.extra.url.to_s).to eq("#{base_url}/extra")
    expect(klass.svc.users.more.url.to_s).to eq("#{base_url}/users/more")
    expect(klass.svc[:extra].url.to_s).to eq("#{base_url}/extra")
    expect(klass.svc[:users][:more].url.to_s).to eq("#{base_url}/users/more")
  end

  it 'keeps the global options of an endpoint that a class gives without options' do
    klass = Class.new do
      include ApiRecipes
      api :svc, endpoints: { repos: nil, files: nil }
    end
    expect(klass.svc.repos('rails').contributors.url.to_s).to eq("#{base_url}/repos/rails/contributors")
    expect(klass.svc.files('a').url.to_s).to eq("#{base_url}/files/a.json")
  end
end
