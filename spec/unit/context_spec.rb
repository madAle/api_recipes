require 'spec_helper'

describe ApiRecipes::Context do
  let(:config) do
    { host: '{shop}.h.test', timeout: 3, variables: { shop: { default: 'main' } },
      endpoints: { slow: { timeout: 30 }, fast: {} } }
  end
  let(:definition) { ApiRecipes::Compiler.compile(:svc, config) }
  let(:klass) { Class.new }

  def context(owner = ApiRecipes) = described_class.new(definition: definition, owner: owner, global_definition: definition)
  def assign(owner, **changes) = ApiRecipes::LevelSet.write(owner, :svc) { |level| level.with(**changes) }

  it 'takes each option from the nearest place' do
    slow = definition.endpoints[:slow]
    fast = definition.endpoints[:fast]
    ctx = context.with(timeout: 10)
    expect(context.setting(:timeout, fast)).to eq(3)
    expect(ctx.setting(:timeout, fast)).to eq(10)
    expect(ctx.setting(:timeout, slow)).to eq(30)
    expect(ctx.setting(:timeout, slow, { timeout: 60 })).to eq(60)
  end

  it 'adds up variables from the default to with' do
    object = klass.new
    expect(context(object).origin).to eq('https://main.h.test')
    assign(ApiRecipes, variables: { shop: 'global' }.freeze)
    assign(klass, variables: { shop: 'class' }.freeze)
    expect(context(object).origin).to eq('https://class.h.test')
    expect(context(object).origin(up_to: :global)).to eq('https://global.h.test')
    assign(object, variables: { shop: 'instance' }.freeze)
    expect(context(object).origin).to eq('https://instance.h.test')
    expect(context(object).with(variables: { shop: 'chain' }).origin).to eq('https://chain.h.test')
  end

  it 'refuses unknown or invalid options in with' do
    expect { context.with(endpoints: {}) }.to raise_error(ApiRecipes::ConfigurationError)
    expect { context.with(host: 'evil.test/x') }.to raise_error(ApiRecipes::ConfigurationError)
  end

  it 'keeps the values given to with as the compiler would' do
    api = ApiRecipes::Compiler.compile(:svc, host: 'h.test', base_url: 'v1', variables: { v: { default: 'a b' } })
    ctx = described_class.new(definition: api, owner: ApiRecipes)
    expect(ctx.base_path).to eq('/v1')
    expect(ctx.with(base_url: 'x y/{v}').base_path).to eq('/x%20y/a%20b')
    expect(ctx.with(verify_with: 'check').setting(:verify_with)).to eq(:check)
    expect(ctx.with(timeout: 9).with(timeout: nil).setting(:timeout)).to eq(3)
    expect(ctx.setting(:ok_code)).to be_nil
  end

  it 'merges headers given to with' do
    api = ApiRecipes::Compiler.compile(:svc, host: 'h.test', default_headers: { 'Accept' => 'a' })
    ctx = described_class.new(definition: api, owner: ApiRecipes).with(default_headers: { 'X-One' => '1' })
    expect(ctx.headers).to eq('Accept' => 'a', 'X-One' => '1')
  end

  it 'keeps exactly the values the compiler resolved' do
    options = { mime_type: (+"caf\xE9").force_encoding('ISO-8859-1'), host: 'h.test'.encode('ISO-8859-1'),
                variables: { shop: ['a'] }, base_url: 'x y', verify_with: 'check', 'x-note' => 1 }
    overrides = context.with(options).overrides
    expect(overrides).to eq(ApiRecipes::Compiler.resolve_options(options, :with_api))
    expect(overrides.values_at(:mime_type, :host).map(&:encoding)).to eq([Encoding::UTF_8, Encoding::UTF_8])
    expect(overrides[:variables][:shop]).to be_frozen
    expect { context.with(timeout: 1, 'timeout' => 2) }.to raise_error(ApiRecipes::ConfigurationError, /twice/)
  end

  it 'reads nil by the keys as given: no credential, or no override' do
    api = ApiRecipes::Compiler.compile(:svc, host: '{shop}.h.test', default_headers: { 'Accept' => 'a' },
                                             variables: { shop: { default: 'main' } })
    ctx = described_class.new(definition: api, owner: ApiRecipes, global_definition: api)
    ApiRecipes::LevelSet.write(ApiRecipes, :svc) { |l| l.with(credential: ApiRecipes::Credential.authorization('T')) }
    expect(ctx.with(default_headers: { 'X' => '1' }).with(default_headers: nil).headers).to eq('Accept' => 'a')
    expect(ctx.with(variables: { shop: 'other' }).with('variables' => nil).origin).to eq('https://main.h.test')
    expect(ctx.with(timeout: 9).with('timeout' => nil).setting(:timeout)).to eq(3)
    expect(ctx.credential).not_to be_nil
    expect(ctx.with('authorization' => nil).credential).to be_nil
    expect(ctx.with(basic_auth: nil).credential).to be_nil
    expect(ctx.with(authorization: 'C').with(authorization: nil).credential).to be_nil
  end

  it 'reads the names of the options as the compiler does, whatever their encoding' do
    ApiRecipes::LevelSet.write(ApiRecipes, :svc) { |l| l.with(credential: ApiRecipes::Credential.authorization('T')) }
    expect(context.with('timeout'.encode('UTF-16LE') => 1).setting(:timeout)).to eq(1)
    expect(context.credential).not_to be_nil
    expect(context.with('authorization'.encode('UTF-16LE') => nil).credential).to be_nil
  end

  it 'is not changed by the caller after with' do
    host = +'a.h.test'
    shop = +'acme'
    list = ['x']
    headers = { 'X' => +'1' }
    ctx = context.with(host: host, variables: { shop: shop, zone: list }, default_headers: headers)
    host.replace('evil.test')
    shop.replace('evil')
    list << 'y'
    headers['X'].replace('2')
    headers['Y'] = '3'
    expect(ctx.origin).to eq('https://a.h.test')
    expect(ctx.overrides[:variables]).to eq(shop: 'acme', zone: ['x'])
    expect(ctx.headers).to eq('X' => '1')
  end

  it 'takes the declared defaults of the global level from the global definition' do
    global = ApiRecipes::Compiler.compile(:svc, host: '{shop}.h.test', variables: { shop: { default: 'global' } })
    ctx = described_class.new(definition: definition, owner: klass.new, global_definition: global)
    expect(ctx.variables(up_to: :global)).to eq(shop: 'global')
    expect(ctx.origin(up_to: :global)).to eq('https://global.h.test')
    expect(ctx.variables).to eq(shop: 'main')
    no_global = described_class.new(definition: definition, owner: klass.new)
    expect(no_global.variables(up_to: :global)).to eq({})
    expect(no_global.origin(up_to: :global)).to be_nil
  end
end
