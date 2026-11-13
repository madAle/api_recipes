require 'spec_helper'

describe ApiRecipes::Endpoint do
  before { configure_test_apis }
  let(:svc) { new_client_class.svc }

  it 'builds the url from the endpoint name' do
    expect(svc.users.url.to_s).to eq("#{base_url}/users")
  end

  it 'replaces a path parameter' do
    expect(svc.users.show(1).url.to_s).to eq("#{base_url}/users/1")
  end

  it 'chains nested endpoints after a parameter' do
    expect(svc.repos('rails').contributors.url.to_s).to eq("#{base_url}/repos/rails/contributors")
  end

  it 'raises when a path parameter is missing' do
    expect { svc.users.show }.to raise_error(ApiRecipes::PathParamsMismatch)
  end

  it 'raises when too many path parameters are given' do
    expect { svc.users.show(1, 2) }.to raise_error(ApiRecipes::PathParamsMismatch)
  end

  it 'has no route when route is false' do
    expect(svc.group.url).to be_nil
    expect { svc.group.run }.to raise_error(ApiRecipes::NoRouteExists)
    expect(svc.group.ping.url.to_s).to eq("#{base_url}/group/ping")
  end

  it 'uses protocol, port and base_url of the api' do
    expect(new_client_class.versioned.ping.url.to_s).to eq('http://api.example.test:8080/v1/ping')
  end

  it 'is reachable from instances and from the ApiRecipes module' do
    expect(new_client_class.new.svc.users.url.to_s).to eq("#{base_url}/users")
    expect(ApiRecipes.svc.users.url.to_s).to eq("#{base_url}/users")
  end
end
