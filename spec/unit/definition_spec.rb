require 'spec_helper'

describe 'ApiRecipes::Definition' do
  let(:api) do
    ApiRecipes::Compiler.compile(:svc, host: 'api.example.test',
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
    nested = ApiRecipes::Compiler.compile(:svc, endpoints: { users: { path: '/users/:uid', endpoints: { show: { path: ':id' } } } })
    expect(nested.routes.map(&:call)).to eq(['svc.users(uid)', 'svc.users(uid).show(id)'])
  end
end
