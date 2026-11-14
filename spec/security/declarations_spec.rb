require 'spec_helper'

# A credential is bound to the tree of the declaration that serves the
# request, so two declarations of one api must never meet in one hierarchy,
# however the second one arrives.
describe 'Declarations of an api in modules, subclasses and objects' do
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:shopify) do
    { host: '{shop}.example.test', auth: { type: 'header', name: 'X-Token' },
      variables: { shop: {} }, endpoints: { orders: nil } }
  end

  before do
    configure_test_apis(svc: { host: 'api.example.test', endpoints: { users: nil } }, shopify: shopify)
    stub_request(:any, /\.test/).to_return(status: 200, body: '{}', headers: json)
  end

  def declaring_module(name, **options)
    Module.new do
      include ApiRecipes
      api name, options
    end
  end

  it 'refuses an object extended with a module that declares the api of its class again' do
    klass = Class.new do
      include ApiRecipes
      api :svc
    end
    object = klass.new
    object.svc.authorization = 'Bearer A-INSTANCE'
    object.extend(declaring_module(:svc, host: 'evil.test'))
    expect { object.svc.users.run }.to raise_error(ApiRecipes::ApiNameClashError, /already declared/)
    expect(WebMock).not_to have_requested(:any, /evil\.test/)
  end

  it 'refuses a subclass that includes a module declaring the api of its superclass' do
    parent = Class.new do
      include ApiRecipes
      api :svc
    end
    parent.svc.authorization = 'Bearer B-CLASS'
    evil = declaring_module(:svc, host: 'evil.test')
    child = Class.new(parent) { include evil }
    expect { child.new.svc.users.run }.to raise_error(ApiRecipes::ApiNameClashError, /already declared/)
    expect { child.svc.users.run }.to raise_error(ApiRecipes::ApiNameClashError, /already declared/)
    expect(WebMock).not_to have_requested(:any, /evil\.test/)
  end

  it 'refuses an object extended with two modules that declare the same api' do
    object = Object.new
    object.extend(declaring_module(:svc, host: 'one.example.test'))
    object.extend(declaring_module(:svc, host: 'two.example.test'))
    expect { object.svc }.to raise_error(ApiRecipes::ApiNameClashError, /already declared/)
  end

  it 'refuses a declaration on a singleton class' do
    klass = Class.new { include ApiRecipes }
    object = klass.new
    object.singleton_class.include(ApiRecipes)
    expect { object.singleton_class.api :svc, host: 'evil.test' }
      .to raise_error(ApiRecipes::ApiNameClashError, /singleton class/)
    klass.api :svc
    klass.svc.authorization = 'Bearer A-CLASS'
    object.svc.users.run
    expect(WebMock).to have_requested(:get, 'https://api.example.test/users').with(headers: { 'Authorization' => 'Bearer A-CLASS' })
    expect(WebMock).not_to have_requested(:any, /evil\.test/)
  end

  it 'does not send the global credential to the host of a class tree' do
    ApiRecipes.svc.authorization = 'Bearer GLOBAL'
    klass = Class.new do
      include ApiRecipes
      api :svc, host: 'other.example.test'
    end
    expect { klass.svc.users.run }.to raise_error(ApiRecipes::CredentialOriginMismatch)
    expect { klass.new.svc.users.run }.to raise_error(ApiRecipes::CredentialOriginMismatch)
    expect(WebMock).not_to have_requested(:any, /other\.example\.test/)
  end

  it 'lets a module declare an api for the classes that include it, with the variables of the module' do
    shop = declaring_module(:shopify, variables: { shop: 'acme' })
    first = Class.new { include shop }
    second = Class.new { include shop }
    a = first.new
    b = second.new
    a.shopify.authorization = 'token-a'
    b.shopify.authorization = 'token-b'
    a.shopify.orders.run
    b.shopify.orders.run
    expect(WebMock).to have_requested(:get, 'https://acme.example.test/orders').with(headers: { 'X-Token' => 'token-a' }).once
    expect(WebMock).to have_requested(:get, 'https://acme.example.test/orders').with(headers: { 'X-Token' => 'token-b' }).once
    shop.shopify.authorization = 'token-module'
    expect([first.new.shopify.authorization, second.new.shopify.authorization]).to eq(%w[token-module token-module])
    expect(shop.shopify.orders.url.to_s).to eq('https://acme.example.test/orders')
    second.new.shopify.orders.run
    expect(WebMock).to have_requested(:get, 'https://acme.example.test/orders').with(headers: { 'X-Token' => 'token-module' })
  end

  it 'lets an object use a module it was extended with, when its class declares nothing' do
    shop = declaring_module(:shopify, variables: { shop: 'acme' })
    object = Class.new.new
    object.extend(shop)
    expect(object.shopify.orders.url.to_s).to eq('https://acme.example.test/orders')
    shop.shopify.authorization = 'token-module'
    object.shopify.orders.run
    expect(WebMock).to have_requested(:get, 'https://acme.example.test/orders').with(headers: { 'X-Token' => 'token-module' })
  end

  it 'creates no singleton class for the objects that use an api, frozen ones included' do
    klass = Class.new do
      include ApiRecipes
      api :svc
    end
    objects = Array.new(5) { klass.new } << klass.new.freeze
    objects.each { |object| 3.times { object.svc.users.url } }
    attached = ObjectSpace.each_object(Class).select(&:singleton_class?).map(&:attached_object)
    expect(attached.select { |owner| objects.any? { |object| object.equal?(owner) } }).to eq([])
    expect(objects.last.svc.users.url.to_s).to eq('https://api.example.test/users')
  end
end
