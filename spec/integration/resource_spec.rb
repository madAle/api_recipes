require 'spec_helper'

describe 'resource: the endpoints of a REST resource from one word' do
  def configure_shop(endpoints)
    configure_test_apis(shop: { host: 'shop.example.test', base_url: 'v1', endpoints: endpoints })
    ApiRecipes.shop
  end

  def routes(api = ApiRecipes.shop)
    api.definition.routes.map { |route| [route.call, route.verb, route.url.delete_prefix('https://shop.example.test')] }
  end

  def problems(endpoints)
    configure_shop(endpoints)
    []
  rescue ApiRecipes::ConfigurationError => e
    e.errors
  end

  before do
    stub_request(:any, /shop\.example\.test/).to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })
  end

  it 'adds show, create, update, replace and delete under the endpoint, which stays the list' do
    configure_shop(orders: { resource: true })
    expect(routes).to eq([
      ['shop.orders', :get, '/v1/orders'],
      ['shop.orders.show(id)', :get, '/v1/orders/:id'],
      ['shop.orders.create', :post, '/v1/orders'],
      ['shop.orders.update(id)', :patch, '/v1/orders/:id'],
      ['shop.orders.replace(id)', :put, '/v1/orders/:id'],
      ['shop.orders.delete(id)', :delete, '/v1/orders/:id']
    ])
  end

  it 'sends each request with its verb to its path' do
    api = configure_shop(orders: { resource: true })
    api.orders.run
    api.orders.show(7).run
    api.orders.create(json: { total: 10 }).run
    api.orders.update(7, json: { total: 11 }).run
    api.orders.replace(7, json: { total: 12 }).run
    api.orders.delete(7).run
    expect(a_request(:get, 'https://shop.example.test/v1/orders')).to have_been_made
    expect(a_request(:get, 'https://shop.example.test/v1/orders/7')).to have_been_made
    expect(a_request(:post, 'https://shop.example.test/v1/orders').with(body: '{"total":10}')).to have_been_made
    expect(a_request(:patch, 'https://shop.example.test/v1/orders/7').with(body: '{"total":11}')).to have_been_made
    expect(a_request(:put, 'https://shop.example.test/v1/orders/7').with(body: '{"total":12}')).to have_been_made
    expect(a_request(:delete, 'https://shop.example.test/v1/orders/7')).to have_been_made
  end

  it 'reads yes and no as true and false, and adds nothing for false' do
    configure_shop(orders: { resource: 'yes' }, users: { resource: 'no' }, items: { resource: false })
    expect(routes.map(&:first)).to eq(%w[shop.orders shop.orders.show(id) shop.orders.create shop.orders.update(id)
                                         shop.orders.replace(id) shop.orders.delete(id) shop.users shop.items])
  end

  it 'adds only the endpoints of a list, in the usual order' do
    configure_shop(orders: { resource: %w[delete show] }, users: { resource: [:create] })
    expect(routes.map(&:first)).to eq(%w[shop.orders shop.orders.show(id) shop.orders.delete(id) shop.users shop.users.create])
  end

  it 'leaves the options of the endpoint as they are: its path, its route, its verb' do
    configure_shop(orders: { resource: true, path: '/shops/:shop/orders', route: false })
    expect(routes).to eq([
      ['shop.orders(shop).show(id)', :get, '/v1/shops/:shop/orders/:id'],
      ['shop.orders(shop).create', :post, '/v1/shops/:shop/orders'],
      ['shop.orders(shop).update(id)', :patch, '/v1/shops/:shop/orders/:id'],
      ['shop.orders(shop).replace(id)', :put, '/v1/shops/:shop/orders/:id'],
      ['shop.orders(shop).delete(id)', :delete, '/v1/shops/:shop/orders/:id']
    ])
  end

  it 'completes a generated endpoint with the options written for it: they win, the others stay' do
    api = configure_shop(orders: { resource: true, endpoints: {
                           show: { path: '/:slug', timeout: 9 },
                           delete: { ok_code: 204 },
                           create: nil,
                           update: { path: nil, verb: 'post' }
                         } })
    orders = api.definition.endpoints[:orders].endpoints
    expect(orders[:show].to_h.values_at(:path, :verb, :timeout)).to eq(['/:slug', :get, 9])
    expect(orders[:delete].to_h.values_at(:path, :verb, :ok_code)).to eq(['/:id', :delete, 204])
    expect(orders[:create].to_h.values_at(:path, :verb)).to eq(['', :post])
    expect(orders[:update].to_h.values_at(:path, :verb)).to eq(['/:id', :post])
    expect(orders.keys).to eq(%i[show create update replace delete])
  end

  it 'adds the other endpoints written by hand after the generated ones, with their own children' do
    configure_shop(orders: { resource: %w[show], endpoints: {
                     search: nil,
                     show: { endpoints: { items: { resource: %w[show] } } }
                   } })
    expect(routes).to eq([
      ['shop.orders', :get, '/v1/orders'],
      ['shop.orders.show(id)', :get, '/v1/orders/:id'],
      ['shop.orders.show(id).items', :get, '/v1/orders/:id/items'],
      ['shop.orders.show(id).items.show(id)', :get, '/v1/orders/:id/items/:id'],
      ['shop.orders.search', :get, '/v1/orders/search']
    ])
  end

  it 'gives the generated endpoints the headers and the parameters of the endpoint' do
    api = configure_shop(orders: { resource: %w[show], default_params: { expand: 'items' },
                                   default_headers: { 'Accept' => 'application/vnd.shop+json' } })
    api.orders.show(7).run
    expect(a_request(:get, 'https://shop.example.test/v1/orders/7?expand=items')
      .with(headers: { 'Accept' => 'application/vnd.shop+json' })).to have_been_made
  end

  it 'is expanded after the options of a class are merged' do
    configure_shop(orders: { resource: true })
    klass = Class.new do
      include ApiRecipes
      api :shop, endpoints: { orders: { resource: %w[show create], endpoints: { show: { path: '/:number' } } } }
    end
    expect(routes(klass.shop)).to eq([
      ['shop.orders', :get, '/v1/orders'],
      ['shop.orders.show(number)', :get, '/v1/orders/:number'],
      ['shop.orders.create', :post, '/v1/orders']
    ])
    off = Class.new do
      include ApiRecipes
      api :shop, endpoints: { orders: { resource: false } }
    end
    expect(routes(off.shop)).to eq([['shop.orders', :get, '/v1/orders']])
  end

  it 'does not appear in the definition: the tree holds plain endpoints' do
    api = configure_shop(orders: { resource: true })
    expect(api.definition.endpoints[:orders].to_h).not_to have_key(:resource)
    expect(api.definition.endpoints[:orders].own(:resource)).to be_nil
  end

  it 'never reads a verb from the name of an endpoint written by hand' do
    configure_shop(orders: { endpoints: { delete: nil, create: nil } })
    expect(routes.map { |route| route[1] }).to eq(%i[get get get])
  end

  it 'reports a value that is not true, false or a list of its endpoints' do
    message = 'must be true, false or a list of: show, create, update, replace, delete'
    [1, 'all', [], %w[show destroy], [1], { show: true }].each do |value|
      expect(problems(orders: { resource: value })).to eq(["shop.endpoints.orders.resource: #{message}"])
    end
  end

  it 'reports the problems of a generated endpoint at its place' do
    expect(problems(orders: { resource: true, endpoints: { show: 5, delete: { verb: 'burn' } } }))
      .to eq(['shop.endpoints.orders.endpoints.show: must be a Hash or empty',
              "shop.endpoints.orders.endpoints.delete.verb: 'burn' is not a verb known to http.rb"])
    expect(problems(orders: { resource: true, endpoints: 'x' })).to eq(['shop.endpoints.orders.endpoints: must be a Hash'])
  end

  it 'is not an option of the api or of with' do
    expect { configure_test_apis(shop: { host: 'h.test', resource: true }) }
      .to raise_error(ApiRecipes::ConfigurationError, /shop: unknown option 'resource'/)
    api = configure_shop(orders: { resource: true })
    expect { api.orders.with(resource: true) }.to raise_error(ApiRecipes::ConfigurationError, /unknown option 'resource'/)
  end
end
