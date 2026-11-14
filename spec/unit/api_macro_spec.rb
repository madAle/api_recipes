require 'spec_helper'

describe 'The api class macro' do
  before { configure_test_apis }

  it 'makes the api available to the class and to its instances' do
    klass = new_client_class
    expect(klass.svc).to be_a(ApiRecipes::Api)
    expect(klass.new.svc).to be_a(ApiRecipes::Api)
  end

  it 'checks responses with the verify_with method of the caller, class or instance' do
    stub_request(:get, "#{base_url}/checked").to_return(status: 200, body: '')
    klass = new_client_class
    klass.define_singleton_method(:response_ok?) { |_response| false }
    klass.define_method(:response_ok?) { |_response| true }
    expect { klass.svc.checked.run }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected)
    expect(klass.new.svc.checked.run.code).to eq(200)
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

  it 'accepts an api declared with no configuration at all' do
    klass = Class.new do
      include ApiRecipes
      api :unknown
    end
    expect(klass.unknown).to be_a(ApiRecipes::Api)
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

  it 'rejects an empty or invalid name and an as: that is not a method name, and declares nothing' do
    klass = Class.new { include ApiRecipes }
    ['', :'', "\xFF"].each { |name| expect { klass.api(name) }.to raise_error(ArgumentError) }
    [42, 'not a name', '', { 'as' => :a, as: :b }].each do |as|
      options = as.is_a?(Hash) ? as : { as: as }
      expect { klass.api(:svc, options) }.to raise_error(ApiRecipes::ConfigurationError)
    end
    expect { klass.api(:svc, variables: 'x') }.to raise_error(ApiRecipes::ConfigurationError)
    klass.api(:svc)
    expect(klass.svc.users.url.to_s).to eq("#{base_url}/users")
  end

  describe 'one declaration of an api per class hierarchy' do
    let(:parent) do
      Class.new do
        include ApiRecipes
        api :svc
      end
    end

    it 'refuses a subclass that declares the api again, plain, with other options or with as:' do
      [[], [{ timeout: 5 }], [{ as: :service }]].each do |extra|
        child = Class.new(parent)
        expect { child.api(:svc, *extra) }.to raise_error(ApiRecipes::ApiNameClashError, /already declared/)
        expect(child).not_to respond_to(:service)
      end
    end

    it 'refuses a class that declares the api twice under two method names' do
      klass = Class.new do
        include ApiRecipes
        api :svc, as: :first
      end
      expect { klass.api(:svc, as: :second) }.to raise_error(ApiRecipes::ApiNameClashError, /already declared/)
      expect(klass).not_to respond_to(:second)
    end

    it 'refuses a superclass that declares an api one of its subclasses already declares' do
      base = Class.new { include ApiRecipes }
      child = Class.new(base) { api :svc, as: :service }
      expect { base.api(:svc) }.to raise_error(ApiRecipes::ApiNameClashError, /already declared/)
      expect(child.service).to be_a(ApiRecipes::Api)
    end

    it 'lets a subclass declare another api' do
      child = Class.new(parent) { api :versioned }
      expect(child.versioned.ping.url.to_s).to eq('http://api.example.test:8080/v1/ping')
      expect(child.svc.users.url.to_s).to eq("#{base_url}/users")
    end
  end
end
