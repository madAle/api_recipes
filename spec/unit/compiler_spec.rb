require 'spec_helper'

describe ApiRecipes::Core::Compiler do
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

  describe 'immutability' do
    it 'keeps frozen copies of the input strings' do
      proto = +'https'
      obc = +'ignore'
      host = +'h.test'
      api = compile(protocol: proto, on_bad_code: obc, host: host, endpoints: { a: { on_bad_code: obc } })
      [proto, obc, host].each { |text| text.replace('ftp') }
      expect([api.protocol, api.on_bad_code, api.host, api.endpoints[:a].on_bad_code]).to eq(%w[https ignore h.test ignore])
    end

    it 'freezes every string of the tree, defaults included' do
      api = compile(default_headers: { 'X' => 'a' }, auth: { type: 'header', name: 'X-T' },
                    variables: { v: { default: 'd', description: 'e' } }, recipe: { name: 'r', list: ['x'] },
                    endpoints: { a: { path: '/p', ok_code: [200] } })
      strings = [api.protocol, api.host, api.on_bad_code, api.default_headers['X'], api.default_headers.keys.first,
                 api.auth[:name], api.variables[:v][:default], api.variables[:v][:description], api.recipe[:name],
                 api.recipe[:list].first, api.endpoints[:a].path, api.endpoints[:a].full_path,
                 api.endpoints[:a].full_name]
      expect(strings).to all(be_frozen)
      expect([api.default_headers, api.auth, api.variables, api.variables[:v], api.recipe, api.recipe[:list],
              api.endpoints[:a].ok_code]).to all(be_frozen)
    end

    it 'does not let the caller change the tree through to_h' do
      api = compile({})
      expect { api.to_h[:protocol] << 'x' }.to raise_error(FrozenError)
      expect { api.to_h[:host] << '.evil' }.to raise_error(FrozenError)
      expect { api.host << '.evil' }.to raise_error(FrozenError)
      expect(api.host).to eq('localhost')
    end
  end

  describe 'duplicate keys' do
    it 'reports a String and a Symbol key for the same option' do
      expect(described_class.check_options({ host: 'good.test@evil.test', 'host' => 'good.test' }, :with_api))
        .to include("option 'host' is given twice (as a String and as a Symbol)")
      expect(problems('host' => 'evil.test', host: 'good.test')).to include(match(/option 'host' is given twice/))
    end

    it 'reports them at every level' do
      expect(problems(endpoints: { 'a' => {}, a: {} })).to include("svc.endpoints: option 'a' is given twice (as a String and as a Symbol)")
      expect(problems(variables: { 'v' => {}, v: {} })).to include(match(/svc\.variables: option 'v' is given twice/))
      expect(problems(auth: { 'type' => 'basic', type: 'bearer' })).to include(match(/svc\.auth: option 'type'/))
      expect(problems(recipe: { 'k' => 1, k: 2 })).to include(match(/svc\.recipe: option 'k'/))
      expect { described_class.compile_all('a' => {}, a: {}) }
        .to raise_error(ApiRecipes::ConfigurationError, /option 'a' is given twice/)
      expect { described_class.normalize('a' => 1, a: 2) }.to raise_error(ApiRecipes::ConfigurationError)
    end
  end

  describe 'invalid input' do
    it 'reports invalid encodings instead of raising' do
      bad = "h\xFF.test"
      expect(problems(host: bad)).to include('svc.host: must be valid UTF-8')
      expect(problems(default_headers: { 'X' => bad })).to include('svc.default_headers.X: must be valid UTF-8')
      expect(problems(mime_type: bad)).to include('svc.mime_type: must be valid UTF-8')
      expect(problems(protocol: bad, on_bad_code: bad)).to include('svc.protocol: must be valid UTF-8')
      expect(problems(endpoints: { a: { verb: bad, route: bad } })).to include('svc.endpoints.a.verb: must be valid UTF-8')
      expect(problems(bad => 1)).to include('svc: must be valid UTF-8')
      expect(described_class.check_options({ host: bad.b }, :with_api)).to include('host: must be valid UTF-8')
    end

    it 'reports names that are not Strings or Symbols' do
      expect(problems(endpoints: { 200 => {}, true => nil })).to include('svc.endpoints: name must be a String or a Symbol')
      expect(problems(variables: { 1 => {} })).to include('svc.variables: name must be a String or a Symbol')
      expect { described_class.compile_all(1 => {}) }
        .to raise_error(ApiRecipes::ConfigurationError, /name must be a String or a Symbol/)
      expect { described_class.compile(nil, {}) }.to raise_error(ApiRecipes::ConfigurationError)
      expect { described_class.compile_all('x') }.to raise_error(ApiRecipes::ConfigurationError, /apis: must be a Hash/)
    end

    it 'never raises from check_options, whatever the input' do
      [nil, 'x', 1, [], { 1 => 2 }, { host: Object.new }, { timeout: [] }, { endpoints: [1] }, { default_headers: [] },
       { auth: 'x' }, { variables: { 'a b' => 3 } }, { 'x' => "\xFF" }].each do |input|
        %i[api with_api with_endpoint].each do |scope|
          expect(described_class.check_options(input, scope)).to be_an(Array)
        end
      end
    end

    it 'sanitizes the names shown in messages' do
      errors = problems(default_headers: { "X\nY" => 'v' }, endpoints: { "a\nb" => { bogus: 1 } })
      expect(errors.join).not_to match(/[\x00-\x1F]/)
    end
  end

  describe 'hardening' do
    it 'rejects hosts without a letter or a digit and hosts with ..' do
      %w[. .. - a..b].each { |host| expect(problems(host: host)).to include(match(/svc\.host/)) }
      expect(problems(host: '{shop}..x', variables: { shop: {} })).to eq([])
    end

    it 'accepts only ports from 1 to 65535' do
      expect(problems(port: 65_536)).to include(match(/svc\.port/))
      expect(problems(port: 65_535)).to eq([])
    end

    it 'rejects path placeholders in base_url' do
      message = 'svc.base_url: path placeholders are not allowed here; declare a variable and write {name}'
      expect(problems(base_url: 'v1/:version')).to eq([message])
      expect(problems(base_url: 'files/*rest')).to eq([message])
      expect(problems(base_url: 'v1/{version}', variables: { version: {} })).to eq([])
    end
  end

  describe '.resolve_options' do
    it 'returns the options as the tree stores them' do
      source = { 'timeout' => 5, 'host' => +'h.test', protocol: :http, on_bad_code: :ignore, verify_with: 'check',
                 base_url: 'my api', default_headers: { 'X' => +'1' }, variables: { shop: +'acme' }, 'x-note' => 1 }
      resolved = described_class.resolve_options(source, :with_api)
      source['host'].replace('evil.test')
      source[:variables][:shop].replace('evil')
      expect(resolved).to eq(timeout: 5, host: 'h.test', protocol: 'http', on_bad_code: 'ignore', verify_with: :check,
                             base_url: 'my%20api', default_headers: { 'X' => '1' }, variables: { shop: 'acme' })
      expect([resolved, resolved[:host], resolved[:default_headers], resolved[:variables][:shop]]).to all(be_frozen)
    end

    it 'handles endpoint options and credentials' do
      expect(described_class.resolve_options({ 'ok_code' => [200], timeout: nil }, :with_endpoint))
        .to eq(ok_code: [200])
      credential = { user: +'u' }
      resolved = described_class.resolve_options({ basic_auth: credential }, :with_api)
      credential[:user].replace('x')
      expect(resolved[:basic_auth]).to eq(user: 'u')
    end

    it 'raises the same messages check_options returns' do
      options = { host: 'a@b', 'host' => 'c', bogus: 1 }
      expected = described_class.check_options(options, :with_api)
      expect(expected).not_to be_empty
      expect { described_class.resolve_options(options, :with_api) }
        .to raise_error(ApiRecipes::ConfigurationError) { |e| expect(e.errors).to eq(expected) }
      expect { described_class.resolve_options('x', :with_api) }.to raise_error(ApiRecipes::ConfigurationError)
    end
  end

  describe 'x- keys' do
    let(:odd) { { 200 => 'ok', true => 1, 'a' => 1, a: 2, "bad\xFF" => "v\xFF" } }

    it 'never looks inside the value of an x- or x_ option, at any option level' do
      config = { 'x-codes' => odd, x_flags: odd, endpoints: { a: { 'x-doc' => odd, endpoints: { b: { x_n: odd } } } } }
      expect(problems(config)).to eq([])
      expect(described_class.check_options(config, :api)).to eq([])
      expect { described_class.compile_all(svc: config) }.not_to raise_error
      expect(described_class.check_options({ 'x-a' => odd, timeout: 1 }, :with_api)).to eq([])
      expect(described_class.check_options({ 'x-a' => odd }, :with_endpoint)).to eq([])
      expect(described_class.resolve_options({ 'x-a' => odd, timeout: 1 }, :with_api)).to eq(timeout: 1)
    end

    it 'leaves the value untouched in normalize and deep_merge' do
      normalized = described_class.normalize('x-a' => odd, 'endpoints' => { 'b' => { 'x_c' => odd } })
      expect(normalized[:'x-a']).to equal(odd)
      expect(normalized[:endpoints][:b][:x_c]).to equal(odd)
      merged = described_class.deep_merge({ 'x-a' => { 'k' => 1 } }, { 'x-a' => odd })
      expect(merged[:'x-a']).to equal(odd)
      expect { described_class.deep_merge({ 'x-a' => odd }, { host: 'h' }) }.not_to raise_error
    end

    it 'still validates names inside default_headers, variables and recipe' do
      expect(problems(default_headers: { 'x-api-key' => "a\nb" })).to include(match(/default_headers\.x-api-key/))
      expect(problems(default_headers: { 'x-api-key' => 'a', 'X-Api-Key' => 'b', :'x-api-key' => 'c' }))
        .to include(match(/default_headers: option 'x-api-key' is given twice/))
      expect(problems(variables: { 'x-k' => {} })).to include(match(/svc\.variables\.x-k/))
      expect(problems(recipe: { 'x-r' => { 1 => 2 } })).to include(match(/svc\.recipe\.x-r: name must be a String/))
    end

    it 'keeps endpoint names that look like x- keys' do
      api = compile(endpoints: { 'x-ray' => { path: '/xr' } })
      expect(api.endpoints[:'x-ray'].full_path).to eq('/xr')
    end
  end

  describe 'names and keys' do
    it 'reports two Strings that become the same Symbol' do
      key = 'host'.encode('UTF-16LE')
      expect(described_class.check_options({ 'host' => 'a@evil.test', key => 'good.test' }, :with_api))
        .to include(match(/option 'host' is given twice/))
    end

    it 'does not quote a raw path in its messages' do
      errors = problems(endpoints: { a: { path: "/:id/:id\n#{'x' * 500}" }, "n\n:i/:i" => nil })
      expect(errors.join).not_to match(/[\x00-\x1F]/)
      expect(errors.map(&:size).max).to be < 200
      expect(errors).to include(match(/svc\.endpoints\.a\.path: placeholder 'id' is repeated/))
    end

    it 'refuses empty names and names with control characters' do
      expect { described_class.compile("a\nb", {}) }.to raise_error(ApiRecipes::ConfigurationError) { |e| expect(e.message).not_to match(/a\nb/) }
      expect { described_class.compile('', {}) }.to raise_error(ApiRecipes::ConfigurationError, /must not be empty/)
      expect(problems(endpoints: { '' => {}, "a\nb" => {} }).join("\n")).not_to match(/a\nb/)
      expect(problems(endpoints: { '' => {} }).size).to eq(1)
      expect(problems(endpoints: { "a\nb" => {} })).to include(match(/svc\.endpoints: .*control/))
      expect(problems(variables: { "a\nb" => {}, '' => {} }).join("\n")).not_to match(/a\nb/)
      expect(problems(variables: { '' => {} }).size).to eq(1)
    end

    it 'keeps names such as pull-requests, 2fa, end and class' do
      expect(problems(endpoints: { 'pull-requests' => {}, '2fa' => {}, 'end' => {}, 'class' => {} })).to eq([])
    end

    it 'returns a frozen Hash for no configuration' do
      expect(described_class.compile_all(nil)).to be_frozen
    end
  end

  describe 'cycles' do
    def cycle
      config = { host: 'h.test' }
      config[:endpoints] = config
      config
    end

    it 'reports a cycle among the inspected values instead of overflowing the stack' do
      expect(problems(cycle)).to include(match(/must not contain itself/))
      expect(described_class.check_options(cycle, :api)).to include(match(/must not contain itself/))
      expect { described_class.compile_all(svc: cycle) }.to raise_error(ApiRecipes::ConfigurationError, /must not contain itself/)
      expect { described_class.normalize(cycle) }.to raise_error(ApiRecipes::ConfigurationError, /must not contain itself/)
      list = []
      list << list
      expect(problems(endpoints: { a: { ok_code: list } })).to include(match(/must not contain itself/))
    end

    it 'does not visit a cycle under an x- key, and accepts a value used twice' do
      loop_hash = {}
      loop_hash[:self] = loop_hash
      shared = { path: '/s' }
      expect(problems('x-self' => loop_hash, endpoints: { a: shared, b: shared })).to eq([])
    end
  end
end
