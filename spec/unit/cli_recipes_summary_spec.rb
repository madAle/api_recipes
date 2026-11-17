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

  it 'shows the parameters sent with every request, one per line, as they are written' do
    lines = summary('shop', 'variables' => { 'api_version' => { 'default' => '2026-10' } },
                            'default_params' => { 'api-version' => '{api_version}', 'per_page' => 100 }).lines
    expect(lines).to include('  params:        api-version: {api_version}', '                 per_page: 100')
    expect(summary.lines.grep(/params/)).to eq([])
  end

  it 'shows the headers and the parameters that an endpoint adds, and where they apply' do
    endpoints = { 'orders' => { 'default_params' => { 'state' => 'open' }, 'endpoints' => {
      'show' => { 'path' => '/:id', 'default_headers' => { 'X-HTTP-Method-Override' => 'DELETE' } }
    } } }
    lines = summary('shop', 'default_headers' => { 'Accept' => 'application/json' }, 'endpoints' => endpoints).lines
    expect(lines).to include('  headers:       Accept: application/json',
                             '                 X-HTTP-Method-Override: DELETE (shop.orders.show)',
                             '  params:        state: open (shop.orders and below)')
  end

  it 'says so when it cuts a name or a value: nothing is left out without a sign' do
    endpoints = { 'u' => { 'default_headers' => { 'X-Note' => "#{'b' * 100} {account}" } } }
    lines = summary('shop', 'variables' => { 'account' => { 'default' => 'd' * 61, 'description' => 'e' * 101 } },
                            'default_params' => { 'q' => "#{'a' * 100}&leak=1", 'n' * 300 => 'delete' },
                            'endpoints' => endpoints).lines
    expect(lines).to include("  headers:       X-Note: #{'b' * 100}... (110 characters) (shop.u)",
                             "  params:        q: #{'a' * 100}... (107 characters)",
                             "                 #{'n' * 100}... (300 characters): delete",
                             "  variables:     account: default #{'d' * 60}... (61 characters), #{'e' * 100}... (101 characters)")
  end

  it 'shows the whole address, also when a default makes it long: where the host ends is at its end' do
    host = "#{'a.' * 300}evil.example.test"
    lines = summary('shop', 'host' => '{h}', 'variables' => { 'h' => { 'default' => host } }).lines
    expect(lines).to include("  with defaults: https://#{host}")
  end

  it 'lists the calls that resource adds and that are not GET' do
    lines = summary('shop', 'endpoints' => { 'orders' => { 'resource' => true } }).lines
    expect(lines.last(5)).to eq(['  calls:         6, of which 4 are not GET:',
                                 '    POST    shop.orders.create       /orders',
                                 '    PATCH   shop.orders.update(id)   /orders/:id',
                                 '    PUT     shop.orders.replace(id)  /orders/:id',
                                 '    DELETE  shop.orders.delete(id)   /orders/:id'])
  end

  it 'shows a path with its variable as it is written' do
    endpoints = { 'orders' => { 'path' => '/accounts/{account}/orders', 'verb' => 'post' } }
    lines = summary('shop', 'variables' => { 'account' => nil }, 'endpoints' => endpoints).lines
    expect(lines.last).to eq('    POST  shop.orders  /accounts/{account}/orders')
  end

  describe '#changes_from' do
    it 'says what changes in the parameters, on the api and on an endpoint, one line for each' do
      before = summary
      after = summary('shop', 'default_params' => { 'debug' => 1, 'page' => 2 })
      expect(after.changes_from(before))
        .to eq(['  changes from shop 1.0.0:', '    new parameter: debug: 1', '    new parameter: page: 2'])
      expect(before.changes_from(after))
        .to eq(['  changes from shop 1.0.0:', '    parameter no longer sent: debug', '    parameter no longer sent: page'])
      endpoints = { 'orders' => { 'default_params' => { 'all' => true } } }
      nested = summary('shop', 'endpoints' => endpoints)
      expect(nested.changes_from(summary('shop', 'endpoints' => { 'orders' => nil })))
        .to eq(['  changes from shop 1.0.0:', '    new parameter: all: true (shop.orders)'])
      moved = summary('shop', 'endpoints' => { 'orders' => { 'default_params' => { 'all' => false } } })
      expect(moved.changes_from(nested)).to eq(['  changes from shop 1.0.0:', '    parameter all (shop.orders): true -> false'])
    end

    it 'says what changes in the headers' do
      before = summary
      after = summary('shop', 'default_headers' => { 'X-HTTP-Method-Override' => 'DELETE' })
      expect(after.changes_from(before)).to eq(['  changes from shop 1.0.0:', '    new header: X-HTTP-Method-Override: DELETE'])
      expect(before.changes_from(after)).to eq(['  changes from shop 1.0.0:', '    header no longer sent: X-HTTP-Method-Override'])
      other = summary('shop', 'default_headers' => { 'X-HTTP-Method-Override' => 'PUT' })
      expect(other.changes_from(after)).to eq(['  changes from shop 1.0.0:', '    header X-HTTP-Method-Override: DELETE -> PUT'])
    end

    it 'compares the values as they are, and shows whole the ones that change, however long' do
      long = 'a' * 150
      before = summary('shop', 'variables' => { 'account' => nil }, 'default_params' => { 'q' => long },
                               'endpoints' => { 'u' => { 'default_headers' => { 'X-Note' => long } } })
      after = summary('shop', 'variables' => { 'account' => nil }, 'default_params' => { 'q' => "#{long}&leak={account}" },
                              'endpoints' => { 'u' => { 'default_headers' => { 'X-Note' => "#{long} {account}" } } })
      expect(after.changes_from(before)).to eq(['  changes from shop 1.0.0:',
                                                "    header X-Note (shop.u): #{long} -> #{long} {account}",
                                                "    parameter q: #{long} -> #{long}&leak={account}"])
      # Two values of the same length, that differ after what a row shows.
      same = %w[safe evil].map { |tail| summary('shop', 'default_params' => { 'q' => "#{long}#{tail}" }) }
      expect(same[1].changes_from(same[0])).to eq(['  changes from shop 1.0.0:', "    parameter q: #{long}safe -> #{long}evil"])
      name = 'n' * 600
      renamed = [summary('shop', 'default_params' => { name => 'harmless' }), summary('shop', 'default_params' => { name => 'delete' })]
      expect(renamed[1].changes_from(renamed[0])).to eq(['  changes from shop 1.0.0:', "    parameter #{name}: harmless -> delete"])
    end

    it 'shows whole an address that changes far from its start' do
      hosts = %w[good evil].map { |word| "#{'a.' * 400}#{word}.example.test" }
      before, after = hosts.map { |host| summary('shop', 'host' => host) }
      expect(after.changes_from(before)).to eq(['  changes from shop 1.0.0:',
                                                "    address: https://#{hosts[0]} -> https://#{hosts[1]}",
                                                "    with defaults: https://#{hosts[0]} -> https://#{hosts[1]}"])
    end

    it 'says so when nothing of what it shows changes' do
      expect(summary.changes_from(summary('shop', 'timeout' => 9)))
        .to eq(['  changes from shop 1.0.0:', '    no change in the address, the credential, the headers, the parameters or the verbs'])
    end
  end
end
