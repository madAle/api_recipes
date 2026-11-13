require 'spec_helper'
require 'pp'
require 'yaml'

describe 'Endpoint and api names' do
  def api(endpoints)
    configure_test_apis(svc: { host: 'h.test', endpoints: endpoints })
    ApiRecipes.svc
  end

  def configure_with(logger, apis)
    ApiRecipes.configure do |config|
      config.logger = logger
      config.apis_configs = apis
    end
  end

  it 'reaches every node with []' do
    svc = api(users: { endpoints: { show: { path: '/:id' } } })
    expect(svc[:users][:show, 7].url.to_s).to eq('https://h.test/users/7')
    expect(svc[:users][:show, 7, { params: { a: 1 } }].url.to_s).to eq(svc.users.show(7).url.to_s)
    expect { svc[:nope] }.to raise_error(ApiRecipes::UnknownEndpoint, /Available: users/)
    expect(ApiRecipes[:svc]).to equal(ApiRecipes.svc)
    expect(ApiRecipes.apis).to eq([:svc])
  end

  it 'generates the methods once, not at every call' do
    svc = api(users: { endpoints: { show: { path: '/:id' } } })
    expect(svc.users.class).to equal(svc.users.class)
    expect(svc.users.singleton_methods).to eq([])
    expect(svc.users).to respond_to(:show)
  end

  it 'returns the response from run, with or without a block' do
    stub_request(:get, 'https://h.test/users').to_return(status: 200, body: '')
    seen = nil
    result = api(users: nil).users.run { |response| seen = response }
    expect(result).to be_a(ApiRecipes::Response).and(equal(seen))
  end

  %i[url run with definition class send display inspect].each do |name|
    it "keeps an endpoint called #{name} reachable with [] and warns once" do
      logger = Logger.new(IO::NULL)
      expect(logger).to receive(:warn).with(/endpoint '#{name}' has the name of an existing method/).once
      configure_with(logger, svc: { host: 'h.test', endpoints: { parent: { endpoints: { name => nil } } } })
      expect(ApiRecipes.svc.parent[name].url.to_s).to eq("https://h.test/parent/#{name}")
    end
  end

  (Kernel.private_instance_methods - ApiRecipes::Handles::RESERVED).each do |name|
    next unless name.match?(/\A[a-z_]\w*\z/)

    it "accepts #{name} as an endpoint method" do
      svc = api(name => { endpoints: { child: nil } })
      expect(svc.public_send(name).child.url.to_s).to eq("https://h.test/#{name}/child")
    end
  end

  %w[pull-requests 2fa end name params route children api object configs].each do |name|
    it "accepts the endpoint name #{name} without a warning" do
      logger = Logger.new(IO::NULL)
      expect(logger).not_to receive(:warn)
      configure_with(logger, svc: { host: 'h.test', endpoints: { parent: { endpoints: { name => nil } } } })
      expect(ApiRecipes.svc.parent[name.to_sym].url.to_s).to eq("https://h.test/parent/#{name}")
    end
  end

  it 'keeps an api called like a method of the module reachable with []' do
    logger = Logger.new(IO::NULL)
    expect(logger).to receive(:warn).with(/configure/)
    configure_with(logger, configure: { host: 'h.test', endpoints: { ping: nil } })
    expect(ApiRecipes[:configure].ping.url.to_s).to eq('https://h.test/ping')
    expect(ApiRecipes.configure).to equal(ApiRecipes.configuration)
  end

  it 'shows itself without secrets' do
    svc = api(users: { endpoints: { show: { path: '/:id' } } })
    svc.authorization = 'Bearer SECRET'
    expect(svc.inspect).to eq('#<ApiRecipes::Api svc https://h.test endpoints: users>')
    expect(svc.users.show(7, params: { token: 'SECRET' }).inspect)
      .to eq('#<ApiRecipes::Endpoint svc.users.show GET https://h.test/users/7>')
  end

  it 'keeps the previous configuration when the new one is invalid' do
    api(users: nil)
    expect { ApiRecipes.configure { |c| c.apis_configs = { svc: { bogus: 1 } } } }.to raise_error(ApiRecipes::ConfigurationError)
    expect(ApiRecipes.svc.users.url.to_s).to eq('https://h.test/users')
  end

  it 'raises UnknownEndpoint for any unknown name, and shows a name that is not plain text with inspect' do
    svc = api(users: nil)
    ["a\nb", "caf\xC3", nil, 42, :nope].each do |name|
      expect { svc[name] }.to raise_error(ApiRecipes::UnknownEndpoint) { |e| expect(e.message).not_to include("\n") }
      expect { ApiRecipes[name] }.to raise_error(ApiRecipes::UnknownEndpoint, /Available: svc/)
    end
    expect { svc["a\nb"] }.to raise_error(ApiRecipes::UnknownEndpoint, /'"a\\nb"'/)
    expect(svc['users'].url.to_s).to eq('https://h.test/users')
    expect(ApiRecipes['svc']).to equal(ApiRecipes.svc)
  end

  it 'writes no secret through pp or to_s, and cannot be serialized with Marshal or YAML' do
    configure_test_apis(svc: { host: 'h.test', default_headers: { 'X-Key' => 'HEADER' }, endpoints: { users: nil } })
    api = ApiRecipes.svc.with(authorization: 'Bearer TOKEN', default_headers: { 'X-Other' => 'OTHER' })
    [api, api.users(params: { token: 'QUERY' }).with(timeout: 5)].each do |object|
      expect([object.pretty_inspect, object.to_s, "#{object}"].join).not_to match(/HEADER|TOKEN|OTHER|QUERY/)
      expect { Marshal.dump(object) }.to raise_error(TypeError)
      expect { YAML.dump(object) }.to raise_error(TypeError)
    end
  end

  it 'shows a host whose variables have no valid value as written' do
    configure_test_apis(shopify: { host: '{shop}.example.test', variables: { shop: {} }, endpoints: { orders: nil } })
    shopify = ApiRecipes.shopify
    expect(shopify.inspect).to eq('#<ApiRecipes::Api shopify https://{shop}.example.test endpoints: orders>')
    expect(shopify.orders.inspect).to eq('#<ApiRecipes::Endpoint shopify.orders GET https://{shop}.example.test/orders>')
    expect(shopify.with(variables: { shop: 'evil.test/x' }).orders.inspect).to include('https://{shop}.example.test/orders')
    expect(shopify.with(variables: { shop: 'acme' }).inspect).to include('https://acme.example.test')
  end

  it 'generates module methods for apis named like private methods of Kernel, not like other methods of the module' do
    logger = Logger.new(IO::NULL)
    allow(logger).to receive(:warn)
    configure_with(logger, test: { host: 'h.test', endpoints: { ping: nil } }, singleton_method_added: {}, raise: {},
                           inspect: {})
    %i[singleton_method_added raise inspect].each do |name|
      expect(logger).to have_received(:warn)
        .with("api '#{name}' has the name of a method of ApiRecipes; reach it with ApiRecipes[:#{name}]")
      expect(ApiRecipes[name]).to be_a(ApiRecipes::Api)
    end
    expect(logger).to have_received(:warn).exactly(3).times
    expect(ApiRecipes.public_send(:test).ping.url.to_s).to eq('https://h.test/ping')
    expect(ApiRecipes.inspect).to eq('ApiRecipes')
    expect { ApiRecipes[:nope] }.to raise_error(ApiRecipes::UnknownEndpoint)
  end

  it 'removes the methods of the apis that a new configuration drops' do
    configure_test_apis
    configure_test_apis(other: { host: 'h.test' })
    expect(ApiRecipes).not_to respond_to(:svc)
    expect(ApiRecipes.other).to equal(ApiRecipes[:other])
    expect { ApiRecipes[:svc] }.to raise_error(ApiRecipes::UnknownEndpoint)
  end
end
