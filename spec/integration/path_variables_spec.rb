require 'spec_helper'

describe 'Variables in the path of an endpoint' do
  let(:shop) do
    { host: 'shop.example.test', base_url: 'v1',
      variables: { account: {}, zone: { default: 'eu' } },
      endpoints: {
        orders: { path: '/accounts/{account}/orders', endpoints: { show: { path: '/:id' } } },
        zones: { path: '/{zone}/zones' },
        plain: nil
      } }
  end

  before do
    stub_request(:any, /shop\.example\.test/).to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })
    configure_test_apis(shop: shop)
  end

  it 'fills the variable with the value of the nearest level' do
    global_values(shop: { variables: { account: 'acme' } })
    expect(ApiRecipes.shop.orders.url.to_s).to eq('https://shop.example.test/v1/accounts/acme/orders')
    expect(ApiRecipes.shop.orders.show(7).url.to_s).to eq('https://shop.example.test/v1/accounts/acme/orders/7')
    expect(ApiRecipes.shop.with(variables: { account: 'other' }).orders.show(7).url.to_s)
      .to eq('https://shop.example.test/v1/accounts/other/orders/7')
  end

  it 'uses the default of the variable' do
    expect(ApiRecipes.shop.zones.url.to_s).to eq('https://shop.example.test/v1/eu/zones')
  end

  it 'sends the request to the filled path' do
    global_values(shop: { variables: { account: 'acme' } })
    ApiRecipes.shop.orders.show(7).run
    expect(a_request(:get, 'https://shop.example.test/v1/accounts/acme/orders/7')).to have_been_made
  end

  it 'reads the value of a class and of an object' do
    klass = Class.new do
      include ApiRecipes
      api :shop, variables: { account: 'class' }
    end
    client = klass.new
    expect(client.shop.orders.url.to_s).to eq('https://shop.example.test/v1/accounts/class/orders')
    client.shop.variables = { account: 'object' }
    expect(client.shop.orders.url.to_s).to eq('https://shop.example.test/v1/accounts/object/orders')
  end

  it 'encodes the value as one segment, so that it cannot reach another endpoint' do
    api = ApiRecipes.shop.with(variables: { account: '../../admin' })
    expect(api.orders.url.to_s).to eq('https://shop.example.test/v1/accounts/..%2F..%2Fadmin/orders')
    expect { ApiRecipes.shop.with(variables: { account: '..' }).orders }
      .to raise_error(ApiRecipes::InvalidVariable, /account/)
  end

  it 'raises MissingVariable when the chain reaches the endpoint, and not before' do
    expect(ApiRecipes.shop.plain.url.to_s).to eq('https://shop.example.test/v1/plain')
    expect { ApiRecipes.shop.orders }.to raise_error(ApiRecipes::MissingVariable, /account/)
  end

  it 'shows the path as it is written in the definition and in the routes' do
    definition = ApiRecipes.shop.definition
    expect(definition.endpoints[:orders].endpoints[:show].full_path).to eq('/v1/accounts/{account}/orders/:id')
    expect(definition.routes.map(&:url)).to include('https://shop.example.test/v1/accounts/{account}/orders/:id')
    expect(definition.endpoints[:orders].to_h[:path_variables]).to eq(%i[account])
    expect(definition.endpoints[:plain].to_h[:path_variables]).to eq([])
  end

  it 'makes a variable with no default of a name that the path of any endpoint uses and the api does not declare' do
    misspelled = { host: 'h.test', variables: { account: {} },
                   endpoints: { orders: { path: '/{acount}/orders', endpoints: { show: { path: '/{zone}/:id' } } } } }
    configure_test_apis(misspelled: misspelled)
    expect(ApiRecipes.misspelled.definition.variables.keys).to eq(%i[account acount zone])
    expect { ApiRecipes.misspelled.with(variables: { account: 'alice' }).orders.show(1).run }
      .to raise_error(ApiRecipes::MissingVariable, "api 'misspelled' requires the variable 'acount' but it was not provided")
  end

  it 'accepts in an endpoint that a class adds the variables of the api, and makes a variable of the class of another name' do
    klass = Class.new do
      include ApiRecipes
      api :shop, endpoints: { users: { path: '/{zone}/users' } }
    end
    expect(klass.shop.users.url.to_s).to eq('https://shop.example.test/v1/eu/users')
    other = Class.new do
      include ApiRecipes
      api :shop, endpoints: { users: { path: '/{tenant}/users' } }, variables: { tenant: 'acme' }
    end
    expect(other.shop.users.url.to_s).to eq('https://shop.example.test/v1/acme/users')
    expect(ApiRecipes.shop.definition.variables).not_to include(:tenant)
  end

  it 'keeps the path it was built with in the copy that with returns' do
    global_values(shop: { variables: { account: 'alice' } })
    kept = ApiRecipes.shop.orders
    global_values(shop: { variables: { account: 'bob' } })
    expect(kept.url.to_s).to eq('https://shop.example.test/v1/accounts/alice/orders')
    expect(kept.with(timeout: 5).url.to_s).to eq('https://shop.example.test/v1/accounts/alice/orders')
    expect(kept.with(timeout: 5).with(ok_code: 200).show(7).url.to_s).to eq('https://shop.example.test/v1/accounts/alice/orders/7')
  end

  # A server answers many users at once: the value of one must never reach
  # the request of another.
  it 'keeps the value of each thread apart, given to with or to an object of its own' do
    client = Class.new do
      include ApiRecipes
      api :shop
    end
    seen = Queue.new
    threads = %w[alice bob carol].map do |user|
      Thread.new do
        50.times do
          seen << [user, ApiRecipes.shop.with(variables: { account: user }).orders.show(1).run.uri.path]
          own = client.new
          own.shop.variables = { account: user }
          seen << [user, own.shop.orders.show(1).run.uri.path]
        end
      end
    end
    threads.each(&:join)
    results = Array.new(seen.size) { seen.pop }
    expect(results.size).to eq(300)
    expect(results).to all(satisfy { |user, path| path == "/v1/accounts/#{user}/orders/1" })
  end

  it 'keeps a brace written with a backslash as text' do
    configure_test_apis(lit: { host: 'h.test', endpoints: { odd: { path: '/a/\{b}' } } })
    expect(ApiRecipes.lit.odd.url.to_s).to eq('https://h.test/a/%7Bb%7D')
  end
end
