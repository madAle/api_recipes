require 'spec_helper'
require 'api_recipes/cli'

describe ApiRecipes::CLI::Import::Security do
  def read(schemes, security = :first, paths = nil)
    overrides = { 'components' => { 'securitySchemes' => schemes } }
    overrides['security'] = security == :first ? [{ schemes.keys.first => [] }] : security unless security.nil?
    overrides['paths'] = paths if paths
    described_class.read(ApiRecipes::CLI::Import::Document.parse(openapi(overrides)))
  end

  {
    { 'type' => 'http', 'scheme' => 'bearer' } => { 'type' => 'bearer' },
    { 'type' => 'http', 'scheme' => 'Bearer', 'bearerFormat' => 'JWT' } => { 'type' => 'bearer' },
    { 'type' => 'http', 'scheme' => 'Basic' } => { 'type' => 'basic' },
    { 'type' => 'oauth2', 'flows' => {} } => { 'type' => 'bearer' },
    { 'type' => 'openIdConnect', 'openIdConnectUrl' => 'https://example.test/.well-known' } => { 'type' => 'bearer' },
    { 'type' => 'apiKey', 'in' => 'header', 'name' => 'X-Api-Key' } => { 'type' => 'header', 'name' => 'X-Api-Key' },
    { 'type' => 'apiKey', 'in' => 'query', 'name' => 'key' } => { 'type' => 'query', 'name' => 'key' }
  }.each do |scheme, auth|
    it "reads #{scheme.slice('type', 'scheme', 'in').values.join(' ')} as #{auth['type']}" do
      result = read('main' => scheme)
      expect(result.auth).to eq(auth)
      expect(result.warnings).to eq([])
    end
  end

  {
    { 'type' => 'apiKey', 'in' => 'cookie', 'name' => 'session' } => /cookie/,
    { 'type' => 'http', 'scheme' => 'digest' } => /'digest'/,
    { 'type' => 'mutualTLS' } => /'mutualTLS'/,
    { 'type' => 'apiKey', 'in' => 'header' } => /name/,
    'text' => /'main'/
  }.each do |scheme, warning|
    it "writes no auth for #{scheme.is_a?(Hash) ? scheme.values.join(' ') : 'a scheme that is not a mapping'}, and says why" do
      result = read('main' => scheme)
      expect(result.auth).to be_nil
      expect(result.warnings).to contain_exactly(match(warning))
    end
  end

  it 'takes the first alternative it can write' do
    schemes = { 'cookie' => { 'type' => 'apiKey', 'in' => 'cookie', 'name' => 's' },
                'token' => { 'type' => 'http', 'scheme' => 'bearer' },
                'key' => { 'type' => 'apiKey', 'in' => 'header', 'name' => 'X-Key' } }
    result = read(schemes, [{ 'cookie' => [] }, { 'token' => [] }, { 'key' => [] }])
    expect(result.auth).to eq('type' => 'bearer')
    expect(result.warnings).to contain_exactly(match(/cookie/))
  end

  it 'takes the first scheme of a requirement that names several, and says so' do
    schemes = { 'key' => { 'type' => 'apiKey', 'in' => 'header', 'name' => 'X-Key' },
                'token' => { 'type' => 'http', 'scheme' => 'bearer' } }
    result = read(schemes, [{ 'key' => [], 'token' => [] }])
    expect(result.auth).to eq('type' => 'header', 'name' => 'X-Key')
    expect(result.warnings).to contain_exactly(match(/several schemes together.*'key'/))
  end

  it 'skips the empty requirement that allows anonymous calls' do
    result = read({ 'token' => { 'type' => 'http', 'scheme' => 'bearer' } }, [{}, { 'token' => [] }])
    expect(result.auth).to eq('type' => 'bearer')
  end

  it 'writes no auth when the global security is an empty list, which means that none is needed' do
    result = read({ 'token' => { 'type' => 'http', 'scheme' => 'basic' } }, [])
    expect([result.auth, result.warnings]).to eq([nil, []])
  end

  it 'does not fail on a path that points to another file: the paths are read elsewhere' do
    result = read({ 'token' => { 'type' => 'http', 'scheme' => 'bearer' } }, :first,
                  { '/legacy' => { '$ref' => './legacy.yml#/x' }, '/a' => { 'get' => { 'security' => [] } } })
    expect(result.warnings).to contain_exactly(match(/1 operation declares its own security/))
  end

  it 'uses the only scheme when there is no global security' do
    result = read({ 'token' => { 'type' => 'http', 'scheme' => 'basic' } }, nil)
    expect(result.auth).to eq('type' => 'basic')
    expect(result.warnings).to eq([])
  end

  it 'writes no auth when there are several schemes and no global security, and says so' do
    schemes = { 'a' => { 'type' => 'http', 'scheme' => 'basic' }, 'b' => { 'type' => 'http', 'scheme' => 'bearer' } }
    result = read(schemes, nil)
    expect(result.auth).to be_nil
    expect(result.warnings).to contain_exactly(match(/2 security schemes.*no global security/))
  end

  it 'writes no auth and no warning when the description has no security at all' do
    result = described_class.read(ApiRecipes::CLI::Import::Document.parse(openapi))
    expect([result.auth, result.warnings]).to eq([nil, []])
  end

  it 'says so when the global security names a scheme that is not defined' do
    result = read({ 'token' => { 'type' => 'http', 'scheme' => 'bearer' } }, [{ 'missing' => [] }])
    expect(result.auth).to be_nil
    expect(result.warnings).to contain_exactly(match(/'missing'.*not defined/))
  end

  it 'follows a $ref to the scheme' do
    text = openapi('components' => { 'securitySchemes' => { 'main' => { '$ref' => '#/x-schemes/token' } } },
                   'x-schemes' => { 'token' => { 'type' => 'http', 'scheme' => 'bearer' } },
                   'security' => [{ 'main' => [] }])
    expect(described_class.read(ApiRecipes::CLI::Import::Document.parse(text)).auth).to eq('type' => 'bearer')
  end

  it 'counts in one warning the operations that declare a security of their own' do
    paths = {
      '/a' => { 'get' => { 'security' => [] }, 'post' => { 'security' => [{ 'main' => [] }] }, 'put' => {} },
      '/b' => { 'get' => { 'security' => [{ 'other' => [] }] }, 'parameters' => [] }
    }
    result = read({ 'main' => { 'type' => 'http', 'scheme' => 'bearer' } }, :first, paths)
    expect(result.auth).to eq('type' => 'bearer')
    expect(result.warnings).to contain_exactly(match(/2 operations declare their own security/))
  end
end
