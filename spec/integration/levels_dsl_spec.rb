require 'spec_helper'

describe 'Credentials, variables and class trees through the DSL' do
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:shopify) do
    { host: '{shop}.example.test', auth: { type: 'header', name: 'X-Token' },
      variables: { shop: {} }, endpoints: { orders: nil } }
  end

  before { stub_request(:any, /example\.test/).to_return(status: 200, body: '{}', headers: json) }

  it 'gives each client its own host and token' do
    configure_test_apis(shopify: shopify)
    client = Class.new do
      include ApiRecipes
      api :shopify

      def initialize(shop, token)
        shopify.variables = { shop: shop }
        shopify.authorization = token
      end

      def orders = shopify.orders.run
    end
    a = client.new('acme', 'token-a')
    client.new('other', 'token-b')
    a.orders
    expect(WebMock).to have_requested(:get, 'https://acme.example.test/orders').with(headers: { 'X-Token' => 'token-a' })
    expect(a.shopify.authorization).to eq('token-a')
  end

  it 'fails with the name of the variable when none is set' do
    configure_test_apis(shopify: shopify)
    expect { ApiRecipes.shopify.orders.url }.to raise_error(ApiRecipes::MissingVariable, /shop/)
    expect(ApiRecipes.shopify.with(variables: { shop: 'acme' }).orders.url.to_s).to eq('https://acme.example.test/orders')
  end

  it 'takes variables from configure and from the class' do
    shopify_config = shopify
    ApiRecipes.configure do |config|
      config.logger = Logger.new(IO::NULL)
      config.apis_configs = { shopify: shopify_config }
      config.variables = { shopify: { shop: 'global' } }
    end
    klass = Class.new do
      include ApiRecipes
      api :shopify, variables: { shop: 'class' }
    end
    expect(ApiRecipes.shopify.orders.url.to_s).to eq('https://global.example.test/orders')
    expect(klass.shopify.orders.url.to_s).to eq('https://class.example.test/orders')
  end

  it 'works when the class is declared before configure, and follows a new configuration' do
    klass = Class.new do
      include ApiRecipes
      api :svc, timeout: 10
    end
    plain = Class.new do
      include ApiRecipes
      api :svc
    end
    configure_test_apis(svc: { host: 'one.example.test', endpoints: { users: nil } })
    expect(klass.svc.users.url.to_s).to eq('https://one.example.test/users')
    expect(plain.svc.definition).to equal(ApiRecipes.svc.definition)
    expect(klass.svc.definition).to equal(klass.svc.definition)        # compiled once
    configure_test_apis(svc: { host: 'two.example.test', endpoints: { users: nil } })
    expect(klass.svc.users.url.to_s).to eq('https://two.example.test/users')
    expect(plain.svc.users.url.to_s).to eq('https://two.example.test/users')
  end

  it 'compiles the tree of a class once under concurrency' do
    configure_test_apis(svc: { host: 'one.example.test', endpoints: { users: nil } })
    klass = Class.new do
      include ApiRecipes
      api :svc, timeout: 10
    end
    definitions = Array.new(10) { Thread.new { klass.svc.definition } }.map(&:value)
    expect(definitions.uniq(&:object_id).size).to eq(1)
  end

  it 'compiles the tree of a class from the registry current when the lock is taken' do
    configure_test_apis(svc: { host: 'one.example.test', endpoints: { users: nil } })
    klass = Class.new do
      include ApiRecipes
      api :svc, timeout: 10
    end
    lock = klass.instance_variable_get(:@__api_recipes_declarations)[:svc].instance_variable_get(:@lock)
    waiting = nil
    lock.synchronize do
      waiting = Thread.new { klass.svc.definition }
      Thread.pass until waiting.status == 'sleep'
      configure_test_apis(svc: { host: 'two.example.test', endpoints: { users: nil } })
    end
    expect(waiting.value.host).to eq('two.example.test')
    expect(klass.svc.definition).to equal(waiting.value)
  end

  it 'lets a subclass inherit the api and the class credential, without leaking back' do
    configure_test_apis(svc: { host: 'api.example.test', endpoints: { users: nil } })
    parent = Class.new do
      include ApiRecipes
      api :svc
    end
    child = Class.new(parent)
    parent.svc.authorization = 'Bearer parent'
    expect(child.svc.authorization).to eq('Bearer parent')
    expect(child.new.svc.authorization).to eq('Bearer parent')
    child.svc.authorization = 'Bearer child'
    expect(parent.svc.authorization).to eq('Bearer parent')
    expect(child.new.svc.authorization).to eq('Bearer child')
  end

  it 'offers another method name with as' do
    configure_test_apis(svc: { host: 'api.example.test', endpoints: { users: nil } })
    klass = Class.new do
      include ApiRecipes
      def self.svc = :taken
      api :svc, as: :service
    end
    expect(klass.service.users.url.to_s).to eq('https://api.example.test/users')
    expect(klass.new.service).to be_a(ApiRecipes::Api)
    with_instance_method = lambda do
      Class.new do
        include ApiRecipes
        def svc = 1
        api :svc
      end
    end
    with_bad_option = lambda do
      Class.new do
        include ApiRecipes
        api :svc, bogus: 1
      end
    end
    expect(&with_instance_method).to raise_error(ApiRecipes::ApiNameClashError)
    expect(&with_bad_option).to raise_error(ApiRecipes::ConfigurationError)
  end

  it 'forgets credentials on reset but not on configure' do
    configure_test_apis
    ApiRecipes.svc.authorization = 'Bearer g'
    configure_test_apis
    expect(ApiRecipes.svc.authorization).to eq('Bearer g')
    ApiRecipes.reset!
    configure_test_apis
    expect(ApiRecipes.svc.authorization).to be_nil
  end

  it 'keeps a frozen copy of the variables with Symbol keys, clears them with nil and refuses anything else' do
    configure_test_apis(shopify: shopify)
    shop = +'acme'
    ApiRecipes.shopify.variables = { 'shop' => shop }
    shop.replace('evil')
    expect(ApiRecipes.shopify.variables).to eq(shop: 'acme').and(be_frozen)
    expect(ApiRecipes.shopify.orders.url.to_s).to eq('https://acme.example.test/orders')
    ApiRecipes.shopify.variables = nil
    expect(ApiRecipes.shopify.variables).to eq({})
    expect { ApiRecipes.shopify.orders.url }.to raise_error(ApiRecipes::MissingVariable)
    ['acme', { 'shop' => 'a', shop: 'b' }, { 'not a name' => 'x' }].each do |values|
      expect { ApiRecipes.shopify.variables = values }.to raise_error(ApiRecipes::ConfigurationError)
    end
  end

  it 'takes variables with String keys from configure and from the class, and keeps a copy' do
    shopify_config = shopify
    global_shop = +'global'
    class_shop = +'class'
    ApiRecipes.configure do |config|
      config.logger = Logger.new(IO::NULL)
      config.apis_configs = { shopify: shopify_config }
      config.variables = { 'shopify' => { 'shop' => global_shop } }
    end
    klass = Class.new do
      include ApiRecipes
      api :shopify, 'variables' => { 'shop' => class_shop }
    end
    global_shop.replace('evil')
    class_shop.replace('evil')
    expect(ApiRecipes.shopify.orders.url.to_s).to eq('https://global.example.test/orders')
    expect(klass.shopify.orders.url.to_s).to eq('https://class.example.test/orders')
    expect { ApiRecipes.configure { |config| config.variables = { shopify: 'acme' } } }
      .to raise_error(ApiRecipes::ConfigurationError)
  end

  it 'compiles the tree of a class from the values given to configure and to api, not from later changes' do
    global_host = +'one.example.test'
    class_path = +'/people'
    configure_test_apis(svc: { host: global_host, endpoints: { users: nil } })
    klass = Class.new do
      include ApiRecipes
      api :svc, endpoints: { users: { path: class_path } }
    end
    global_host.replace('evil.test')
    class_path.replace('/evil')
    expect(klass.svc.users.url.to_s).to eq('https://one.example.test/people')
  end

  it 'gives a class its declared variables again after reset' do
    klass = Class.new do
      include ApiRecipes
      api :shopify, variables: { shop: 'class' }
    end
    ApiRecipes.reset!
    configure_test_apis(shopify: shopify)
    expect(klass.shopify.orders.url.to_s).to eq('https://class.example.test/orders')
  end

  it 'reads the levels once per request, for the origin, the credential and the headers' do
    configure_test_apis(shopify: shopify.merge(default_headers: { 'X-Shop' => '{shop}' }))
    klass = Class.new do
      include ApiRecipes
      api :shopify, variables: { shop: 'acme' }
    end
    klass.shopify.authorization = 'token-class'
    endpoint = klass.new.shopify.orders
    expect(ApiRecipes::Levels).to receive(:chain).once.and_call_original
    endpoint.run
    expect(WebMock).to have_requested(:get, 'https://acme.example.test/orders')
      .with(headers: { 'X-Token' => 'token-class', 'X-Shop' => 'acme' })
  end

  it 'reads the credential resolved along the chain, and nil for the other kind' do
    configure_test_apis
    ApiRecipes.svc.basic_auth = { user: 'u', pass: 'p' }
    expect(ApiRecipes.svc.basic_auth).to eq(user: 'u', pass: 'p')
    expect(ApiRecipes.svc.authorization).to be_nil
    klass = new_client_class
    object = klass.new
    expect(object.svc.basic_auth).to eq(user: 'u', pass: 'p')
    expect(object.svc.with(authorization: 'Bearer chain').authorization).to eq('Bearer chain')
    object.svc.authorization = nil
    expect([object.svc.authorization, object.svc.basic_auth]).to eq([nil, nil])
    expect(klass.new.svc.basic_auth).to eq(user: 'u', pass: 'p')
  end
end
