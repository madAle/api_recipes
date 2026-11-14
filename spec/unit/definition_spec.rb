require 'spec_helper'

describe 'ApiRecipes::Internals::Definition' do
  let(:api) do
    ApiRecipes::Internals::Compiler.compile(:svc, host: 'api.example.test',
      endpoints: { users: { endpoints: { show: { path: '/:id' } } }, group: { route: false, endpoints: { ping: {} } } })
  end

  it 'lists the routes' do
    expect(api.routes.map(&:to_a)).to eq([
      ['svc.users', :get, 'https://api.example.test/users'],
      ['svc.users.show(id)', :get, 'https://api.example.test/users/:id'],
      ['svc.group.ping', :get, 'https://api.example.test/group/ping']
    ])
  end

  it 'exports plain data' do
    expect(api.to_h).to include(name: :svc, host: 'api.example.test')
    expect(api.endpoints[:users].to_h).to include(name: :users, verb: :get, path: 'users')
    expect(api.endpoints[:users].parent).to equal(api)
  end

  it 'exports data that can be changed without touching the definition' do
    data = api.to_h
    data[:endpoints][:users][:path_params] << :x
    data[:default_headers]['A'] = 'b'
    expect(api.endpoints[:users].path_params).to eq([])
    expect(api.default_headers).to eq({})
  end

  it 'writes the parameters of every step in the call of a route' do
    nested = ApiRecipes::Internals::Compiler.compile(:svc, endpoints: { users: { path: '/users/:uid', endpoints: { show: { path: ':id' } } } })
    expect(nested.routes.map(&:call)).to eq(['svc.users(uid)', 'svc.users(uid).show(id)'])
  end

  describe 'what is shown' do
    let(:secret_api) do
      ApiRecipes::Internals::Compiler.compile(:svc, host: 'api.example.test', port: 8443,
        default_headers: { 'Authorization' => 'Bearer s3cret' },
        endpoints: { users: { endpoints: { show: { path: '/:id' } } }, repos: nil })
    end

    it 'inspects without header values or the tree' do
      expect(secret_api.inspect).to eq('#<ApiRecipes::Internals::Definition::Api svc https://api.example.test:8443 endpoints: users, repos>')
      show = secret_api.endpoints[:users].endpoints[:show]
      expect(show.inspect).to eq('#<ApiRecipes::Internals::Definition::Endpoint svc.users.show GET /users/:id>')
      expect([secret_api.inspect, show.inspect, secret_api.endpoints[:users].inspect].join).not_to include('s3cret')
    end

    it 'pretty prints like inspect' do
      require 'pp'
      expect(secret_api.pretty_inspect.strip).to eq(secret_api.inspect)
      show = secret_api.endpoints[:users].endpoints[:show]
      expect(show.pretty_inspect.strip).to eq(show.inspect)
    end

    it 'filters header values in to_h and keeps the real ones in the reader' do
      expect(secret_api.to_h[:default_headers]).to eq('Authorization' => '[FILTERED]')
      expect(secret_api.to_h.to_s).not_to include('s3cret')
      expect(secret_api.default_headers).to eq('Authorization' => 'Bearer s3cret')
    end
  end
end
