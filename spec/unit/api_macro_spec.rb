require 'spec_helper'

describe 'The api class macro' do
  before { configure_test_apis }

  it 'makes the api available to the class and to its instances' do
    klass = new_client_class
    expect(klass.svc).to be_a(ApiRecipes::Api)
    expect(klass.new.svc).to be_a(ApiRecipes::Api)
  end

  it 'passes the caller to the api as object' do
    klass = new_client_class
    instance = klass.new
    expect(klass.svc.object).to equal(klass)
    expect(instance.svc.object).to equal(instance)
  end

  it 'accepts the api name as a String' do
    klass = Class.new do
      include ApiRecipes
      api 'svc'
    end
    expect(klass.svc.users.url.to_s).to eq("#{base_url}/users")
  end

  it 'declares several apis in the same class' do
    klass = new_client_class
    expect(klass.svc.users.url.to_s).to eq("#{base_url}/users")
    expect(klass.versioned.ping.url.to_s).to eq('http://api.example.test:8080/v1/ping')
  end

  it 'accepts custom configs with String keys' do
    klass = Class.new do
      include ApiRecipes
      api :svc, 'host' => 'other.example.test', 'endpoints' => { 'users' => { 'path' => '/people' } }
    end
    expect(klass.svc.users.url.to_s).to eq('https://other.example.test/people')
  end

  it 'declares an api that is not in the global configuration' do
    klass = Class.new do
      include ApiRecipes
      api :weather, host: 'api.weather.test', endpoints: { forecast: { path: '/forecast/:city' } }
    end
    expect(klass.weather.forecast('rome').url.to_s).to eq('https://api.weather.test/forecast/rome')
    expect(ApiRecipes).not_to respond_to(:weather)
  end

  it 'uses the defaults for an api declared with no configuration at all' do
    klass = Class.new do
      include ApiRecipes
      api :unknown
    end
    expect(klass.unknown.configs).to include(protocol: 'https', host: 'localhost', timeout: 3, on_bad_code: 'raise')
  end

  it 'rejects a name that is neither a String nor a Symbol' do
    expect do
      Class.new do
        include ApiRecipes
        api 42
      end
    end.to raise_error(ArgumentError)
  end

  it 'rejects configs that are not a Hash' do
    expect do
      Class.new do
        include ApiRecipes
        api :svc, 'not a hash'
      end
    end.to raise_error(ApiRecipes::ApiConfigIsNotAnHash)
  end

  it 'rejects a name the class already responds to' do
    expect do
      Class.new do
        include ApiRecipes
        api :name
      end
    end.to raise_error(ApiRecipes::ApiNameClashError)
  end
end
