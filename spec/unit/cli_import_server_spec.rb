require 'spec_helper'
require 'api_recipes/cli'

describe ApiRecipes::CLI::Import::Server do
  let(:error) { ApiRecipes::CLI::Import::Error }

  def read(servers, index = 0)
    overrides = servers == :absent ? {} : { 'servers' => servers }
    text = servers == :absent ? openapi.sub(/^servers:\n- url: .*\n/, '') : openapi(overrides)
    described_class.read(ApiRecipes::CLI::Import::Document.parse(text), index)
  end

  def server(url, variables = nil)
    [{ 'url' => url }.merge(variables ? { 'variables' => variables } : {})]
  end

  {
    'https://api.github.com' => { host: 'api.github.com' },
    'https://api.github.com/' => { host: 'api.github.com' },
    'http://localhost:3000/api/v1/' => { protocol: 'http', host: 'localhost', port: 3000, base_url: 'api/v1' },
    'https://api.example.test:443/v2' => { host: 'api.example.test', base_url: 'v2' },
    'http://api.example.test:80' => { protocol: 'http', host: 'api.example.test' },
    'HTTPS://API.Example.test:8443' => { host: 'API.Example.test', port: 8443 },
    'https://web_service_1/a//b/' => { host: 'web_service_1', base_url: 'a/b' }
  }.each do |url, options|
    it "reads #{url}" do
      result = read(server(url))
      expect(result.options).to eq(options)
      expect(result.options.keys).to eq(options.keys)
      expect(result.warnings).to eq([])
    end
  end

  it 'keeps the variables of the host and of the path, with their defaults' do
    result = read(server('https://{shop}.example.test/admin/{api_version}',
                         'shop' => { 'default' => 'acme', 'description' => "The shop.\nSecond line" },
                         'api_version' => { 'default' => '2026-10', 'enum' => %w[2026-10 2027-01] },
                         'unused' => { 'default' => 'x' }))
    expect(result.options).to eq(
      host: '{shop}.example.test', base_url: 'admin/{api_version}',
      variables: { 'shop' => { 'default' => 'acme', 'description' => 'The shop. Second line' },
                   'api_version' => { 'default' => '2026-10' } }
    )
    expect(result.warnings).to eq([])
  end

  it 'replaces a variable of the protocol or of the port with its default, and says so' do
    result = read(server('{scheme}://api.example.test:{port}',
                         'scheme' => { 'default' => 'https' }, 'port' => { 'default' => '8443' }))
    expect(result.options).to eq(host: 'api.example.test', port: 8443)
    expect(result.warnings).to contain_exactly(match(/'scheme'.*protocol.*default 'https'/),
                                               match(/'port'.*port.*default '8443'/))
  end

  it 'renames a variable whose name the gem cannot use, and says so' do
    result = read(server('https://{my-shop}.example.test/{1st}',
                         'my-shop' => { 'default' => 'acme' }, '1st' => { 'default' => 'a' }))
    expect(result.options).to eq(host: '{my_shop}.example.test', base_url: '{_1st}',
                                 variables: { 'my_shop' => { 'default' => 'acme' }, '_1st' => { 'default' => 'a' } })
    expect(result.warnings).to contain_exactly(match(/'my-shop'.*'my_shop'/), match(/'1st'.*'_1st'/))
  end

  it 'declares a variable that the description uses and does not define, without a default' do
    result = read(server('https://{shop}.example.test'))
    expect(result.options).to eq(host: '{shop}.example.test', variables: { 'shop' => {} })
    expect(result.warnings).to contain_exactly(match(/'shop'.*not defined/))
  end

  it 'writes no host for a relative address, and says to set it' do
    result = read(server('/v1'))
    expect(result.options).to eq(base_url: 'v1')
    expect(result.warnings).to contain_exactly(match(/relative.*set host/))
    expect(read(server('/')).options).to eq({})
  end

  it 'writes nothing when the description names no server, and says to set the host' do
    result = read(:absent)
    expect(result.options).to eq({})
    expect(result.warnings).to contain_exactly(match(/no server.*set host/))
    expect(read([]).options).to eq({})
  end

  it 'reads the server that was asked for' do
    servers = server('https://one.example.test') + server('https://two.example.test')
    expect(read(servers, 1).options).to eq(host: 'two.example.test')
  end

  it 'refuses an index that is not in the list, and says how many there are' do
    servers = server('https://one.example.test') + server('https://two.example.test')
    expect { read(servers, 2) }.to raise_error(error, /--server 2.*2 servers.*0 to 1/)
    expect { read(servers, -1) }.to raise_error(error, /--server -1/)
    expect { read(:absent, 1) }.to raise_error(error, /--server 1.*no server/)
  end

  it 'refuses what is not an http or https address it can read' do
    {
      'ws://api.example.test' => /protocol 'ws'/,
      'https://user:pass@api.example.test' => /user/,
      'https://api.example.test:port' => /port/,
      'https://api.example.test:0' => /port/,
      'https://api.example.test/a?b=1' => /query/,
      'https://api.example.test/a#b' => /query/,
      'https:///path' => /host/,
      '{scheme}://api.example.test' => /'scheme'.*no default/
    }.each do |url, message|
      expect { read(server(url)) }.to raise_error(error, message)
    end
    expect { read([{ 'url' => 42 }]) }.to raise_error(error, /servers\[0\]\.url/)
    expect { read(['text']) }.to raise_error(error, /servers\[0\]/)
  end

  it 'follows a $ref to the server' do
    text = openapi('servers' => [{ '$ref' => '#/x-servers/main' }],
                   'x-servers' => { 'main' => { 'url' => 'https://ref.example.test' } })
    result = described_class.read(ApiRecipes::CLI::Import::Document.parse(text))
    expect(result.options).to eq(host: 'ref.example.test')
  end
end
