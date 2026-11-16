require 'spec_helper'
require 'stringio'

describe 'default_params, and the headers and parameters of an endpoint' do
  let(:config) do
    { host: 'api.example.test',
      variables: { api_version: { default: '2026-10-01' } },
      default_headers: { 'Accept' => 'application/json', 'X-Api' => 'one' },
      default_params: { 'api-version' => '{api_version}', per_page: 100, archived: false },
      endpoints: {
        issues: {
          default_headers: { 'accept' => 'text/plain' },
          default_params: { state: 'all' },
          endpoints: {
            open: { path: '', default_params: { state: 'open' } },
            show: { path: '/:id', default_headers: { 'X-Api' => 'v{api_version}' } }
          }
        },
        users: nil
      } }
  end
  let(:always) { { 'api-version' => '2026-10-01', 'per_page' => '100', 'archived' => 'false' } }

  before do
    stub_request(:any, /example\.test/).to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })
    configure_test_apis(svc: config)
  end

  # A GET to path: with exactly this query, or with these headers and any query.
  def sent(path, query: nil, headers: nil)
    return a_request(:get, "https://api.example.test#{path}").with(query: query) if query

    a_request(:get, /\Ahttps:\/\/api\.example\.test#{Regexp.escape(path)}(\?|\z)/).with(headers: headers)
  end

  describe 'default_params of the api' do
    it 'sends them with every request, with the variables filled' do
      ApiRecipes.svc.users.run
      expect(sent('/users', query: always)).to have_been_made
    end

    it 'writes them before the params of the request' do
      ApiRecipes.svc.users(params: { q: 'ruby' }).run
      expect(a_request(:get, 'https://api.example.test/users?api-version=2026-10-01&per_page=100&archived=false&q=ruby'))
        .to have_been_made
    end

    it 'lets the params of the request win on the same name, given as a Symbol or as a String' do
      ApiRecipes.svc.users(params: { per_page: 5, q: 'x' }).run
      expect(sent('/users', query: always.merge('per_page' => '5', 'q' => 'x'))).to have_been_made
      ApiRecipes.svc.users(params: { 'archived' => true }).run
      expect(sent('/users', query: always.merge('archived' => 'true'))).to have_been_made
    end

    it 'takes the value of a variable from the nearest level' do
      ApiRecipes.svc.with(variables: { api_version: '2027-01-01' }).users.run
      expect(sent('/users', query: always.merge('api-version' => '2027-01-01'))).to have_been_made
    end

    it 'encodes the name and the value: a value cannot add a parameter' do
      ApiRecipes.svc.with(variables: { api_version: 'x&admin=1#f' }).users.run
      expect(a_request(:get, 'https://api.example.test/users?api-version=x%26admin%3D1%23f&per_page=100&archived=false'))
        .to have_been_made
    end

    it 'raises MissingVariable when a value has no variable' do
      configure_test_apis(svc: { host: 'h.test', variables: { v: {} }, default_params: { v: '{v}' }, endpoints: { users: nil } })
      expect { ApiRecipes.svc.users.run }.to raise_error(ApiRecipes::MissingVariable, /'v'/)
    end

    it 'adds the ones given to with, which win on the same name' do
      ApiRecipes.svc.with(default_params: { per_page: 10, sort: 'name' }).users.run
      expect(sent('/users', query: always.merge('per_page' => '10', 'sort' => 'name'))).to have_been_made
      ApiRecipes.svc.with(default_params: { sort: 'name' }).with(default_params: nil).users.run
      expect(sent('/users', query: always)).to have_been_made
    end

    it 'takes the ones of a class' do
      klass = Class.new do
        include ApiRecipes
        api :svc, default_params: { per_page: 7, mine: 'yes' }
      end
      klass.svc.users.run
      expect(sent('/users', query: always.merge('per_page' => '7', 'mine' => 'yes'))).to have_been_made
    end

    it 'leaves them out of url' do
      expect(ApiRecipes.svc.users.url.to_s).to eq('https://api.example.test/users')
    end

    it 'needs the params of the request to be a Hash' do
      expect { ApiRecipes.svc.users(params: [%w[q ruby]]).run }
        .to raise_error(ApiRecipes::ConfigurationError, /params: must be a Hash when the api has default_params/)
      expect(a_request(:any, /example\.test/)).not_to have_been_made
    end

    it 'does not touch the params of an api without default_params' do
      configure_test_apis(svc: { host: 'api.example.test', endpoints: { users: nil } })
      ApiRecipes.svc.users(params: [%w[q a], %w[q b]]).run
      expect(a_request(:get, 'https://api.example.test/users?q=a&q=b')).to have_been_made
    end
  end

  describe 'on an endpoint' do
    it 'adds its params to those of the api, for itself and for the endpoints below it' do
      ApiRecipes.svc.issues.run
      expect(sent('/issues', query: always.merge('state' => 'all'))).to have_been_made
      ApiRecipes.svc.issues.show(7).run
      expect(sent('/issues/7', query: always.merge('state' => 'all'))).to have_been_made
    end

    it 'lets the nearest endpoint win on the same name' do
      ApiRecipes.svc.issues.open.run
      expect(sent('/issues', query: always.merge('state' => 'open'))).to have_been_made
    end

    it 'wins over the with of the api, and loses to the params of the request' do
      ApiRecipes.svc.with(default_params: { state: 'closed', sort: 'name' }).issues.open.run
      expect(sent('/issues', query: always.merge('state' => 'open', 'sort' => 'name'))).to have_been_made
      ApiRecipes.svc.issues.open(params: { state: 'mine' }).run
      expect(sent('/issues', query: always.merge('state' => 'mine'))).to have_been_made
    end

    it 'adds its headers, and replaces one of the api whatever the case of its name' do
      ApiRecipes.svc.issues.run
      expect(sent('/issues', headers: { 'Accept' => 'text/plain', 'X-Api' => 'one' })).to have_been_made
      ApiRecipes.svc.users.run
      expect(sent('/users', headers: { 'Accept' => 'application/json', 'X-Api' => 'one' })).to have_been_made
    end

    it 'gives its headers to the endpoints below it, with the variables filled' do
      ApiRecipes.svc.issues.show(7).run
      expect(sent('/issues/7', headers: { 'Accept' => 'text/plain', 'X-Api' => 'v2026-10-01' })).to have_been_made
    end

    it 'wins over the with of the api, and loses to the credential and to the headers of the request' do
      ApiRecipes.svc.with(default_headers: { 'ACCEPT' => 'text/csv', 'X-More' => '1' }).issues.run
      expect(sent('/issues', headers: { 'Accept' => 'text/plain', 'X-More' => '1' })).to have_been_made
      ApiRecipes.svc.issues(headers: { 'Accept' => 'text/html' }).run
      expect(sent('/issues', headers: { 'Accept' => 'text/html' })).to have_been_made
    end

    it 'does not let a header of an endpoint take the place of the credential' do
      configure_test_apis(svc: { host: 'api.example.test',
                                 endpoints: { users: { default_headers: { 'authorization' => 'theirs' } } } })
      ApiRecipes.svc.with(authorization: 'Bearer mine').users.run
      expect(sent('/users', headers: { 'Authorization' => 'Bearer mine' })).to have_been_made
    end
  end

  describe 'the name of a header, which has no case and reads _ as -' do
    def headers_of(api, *path)
      endpoint = path.reduce(api) { |node, name| node[name] }
      endpoint.run
      WebMock::RequestRegistry.instance.requested_signatures.hash.keys.last.headers
    end

    it 'is replaced by with, and by a second with' do
      ApiRecipes.svc.with(default_headers: { 'ACCEPT' => 'text/csv' }).users.run
      expect(sent('/users', headers: { 'Accept' => 'text/csv', 'X-Api' => 'one' })).to have_been_made
      api = ApiRecipes.svc.with(default_headers: { 'X-New' => 'a' }).with(default_headers: { 'x_new' => 'b' })
      expect(headers_of(api, :users)).to include('X-New' => 'b')
    end

    it 'is replaced by the options of a class, on the api and on an endpoint' do
      klass = Class.new do
        include ApiRecipes
        api :svc, default_headers: { 'accept' => 'text/csv' },
                  endpoints: { issues: { default_headers: { 'ACCEPT' => 'text/html' } } }
      end
      expect(headers_of(klass.svc, :users)).to include('Accept' => 'text/csv', 'X-Api' => 'one')
      expect(headers_of(klass.svc, :issues)).to include('Accept' => 'text/html')
      expect(klass.svc.definition.default_headers.keys).to eq(%w[X-Api accept])
    end

    it 'is replaced by an endpoint that writes it with _' do
      configure_test_apis(svc: { host: 'api.example.test', default_headers: { 'x-api-key' => 'api' },
                                 endpoints: { users: { default_headers: { 'X_API_KEY' => 'endpoint' } } } })
      expect(headers_of(ApiRecipes.svc, :users)).to include('X-Api-Key' => 'endpoint')
    end

    it 'cannot be given twice in one place' do
      twice = "is given twice, as 'Accept' and as 'accept': the name of a header has no case, and _ is read as -"
      expect { configure_test_apis(svc: { host: 'h.test', default_headers: { 'Accept' => 'a', 'accept' => 'b' } }) }
        .to raise_error(ApiRecipes::ConfigurationError) { |e| expect(e.errors).to eq(["svc.default_headers.accept: #{twice}"]) }
      expect { ApiRecipes.svc.with(default_headers: { 'Accept' => 'a', 'accept' => 'b' }) }
        .to raise_error(ApiRecipes::ConfigurationError, /default_headers\.accept: is given twice/)
    end
  end

  it 'refuses, when the class is declared, default_params that name the parameter of the credential of the api' do
    configure_test_apis(svc: { host: 'api.example.test', auth: { type: 'query', name: 'key' }, endpoints: { users: nil } })
    declare = lambda do |options|
      Class.new do
        include ApiRecipes
        api :svc, **options
      end
    end
    expect { declare.call(default_params: { key: 'x' }) }
      .to raise_error(ApiRecipes::ConfigurationError, /default_params\.key: is the parameter of the credential/)
    expect { declare.call(endpoints: { users: { default_params: { 'key' => 'x' } } }) }
      .to raise_error(ApiRecipes::ConfigurationError, /endpoints\.users\.default_params\.key: is the parameter of the credential/)
    expect { declare.call(auth: { type: 'header', name: 'X-Key' }, default_params: { key: 'x' }) }.not_to raise_error
  end

  describe 'with a credential in the query' do
    let(:keyed) do
      { host: 'api.example.test', auth: { type: 'query', name: 'key' }, default_params: { page: 1 },
        endpoints: { users: { default_params: { size: 2 } } } }
    end

    it 'writes the credential last' do
      configure_test_apis(svc: keyed)
      ApiRecipes.svc.with(authorization: 'S3CRET').users(params: { q: 'x' }).run
      expect(a_request(:get, 'https://api.example.test/users?page=1&size=2&q=x&key=S3CRET')).to have_been_made
    end

    it 'refuses default_params that name the parameter of the credential, on the api and on an endpoint' do
      keyed[:default_params] = { 'key' => 'theirs' }
      keyed[:endpoints][:users][:default_params] = { key: 'theirs' }
      expect { configure_test_apis(svc: keyed) }
        .to raise_error(ApiRecipes::ConfigurationError) { |e|
          expect(e.errors).to eq(["svc.default_params.key: is the parameter of the credential (auth.name): it cannot be set here",
                                  "svc.endpoints.users.default_params.key: is the parameter of the credential (auth.name): it cannot be set here"])
        }
    end

    it 'sends only the credential when with gives a parameter with its name' do
      configure_test_apis(svc: keyed)
      ApiRecipes.svc.with(authorization: 'S3CRET', default_params: { key: 'theirs' }).users.run
      expect(a_request(:get, 'https://api.example.test/users?page=1&size=2&key=S3CRET')).to have_been_made
    end
  end

  describe 'what is shown' do
    let(:secret) do
      { host: 'api.example.test', default_params: { token: 'S3CRET-PARAM' },
        endpoints: { users: { default_params: { other: 'S3CRET-OTHER' }, default_headers: { 'X-Key' => 'S3CRET-HEADER' } } } }
    end

    it 'hides the values in definition and in inspect' do
      configure_test_apis(svc: secret)
      definition = ApiRecipes.svc.definition
      expect(definition.to_h[:default_params]).to eq('token' => '[FILTERED]')
      users = definition.endpoints[:users]
      expect(users.to_h.values_at(:default_params, :default_headers)).to eq([{ 'other' => '[FILTERED]' }, { 'X-Key' => '[FILTERED]' }])
      shown = [definition.inspect, users.inspect, definition.to_json, ApiRecipes.svc.inspect, ApiRecipes.svc.users.inspect].join
      expect(shown).not_to match(/S3CRET/)
    end

    it 'gives the values to the readers of the definition, as for default_headers' do
      configure_test_apis(svc: secret)
      definition = ApiRecipes.svc.definition
      expect(definition.default_params).to eq('token' => 'S3CRET-PARAM')
      expect(definition.endpoints[:users].default_params).to eq('other' => 'S3CRET-OTHER')
      expect(definition.endpoints[:users].default_headers).to eq('X-Key' => 'S3CRET-HEADER')
      expect(definition.endpoints[:users].default_params).to be_frozen
    end

    it 'keeps the values out of the log and of the errors' do
      log = StringIO.new
      ApiRecipes.configure do |c|
        c.logger = Logger.new(log)
        c.print_urls = true
        c.apis_configs = { svc: secret }
      end
      stub_request(:get, /example\.test/).to_return(status: 500, body: 'no')
      expect { ApiRecipes.svc.users.run }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected) { |e|
        expect("#{e.message} #{e.inspect} #{e.response.inspect}").not_to match(/S3CRET/)
      }
      expect(log.string).not_to match(/S3CRET/)
      expect(log.string).to include('https://api.example.test/users')
    end
  end

  describe 'validation' do
    def problems(api)
      configure_test_apis(svc: api)
      []
    rescue ApiRecipes::ConfigurationError => e
      e.errors
    end

    it 'accepts text, numbers and booleans, and names with any visible character' do
      expect(problems(host: 'h.test', default_params: { 'page[size]' => 10, 'a b' => :x, flag: true, f: 1.5 })).to eq([])
    end

    it 'reports what is not a Hash, an empty name, a name with a control character and a value that is not a scalar' do
      expect(problems(host: 'h.test', default_params: 'x')).to eq(['svc.default_params: must be a Hash'])
      expect(problems(host: 'h.test', default_params: { '' => 1 })).to eq(['svc.default_params: a parameter name must not be empty'])
      expect(problems(host: 'h.test', default_params: { "a\nb" => 1 }))
        .to eq(['svc.default_params.a?b: the name must not contain control characters'])
      expect(problems(host: 'h.test', default_params: { list: [1], map: { a: 1 } }))
        .to eq(['svc.default_params.list: must be a string, a number or a boolean',
                'svc.default_params.map: must be a string, a number or a boolean'])
    end

    it 'reports a variable that the api does not declare, on the api and on an endpoint' do
      api = { host: 'h.test', default_params: { v: '{version}' },
              endpoints: { users: { default_params: { z: '{zone}' }, default_headers: { 'X-Zone' => '{zone}' } } } }
      expect(problems(api)).to eq(["svc.default_params.v: unknown variable 'version'",
                                   "svc.endpoints.users.default_headers.X-Zone: unknown variable 'zone'",
                                   "svc.endpoints.users.default_params.z: unknown variable 'zone'"])
    end

    it 'checks the headers of an endpoint as those of the api' do
      api = { host: 'h.test', endpoints: { users: { default_headers: { 'bad name' => 'x', 'X-A' => "a\nb" } } } }
      expect(problems(api)).to eq(['svc.endpoints.users.default_headers.bad name: is not a valid header name',
                                   'svc.endpoints.users.default_headers.X-A: must not contain control characters'])
    end

    it 'refuses them in the with of an endpoint, which has headers: and params: for one request' do
      configure_test_apis(svc: config)
      expect { ApiRecipes.svc.users.with(default_params: { a: 1 }) }
        .to raise_error(ApiRecipes::ConfigurationError, /unknown option 'default_params'/)
    end
  end
end
