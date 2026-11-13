require 'spec_helper'

describe ApiRecipes::Compiler do
  def compile(config) = described_class.compile(:svc, config)

  def problems(config)
    compile(config)
    []
  rescue ApiRecipes::ConfigurationError => e
    e.errors
  end

  it 'applies the defaults' do
    api = compile({})
    expect([api.protocol, api.host, api.port, api.timeout, api.on_bad_code]).to eq(['https', 'localhost', nil, 3, 'raise'])
    expect(api.endpoints).to eq({})
  end

  it 'builds the tree with resolved options' do
    api = compile('host' => 'h.test', 'base_url' => '/v1/', timeout: 10, verify_with: 'check',
                  endpoints: { users: { timeout: 1, endpoints: { show: { path: '/:id', verb: 'POST' }, list: nil } } })
    users = api.endpoints[:users]
    show = users.endpoints[:show]
    expect(users.full_name).to eq('svc.users')
    expect(show.full_path).to eq('/v1/users/:id')
    expect(show.path_params).to eq(%i[id])
    expect(show.verb).to eq(:post)
    expect([users.timeout, show.timeout]).to eq([1, 10])   # timeout comes from the api, not from the parent
    expect(users.own(:timeout)).to eq(1)
    expect(show.own(:timeout)).to be_nil
    expect(show.verify_with).to eq(:check)
    expect(users.endpoints[:list].route?).to eq(true)
    expect([api, api.endpoints, users, show]).to all(be_frozen)
  end

  it 'hands verify_with down from the parent, also to an endpoint written without options' do
    api = compile(verify_with: :api_check, endpoints: { a: { verify_with: :a_check, endpoints: { b: nil, c: {} } } })
    expect(api.endpoints[:a].endpoints[:b].verify_with).to eq(:a_check)
    expect(api.endpoints[:a].endpoints[:c].own(:verify_with)).to eq(:a_check)
  end

  it 'reports every problem at once, with its place' do
    errors = problems(host: 'h.test', endpoints: { users: { method: :post, on_bad_code: 'explode' } })
    expect(errors).to contain_exactly(
      "svc.endpoints.users: unknown option 'method'",
      "svc.endpoints.users.on_bad_code: 'explode' is not one of raise, ignore"
    )
  end

  {
    { protocol: 'ftp' }                            => /svc\.protocol/,
    { host: 'h.test/path' }                        => /svc\.host/,
    { host: 'user@h.test' }                        => /svc\.host/,
    { host: "h.test\nevil.test" }                  => /svc\.host/,
    { host: 'città.test' }                         => /svc\.host/,
    { port: 0 }                                    => /svc\.port/,
    { timeout: 'soon' }                            => /svc\.timeout/,
    { bogus: 1 }                                   => /svc: unknown option 'bogus'/,
    { default_headers: { 'X' => "a\r\nY: b" } }    => /svc\.default_headers/,
    { verify_with: 'not a method!' }               => /svc\.verify_with/,
    { host: '{shop}.h.test' }                      => /svc\.host: unknown variable 'shop'/,
    { auth: { type: 'header' } }                   => /svc\.auth/,
    { auth: { type: 'magic' } }                    => /svc\.auth/,
    { endpoints: { a: 'text' } }                   => /svc\.endpoints\.a/,
    { endpoints: { a: { verb: 'fetch' } } }        => /svc\.endpoints\.a\.verb/,
    { endpoints: { a: { route: 'maybe' } } }       => /svc\.endpoints\.a\.route/,
    { endpoints: { a: { ok_code: '200' } } }       => /svc\.endpoints\.a\.ok_code/,
    { endpoints: { a: { path: '/:id/:id' } } }     => /svc\.endpoints\.a\.path/
  }.each do |config, pattern|
    it "rejects #{config.inspect}" do
      expect(problems(config)).to include(match(pattern))
    end
  end

  it 'accepts what is valid today' do
    valid = { protocol: :http, host: 'web_service_1', port: 3000, on_bad_code: :ignore, 'x-note' => 'free',
              endpoints: { a: { route: 'no', ok_code: [200, 201], 'x-doc' => 1, endpoints: { b: { route: true } } } } }
    expect(problems(valid)).to eq([])
  end

  it 'accepts auth, variables and recipe' do
    api = compile(host: '{shop}.myshopify.com', base_url: 'admin/{version}',
                  auth: { type: 'header', name: 'X-Shopify-Access-Token' },
                  variables: { shop: { description: 'd' }, version: { default: '2026-10' } },
                  recipe: { name: 'shopify', version: '1.0.0' })
    expect(api.auth).to eq(type: :header, name: 'X-Shopify-Access-Token')
    expect(api.variables[:version][:default]).to eq('2026-10')
    expect(api.host_template.names).to eq(%i[shop])
  end

  it 'collects the problems of every api' do
    expect { described_class.compile_all(a: { bogus: 1 }, b: { protocol: 'ftp' }) }
      .to raise_error(ApiRecipes::ConfigurationError) { |e| expect(e.errors.size).to eq(2) }
  end

  it 'checks the options allowed in with' do
    expect(described_class.check_options({ timeout: 5, host: 'h.test' }, :with_api)).to eq([])
    expect(described_class.check_options({ endpoints: {} }, :with_api)).to include(match(/endpoints/))
    expect(described_class.check_options({ ok_code: 201 }, :with_endpoint)).to eq([])
    expect(described_class.check_options({ path: '/x' }, :with_endpoint)).to include(match(/path/))
  end

  it 'merges class options over global ones' do
    merged = described_class.deep_merge({ host: 'a', endpoints: { users: { path: '/u' }, repos: {} } },
                                        { host: 'b', timeout: nil, endpoints: { users: { path: '/people' } } })
    expect(merged).to eq(host: 'b', endpoints: { users: { path: '/people' }, repos: {} })
  end

  it 'normalizes keys at every level without touching the input' do
    input = { 'a' => { 'b' => [{ 'c' => 1 }] } }
    expect(described_class.normalize(input)).to eq(a: { b: [{ c: 1 }] })
    expect(input.keys).to eq(['a'])
  end

  it 'encodes the fixed text of base_url and keeps its variables' do
    api = compile(base_url: 'my api/{version}', variables: { version: {} })
    expect(api.base_url).to eq('my%20api/{version}')
    expect(api.base_url_template.names).to eq(%i[version])
  end

  it 'joins paths like today: repeated slashes, empty path, name as default path' do
    api = compile(base_url: 'v1', endpoints: { a: { path: '', endpoints: { b: { path: '//x/' }, c: nil } } })
    expect(api.endpoints[:a].full_path).to eq('/v1/')
    expect(api.endpoints[:a].endpoints[:b].full_path).to eq('/v1/x/')
    expect(api.endpoints[:a].endpoints[:c].full_path).to eq('/v1/c')
    expect(api.endpoints[:a].endpoints[:c].path).to eq('c')
  end

  it 'takes on_bad_code and mime_type from the api, not from the parent endpoint' do
    api = compile(on_bad_code: 'ignore', mime_type: 'text/plain',
                  endpoints: { a: { on_bad_code: 'raise', mime_type: 'application/json', endpoints: { b: nil } } })
    expect([api.endpoints[:a].on_bad_code, api.endpoints[:a].mime_type]).to eq(['raise', 'application/json'])
    expect([api.endpoints[:a].endpoints[:b].on_bad_code, api.endpoints[:a].endpoints[:b].mime_type])
      .to eq(['ignore', 'text/plain'])
  end

  it 'does not echo header values in its messages' do
    expect(problems(default_headers: { 'X' => "secret\nvalue" }).join).not_to include('secret')
  end

  it 'rejects a variable used in a header and not declared' do
    expect(problems(default_headers: { 'X-Key' => '{token}' })).to include(match(/default_headers\.X-Key: unknown variable 'token'/))
  end

  it 'requires the name of auth type header and query' do
    expect(problems(auth: { type: 'query' })).to include(match(/svc\.auth\.name/))
    expect(problems(auth: { type: 'query', name: "a\nb" })).to include(match(/svc\.auth\.name/))
    expect(problems(auth: { type: 'bearer' })).to eq([])
  end
end
