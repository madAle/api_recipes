require 'spec_helper'

describe 'URL building' do
  def api(configs)
    configure_test_apis(svc: configs)
    ApiRecipes.svc
  end

  describe 'api options' do
    it 'defaults to https on localhost' do
      expect(api(endpoints: { ping: nil }).ping.url.to_s).to eq('https://localhost/ping')
    end

    it 'uses protocol http' do
      expect(api(protocol: 'http', host: 'h.test', endpoints: { ping: nil }).ping.url.to_s)
        .to eq('http://h.test/ping')
    end

    it 'adds the port when one is given' do
      expect(api(host: 'h.test', port: 8443, endpoints: { ping: nil }).ping.url.to_s)
        .to eq('https://h.test:8443/ping')
    end

    it 'accepts underscores in the host name' do
      expect(api(protocol: 'http', host: 'web_service_1', port: 3000, endpoints: { ping: nil }).ping.url.to_s)
        .to eq('http://web_service_1:3000/ping')
    end

    it 'prefixes every path with base_url' do
      svc = api(host: 'h.test', base_url: 'api/v2', endpoints: { users: { endpoints: { show: { path: '/:id' } } } })
      expect(svc.users.url.to_s).to eq('https://h.test/api/v2/users')
      expect(svc.users.show(7).url.to_s).to eq('https://h.test/api/v2/users/7')
    end

    it 'ends the url of a root endpoint with an empty path with a slash, as 2.x did' do
      svc = api(host: 'h.test', base_url: 'api/v2',
                endpoints: { root: { path: '', endpoints: { same: { path: '' }, kid: nil } }, users: nil })
      expect(svc.root.url.to_s).to eq('https://h.test/api/v2/')
      expect(svc.root.same.url.to_s).to eq('https://h.test/api/v2/')
      expect(svc.root.kid.url.to_s).to eq('https://h.test/api/v2/kid')
      expect(svc.root.definition.full_path).to eq('/api/v2/')
      expect(svc.users.url.to_s).to eq('https://h.test/api/v2/users')
      expect(api(host: 'h.test', endpoints: { root: { path: '' } }).root.url.to_s).to eq('https://h.test/')
    end

    it 'does not add a slash to a nested endpoint with an empty path' do
      svc = api(host: 'h.test', base_url: 'api/v2', endpoints: { users: { endpoints: { all: { path: '' } } } })
      expect(svc.users.all.url.to_s).to eq('https://h.test/api/v2/users')
    end

    it 'ignores extra slashes around base_url' do
      expect(api(host: 'h.test', base_url: '/v1/', endpoints: { ping: nil }).ping.url.to_s)
        .to eq('https://h.test/v1/ping')
    end
  end

  describe 'endpoint paths' do
    let(:svc) do
      api(host: 'h.test', endpoints: {
            people: { path: '/users' },
            repos: {
              route: false, path: '/repos/:owner/:repo',
              endpoints: {
                show: { path: '' },
                contributors: nil,
                issues: { endpoints: { comments: { path: '/:number/comments', endpoints: { show: { path: '/:id' } } } } }
              }
            }
          })
    end

    it 'uses the endpoint name when no path is given' do
      expect(svc.repos('rails', 'rails').contributors.url.to_s).to eq('https://h.test/repos/rails/rails/contributors')
    end

    it 'uses path instead of the endpoint name' do
      expect(svc.people.url.to_s).to eq('https://h.test/users')
    end

    it 'shares the url of the parent with an empty path' do
      expect(svc.repos('rails', 'rails').show.url.to_s).to eq('https://h.test/repos/rails/rails')
    end

    it 'fills several parameters in order' do
      expect(svc.repos('owner', 'name').show.url.to_s).to eq('https://h.test/repos/owner/name')
    end

    it 'chains endpoints nested on several levels, each with its own parameters' do
      expect(svc.repos('rails', 'rails').issues.comments(12).show(34).url.to_s)
        .to eq('https://h.test/repos/rails/rails/issues/12/comments/34')
    end

    it 'accepts numbers and symbols as parameter values' do
      expect(svc.repos(:rails, 42).show.url.to_s).to eq('https://h.test/repos/rails/42')
    end

    it 'says which parameters are missing' do
      expect { svc.repos('rails').show }
        .to raise_error(ApiRecipes::PathParamsMismatch, /requires params \[:owner, :repo\]/)
    end

    it 'says when an endpoint takes no parameters' do
      expect { svc.people(1) }.to raise_error(ApiRecipes::PathParamsMismatch, /requires NO PARAMS/)
    end
  end

  describe 'the route option' do
    { 'yes' => true, true => true, 'no' => false, false => false }.each do |value, callable|
      it "#{callable ? 'creates' : 'does not create'} a route for route: #{value.inspect}" do
        svc = api(host: 'h.test', endpoints: { group: { route: value, endpoints: { ping: nil } } })
        if callable
          expect(svc.group.url.to_s).to eq('https://h.test/group')
        else
          expect(svc.group.url).to be_nil
          expect { svc.group.run }.to raise_error(ApiRecipes::NoRouteExists)
        end
        expect(svc.group.ping.url.to_s).to eq('https://h.test/group/ping')
      end
    end

    it 'creates a route by default' do
      expect(api(host: 'h.test', endpoints: { ping: {} }).ping.definition.route?).to eq(true)
    end
  end
end
