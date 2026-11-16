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
      config.values = { shopify: { variables: { shop: 'global' }, authorization: 'token-global' } }
    end
    klass = Class.new do
      include ApiRecipes
      api :shopify, variables: { shop: 'class' }, authorization: 'token-class'
    end
    plain = Class.new do
      include ApiRecipes
      api :shopify
    end
    expect(ApiRecipes.shopify.orders.url.to_s).to eq('https://global.example.test/orders')
    expect(klass.shopify.orders.url.to_s).to eq('https://class.example.test/orders')
    expect([ApiRecipes.shopify.authorization, klass.shopify.authorization, klass.new.shopify.authorization,
            plain.new.shopify.authorization]).to eq(%w[token-global token-class token-class token-global])
    klass.new.shopify.orders.run
    expect(WebMock).to have_requested(:get, 'https://class.example.test/orders').with(headers: { 'X-Token' => 'token-class' })
  end

  # What the whole application or a class uses is shared by every thread: it
  # is given where the application starts, and cannot be assigned later.
  it 'refuses to assign a credential or variables on the api of the module, of a class or of a module' do
    configure_test_apis(shopify: shopify)
    klass = Class.new do
      include ApiRecipes
      api :shopify
    end
    mixin = Module.new do
      include ApiRecipes
      api :svc
    end
    { ApiRecipes.shopify => /\AApiRecipes\.shopify is shared by the whole application, in every thread: give its \w+ to ApiRecipes\.configure, as config\.values = \{ shopify: \{ \w+: \.\.\. \} \}, or use with\(\w+: \.\.\.\) for one chain\z/,
      ApiRecipes[:shopify] => /\AApiRecipes\.shopify is shared/,
      klass.shopify => /\Aa class or a module is shared by all its objects, in every thread: give its \w+ to `api :shopify, \w+: \.\.\.`, or use an object or with\(\w+: \.\.\.\) for one chain\z/,
      Class.new(klass).shopify => /\Aa class or a module is shared/,
      mixin.svc => /\Aa class or a module is shared/ }.each do |api, message|
      expect { api.authorization = 'token' }.to raise_error(ApiRecipes::Error, message)
      expect { api.authorization = nil }.to raise_error(ApiRecipes::Error, message)
      expect { api.basic_auth = { user: 'u', pass: 'p' } }.to raise_error(ApiRecipes::Error, message)
      expect { api.variables = { shop: 'acme' } }.to raise_error(ApiRecipes::Error, message)
      expect { api.variables = nil }.to raise_error(ApiRecipes::Error, message)
    end
    expect([ApiRecipes.shopify.authorization, klass.shopify.authorization, klass.shopify.variables]).to eq([nil, nil, {}])
    expect { ApiRecipes.shopify.orders.url }.to raise_error(ApiRecipes::MissingVariable)
    object = klass.new
    object.shopify.variables = { shop: 'acme' }
    object.shopify.authorization = 'token-object'
    expect([object.shopify.orders.url.to_s, object.shopify.authorization]).to eq(['https://acme.example.test/orders', 'token-object'])
    expect(klass.new.shopify.authorization).to be_nil
    # The api that with returned belongs to its chain: it writes nothing on the object.
    chained = object.shopify.with(variables: { shop: 'other' })
    expect { chained.authorization = 'token-chain' }
      .to raise_error(ApiRecipes::Error, 'an api returned by with cannot set authorization for the caller: use with(authorization: ...)')
    expect { chained.basic_auth = { user: 'u', pass: 'p' } }.to raise_error(ApiRecipes::Error, /returned by with cannot set basic_auth/)
    expect { chained.variables = { shop: 'evil' } }.to raise_error(ApiRecipes::Error, /returned by with cannot set variables/)
    expect([object.shopify.authorization, object.shopify.variables]).to eq(['token-object', { shop: 'acme' }])
  end

  describe 'the values of the application and a later configure' do
    def configure_shopify(values = :unchanged)
      shopify_config = shopify
      ApiRecipes.configure do |config|
        config.logger = Logger.new(IO::NULL)
        config.apis_configs = { shopify: shopify_config }
        config.values = values unless values == :unchanged
      end
    end

    # The rule: the level of the application holds what the configuration in
    # force gives with values, and nothing else.
    it 'stops using a variable that the new configuration does not give' do
      configure_shopify(shopify: { variables: { shop: 'old' } })
      expect(ApiRecipes.shopify.orders.url.to_s).to eq('https://old.example.test/orders')
      configure_shopify({})
      expect { ApiRecipes.shopify.orders.url }.to raise_error(ApiRecipes::MissingVariable, /shop/)
      expect(ApiRecipes.shopify.variables).to eq({})
    end

    it 'replaces the values with the ones of the new configuration, credential and variables together' do
      configure_shopify(shopify: { variables: { shop: 'old' }, authorization: 'token-old' })
      configure_shopify(shopify: { variables: { shop: 'new' } })
      expect(ApiRecipes.shopify.orders.url.to_s).to eq('https://new.example.test/orders')
      expect(ApiRecipes.shopify.authorization).to be_nil
      configure_shopify(shopify: { basic_auth: { user: 'u', pass: 'p' } })
      expect(ApiRecipes.shopify.basic_auth).to eq(user: 'u', pass: 'p')
      expect { ApiRecipes.shopify.orders.url }.to raise_error(ApiRecipes::MissingVariable, /shop/)
    end

    it 'keeps the values when a later configure does not give any' do
      configure_shopify(shopify: { variables: { shop: 'kept' }, authorization: 'token' })
      configure_shopify
      expect(ApiRecipes.shopify.orders.url.to_s).to eq('https://kept.example.test/orders')
      expect(ApiRecipes.shopify.authorization).to eq('token')
    end

    it 'changes nothing when the new configuration is refused' do
      configure_shopify(shopify: { variables: { shop: 'old' }, authorization: 'token' })
      [{ shopify: 'acme' }, { shopify: { variables: { shpo: 'x' } } }, { shopify: { authorization: 'a', basic_auth: { user: 'u', pass: 'p' } } },
       { shopify: { token: 'x' } }, { shopify: { authorization: 1 } }, { 1 => {} }, { shopify: {}, 'shopify' => {} }].each do |values|
        expect { configure_shopify(values) }.to raise_error(ApiRecipes::Error), values.inspect
      end
      expect { ApiRecipes.configure { |config| config.values = 'acme' } }.to raise_error(ArgumentError, 'values must be an Hash')
      expect(ApiRecipes.shopify.orders.url.to_s).to eq('https://old.example.test/orders')
      expect(ApiRecipes.shopify.authorization).to eq('token')
    end

    it 'says what is wrong with the values, with the name of the api and without a value' do
      problems = {
        { shopify: 'SECRET' } => ['values.shopify: must be a Hash'],
        { shopify: { token: 'SECRET' } } => ['values.shopify: takes variables, authorization and basic_auth, and nothing else'],
        { shopify: { authorization: 'SECRET', basic_auth: { user: 'u', pass: 'SECRET' } } } =>
          ['values.shopify: takes authorization or basic_auth, not both'],
        { shopify: { variables: 'SECRET' } } => ['values.shopify.variables: must be a Hash'],
        { shopify: { 'SECRET-AS-A-KEY' => true } } => ['values.shopify: takes variables, authorization and basic_auth, and nothing else'],
        { shopify: { authorization: 'SECRET', 'authorization' => 'SECRET' } } => ['values.shopify: authorization is given twice'],
        { "shop\nINJECTED" => {} } => ['values.shop?INJECTED: is not the name of an api'],
        { shopify: { variables: { shop: Object.new } } } => ['values.shopify.variables.shop: must be a string'],
        { shopify: { variables: { shpo: 'SECRET' } } } => ["shopify.variables: unknown variable 'shpo' (declared: shop)"]
      }
      problems.each do |values, expected|
        expect { configure_shopify(values) }.to raise_error(ApiRecipes::ConfigurationError) { |error| expect(error.errors).to eq(expected) }
      end
    end

    it 'sends no credential for an api whose authorization is given as nil' do
      configure_shopify(shopify: { variables: { shop: 'acme' }, authorization: nil })
      ApiRecipes.shopify.orders.run
      expect(WebMock).to(have_requested(:get, 'https://acme.example.test/orders').with { |request| !request.headers.key?('X-Token') })
    end
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
      api :svc, authorization: 'Bearer parent'
    end
    child = Class.new(parent)
    expect(child.svc.authorization).to eq('Bearer parent')
    expect(child.new.svc.authorization).to eq('Bearer parent')
    object = child.new
    object.svc.authorization = 'Bearer object'
    expect([parent.svc.authorization, child.svc.authorization, child.new.svc.authorization, object.svc.authorization])
      .to eq(['Bearer parent', 'Bearer parent', 'Bearer parent', 'Bearer object'])
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
    global_values(svc: { authorization: 'Bearer g' })
    configure_test_apis
    expect(ApiRecipes.svc.authorization).to eq('Bearer g')
    ApiRecipes.reset!
    configure_test_apis
    expect(ApiRecipes.svc.authorization).to be_nil
  end

  it 'keeps a frozen copy of the variables with Symbol keys, clears them with nil and refuses anything else' do
    configure_test_apis(shopify: shopify)
    shop = +'acme'
    global_values(shopify: { variables: { 'shop' => shop } })
    shop.replace('evil')
    expect(ApiRecipes.shopify.variables).to eq(shop: 'acme').and(be_frozen)
    expect(ApiRecipes.shopify.orders.url.to_s).to eq('https://acme.example.test/orders')
    global_values(shopify: { variables: nil })
    expect(ApiRecipes.shopify.variables).to eq({})
    expect { ApiRecipes.shopify.orders.url }.to raise_error(ApiRecipes::MissingVariable)
    object = Class.new { include ApiRecipes }.tap { |klass| klass.api(:shopify) }.new
    ['acme', { 'shop' => 'a', shop: 'b' }, { 'not a name' => 'x' }].each do |values|
      expect { global_values(shopify: { variables: values }) }.to raise_error(ApiRecipes::ConfigurationError)
      expect { object.shopify.variables = values }.to raise_error(ApiRecipes::ConfigurationError)
    end
  end

  it 'takes variables with String keys from configure and from the class, and keeps a copy' do
    shopify_config = shopify
    global_shop = +'global'
    class_shop = +'class'
    ApiRecipes.configure do |config|
      config.logger = Logger.new(IO::NULL)
      config.apis_configs = { shopify: shopify_config }
      config.values = { 'shopify' => { 'variables' => { 'shop' => global_shop } } }
    end
    klass = Class.new do
      include ApiRecipes
      api :shopify, 'variables' => { 'shop' => class_shop }
    end
    global_shop.replace('evil')
    class_shop.replace('evil')
    expect(ApiRecipes.shopify.orders.url.to_s).to eq('https://global.example.test/orders')
    expect(klass.shopify.orders.url.to_s).to eq('https://class.example.test/orders')
    expect { ApiRecipes.configure { |config| config.values = { shopify: 'acme' } } }
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

  it 'gives a class its declared variables and credential again after reset' do
    klass = Class.new do
      include ApiRecipes
      api :shopify, variables: { shop: 'class' }, authorization: 'token-class'
    end
    ApiRecipes.reset!
    configure_test_apis(shopify: shopify)
    expect(klass.shopify.orders.url.to_s).to eq('https://class.example.test/orders')
    expect(klass.new.shopify.authorization).to eq('token-class')
  end

  it 'reads the levels once per request, for the origin, the credential and the headers' do
    configure_test_apis(shopify: shopify.merge(default_headers: { 'X-Shop' => '{shop}' }))
    klass = Class.new do
      include ApiRecipes
      api :shopify, variables: { shop: 'acme' }, authorization: 'token-class'
    end
    endpoint = klass.new.shopify.orders
    expect(ApiRecipes::Internals::Levels).to receive(:chain).once.and_call_original
    endpoint.run
    expect(WebMock).to have_requested(:get, 'https://acme.example.test/orders')
      .with(headers: { 'X-Token' => 'token-class', 'X-Shop' => 'acme' })
  end

  it 'reads the credential resolved along the chain, and nil for the other kind' do
    configure_test_apis
    global_values(svc: { basic_auth: { user: 'u', pass: 'p' } })
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
