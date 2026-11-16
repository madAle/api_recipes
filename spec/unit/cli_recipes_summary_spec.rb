require 'spec_helper'
require 'api_recipes/cli'

RSpec.describe ApiRecipes::CLI::Recipes::Summary do
  def summary(*arguments, origin: nil, **options)
    recipe = ApiRecipes::Internals::Recipe.parse(recipe_text(*arguments, **options), 'the recipe')
    described_class.new(recipe, origin: origin)
  end

  it 'shows the name, the version, the summary, the address, the credential and the calls that are not GET' do
    expect(summary.lines).to eq([
      'shop 1.0.0',
      '  summary:       A test api',
      '  address:       https://shop.example.test',
      '  credential:    in the Authorization header',
      '  calls:         3, of which 1 is not GET:',
      '    POST  shop.orders.create  /orders'
    ])
  end

  it 'shows the homepage and where the recipe comes from' do
    lines = summary('shop', recipe: { 'homepage' => 'https://example.test/docs' }, origin: 'https://example.test/r, commit abc').lines
    expect(lines).to include('  homepage:      https://example.test/docs', '  from:          https://example.test/r, commit abc')
  end

  it 'shows the address as it is written and with the defaults of the variables' do
    lines = summary('shop', 'protocol' => 'http', 'port' => 8080, 'host' => '{tenant}.{region}.example.test',
                            'base_url' => '/v/{version}/', 'auth' => { 'type' => 'none' },
                            'variables' => { 'tenant' => { 'description' => 'the name of the account' },
                                             'region' => { 'default' => 'eu', 'description' => 'eu or us' },
                                             'version' => { 'default' => '2026-10' } }).lines
    expect(lines).to include(
      '  address:       http://{tenant}.{region}.example.test:8080/v/{version}',
      '  with defaults: http://{tenant}.eu.example.test:8080/v/2026-10',
      '  variables:     tenant: to be set, the name of the account',
      '                 region: default eu, eu or us',
      '                 version: default 2026-10'
    )
  end

  it 'does not repeat the address when no variable has a default' do
    lines = summary('shop', 'host' => '{tenant}.example.test', 'variables' => { 'tenant' => nil }).lines
    expect(lines.grep(/with defaults/)).to eq([])
    expect(lines).to include('  variables:     tenant: to be set')
  end

  it 'says where the credential goes for every kind of auth' do
    kinds = {
      nil => 'in the Authorization header',
      { 'type' => 'bearer' } => 'in the Authorization header',
      { 'type' => 'basic' } => 'in the Authorization header',
      { 'type' => 'none' } => 'none declared: a credential you assign still goes in the Authorization header',
      { 'type' => 'header', 'name' => 'X-Token' } => 'in the header X-Token',
      { 'type' => 'query', 'name' => 'key' } => 'in the query string, as the parameter key'
    }
    kinds.each do |auth, text|
      expect(summary('shop', 'auth' => auth).lines).to include("  credential:    #{text}")
    end
  end

  it 'lists every call that is not a GET, with its verb and its path' do
    endpoints = { 'show' => { 'path' => '/items/:id', 'verb' => 'delete' }, 'list' => nil,
                  'group' => { 'route' => false, 'endpoints' => { 'replace' => { 'verb' => 'put' } } } }
    lines = summary('shop', 'base_url' => 'v1', 'endpoints' => endpoints).lines
    expect(lines.last(3)).to eq(['  calls:         3, of which 2 are not GET:',
                                 '    DELETE  shop.show(id)       /v1/items/:id',
                                 '    PUT     shop.group.replace  /v1/group/replace'])
  end

  it 'says so when every call is a GET' do
    expect(summary('shop', 'endpoints' => { 'list' => nil }).lines.last).to eq('  calls:         1, all GET')
  end

  it 'warns about a credential in the query string' do
    expect(summary('shop', 'auth' => { 'type' => 'query', 'name' => 'key' }).warnings)
      .to eq(['the credential travels in the address, as the query parameter key: addresses are written in logs and kept by proxies'])
  end

  it 'warns about http, whatever the recipe says about the credential: one that the application assigns is sent' do
    warning = ['the protocol is http: a credential you assign travels without encryption']
    expect(summary('shop', 'protocol' => 'http').warnings).to eq(warning)
    expect(summary('shop', 'protocol' => 'http', 'auth' => nil).warnings).to eq(warning)
    expect(summary('shop', 'protocol' => 'http', 'auth' => { 'type' => 'none' }).warnings).to eq(warning)
    expect(summary.warnings).to eq([])
  end

  # A recipe with such characters is refused when it is read: this is what the
  # summary does on its own, with an api compiled from a Hash.
  it 'shows text of the recipe without control and format characters' do
    endpoints = { "sh\u202Eow" => { 'path' => "/a\u200Bb", 'verb' => 'post' } }
    variables = { 'tenant' => { 'description' => "safe\u202E\u2028text", 'default' => "e\u200Bu" } }
    config = recipe_data('shop', 'host' => '{tenant}.example.test', 'variables' => variables, 'endpoints' => endpoints)['shop']
    definition = ApiRecipes::Internals::Compiler.compile(:shop, config)
    recipe = Struct.new(:name, :version, :definition, :text).new('shop', '1.0.0', definition, '')
    lines = described_class.new(recipe).lines
    expect(lines.join("\n")).not_to match(/[\u202E\u2028\u200B]/)
    expect(lines).to include('  variables:     tenant: default e?u, safe? text', '    POST  shop.sh?ow  /a%E2%80%8Bb')
  end

  it 'cuts a long text' do
    expect(described_class.shown('x' * 300).length).to eq(200)
    expect(described_class.shown('x' * 300, 10)).to eq('x' * 10)
  end

  it 'gives the verb of every call' do
    expect(summary.verbs).to eq('shop.orders' => 'GET', 'shop.orders.show(id)' => 'GET', 'shop.orders.create' => 'POST')
  end

  it 'shows the headers sent with every request, one per line' do
    lines = summary('shop', 'default_headers' => { 'Accept' => 'application/json', 'X-HTTP-Method-Override' => 'DELETE' }).lines
    expect(lines).to include('  headers:       Accept: application/json', '                 X-HTTP-Method-Override: DELETE')
    expect(summary.lines.grep(/headers/)).to eq([])
  end

  it 'shows one variable per line, so that a long description hides no other' do
    variables = (1..12).to_h { |number| ["v#{number}", { 'description' => 'd' * 100, 'default' => 'x' }] }
    lines = summary('shop', 'variables' => variables).lines
    expect(lines.grep(/\A {2}(variables:| {10}) +v\d+: default x, d+\z/).size).to eq(12)
  end

  it 'shows one space where the text has several, so that a long text cannot draw rows of its own' do
    text = "A test api#{' ' * 60}address:       https://safe.example.test"
    expect(summary('shop', recipe: { 'summary' => text }).lines[1]).to eq('  summary:       A test api address: https://safe.example.test')
    expect(described_class.shown("a #{[0xA0].pack('U')}  b")).to eq('a b')
  end

  describe '#changes_from' do
    it 'says what changes in the headers' do
      before = summary
      after = summary('shop', 'default_headers' => { 'X-HTTP-Method-Override' => 'DELETE' })
      expect(after.changes_from(before)).to eq(['  changes from shop 1.0.0:', '    headers: none -> X-HTTP-Method-Override: DELETE'])
      expect(before.changes_from(after)).to eq(['  changes from shop 1.0.0:', '    headers: X-HTTP-Method-Override: DELETE -> none'])
    end

    it 'says so when nothing of what it shows changes' do
      expect(summary.changes_from(summary('shop', 'timeout' => 9)))
        .to eq(['  changes from shop 1.0.0:', '    no change in the address, the credential, the headers or the verbs'])
    end
  end
end
