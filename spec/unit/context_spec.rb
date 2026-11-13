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
end
