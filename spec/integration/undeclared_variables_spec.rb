require 'spec_helper'
require 'api_recipes/cli'
require 'tmpdir'

# A {name} that a description uses is a variable of the api, declared or not.
# The declaration is where its default and its description are written: a
# variable without one has no default, so a value must be given.
describe 'A variable that is used and not declared' do
  include RecipeHelpers

  let(:json) { { 'Content-Type' => 'application/json' } }

  before { stub_request(:any, /example\.test/).to_return(status: 200, body: '{}', headers: json) }

  # Every place where a {name} can be written, each with a value that fits it.
  PLACES = {
    'the host' => [{ host: '{x}.example.test', endpoints: { ping: nil } }, 'acme'],
    'the base_url' => [{ host: 'api.example.test', base_url: 'v/{x}', endpoints: { ping: nil } }, 'one'],
    'the path of an endpoint' => [{ host: 'api.example.test', endpoints: { ping: { path: '/{x}/ping' } } }, 'one'],
    'a header of the api' => [{ host: 'api.example.test', default_headers: { 'X-Key' => '{x}' }, endpoints: { ping: nil } }, 'one'],
    'a header of an endpoint' => [{ host: 'api.example.test', endpoints: { ping: { default_headers: { 'X-Key' => '{x}' } } } }, 'one'],
    'a parameter of the api' => [{ host: 'api.example.test', default_params: { v: '{x}' }, endpoints: { ping: nil } }, 'one'],
    'a parameter of an endpoint' => [{ host: 'api.example.test', endpoints: { ping: { default_params: { v: '{x}' } } } }, 'one'],
    'the protocol' => [{ host: 'api.example.test', protocol: '{x}', endpoints: { ping: nil } }, 'http'],
    'the port' => [{ host: 'api.example.test', port: '{x}', endpoints: { ping: nil } }, '8443'],
    'the timeout' => [{ host: 'api.example.test', timeout: '{x}', endpoints: { ping: nil } }, '5'],
    'on_bad_code' => [{ host: 'api.example.test', on_bad_code: '{x}', endpoints: { ping: nil } }, 'ignore'],
    'the mime_type' => [{ host: 'api.example.test', mime_type: '{x}', endpoints: { ping: nil } }, 'application/json'],
    'the timeout of an endpoint' => [{ host: 'api.example.test', endpoints: { ping: { timeout: '{x}' } } }, '5'],
    'the verb of an endpoint' => [{ host: 'api.example.test', endpoints: { ping: { verb: '{x}' } } }, 'post'],
    'the ok_code of an endpoint' => [{ host: 'api.example.test', endpoints: { ping: { ok_code: '{x}' } } }, '200']
  }.freeze

  PLACES.each do |place, (described, value)|
    describe "in #{place}" do
      before { configure_test_apis(svc: described) }

      it 'is a variable of the api, with no default' do
        expect(ApiRecipes.svc.definition.variables).to eq(x: { default: nil, description: nil })
      end

      it 'takes its value from the application, from an object and from with' do
        global_values(svc: { variables: { x: value } })
        expect(ApiRecipes.svc.ping.run.code).to eq(200)
        configure_test_apis(svc: described)
        expect(ApiRecipes.svc.with(variables: { x: value }).ping.run.code).to eq(200)
        client = Class.new { include ApiRecipes; api :svc }.new # rubocop:disable Style/Semicolon
        client.svc.variables = { x: value }
        expect(client.svc.ping.run.code).to eq(200)
      end

      it 'raises MissingVariable, which names it, when a request has no value for it, and sends nothing' do
        expect { ApiRecipes.svc.ping.run }
          .to raise_error(ApiRecipes::MissingVariable, "api 'svc' requires the variable 'x' but it was not provided")
        expect(WebMock).not_to have_requested(:any, /./)
      end
    end
  end

  it 'is listed after the declared ones, each once, in the order they are first written' do
    configure_test_apis(svc: { host: '{shop}.example.test', base_url: '{zone}/{version}', default_headers: { 'X-Zone' => '{zone}' },
                               variables: { version: { default: 'v1' } },
                               endpoints: { ping: { path: '/{tenant}/ping', default_params: { shop: '{shop}' } } } })
    expect(ApiRecipes.svc.definition.variables.keys).to eq(%i[version shop zone tenant])
    expect(ApiRecipes.svc.definition.variables[:version]).to eq(default: 'v1', description: nil)
  end

  it 'still refuses a name that the api neither declares nor uses, at every level' do
    described = { host: '{shop}.example.test', variables: { version: { default: 'v1' } }, endpoints: { ping: nil } }
    unknown = "unknown variable 'shpo' (variables of the api: shop, version)"
    configure_test_apis(svc: described)
    expect { global_values(svc: { variables: { shpo: 'acme' } }) }
      .to raise_error(ApiRecipes::ConfigurationError) { |error| expect(error.errors).to eq(["svc.variables: #{unknown}"]) }
    expect { ApiRecipes.svc.with(variables: { shpo: 'acme' }) }
      .to raise_error(ApiRecipes::ConfigurationError) { |error| expect(error.errors).to eq(["variables: #{unknown}"]) }
    client = Class.new { include ApiRecipes; api :svc }.new # rubocop:disable Style/Semicolon
    expect { client.svc.variables = { shpo: 'acme' } }.to raise_error(ApiRecipes::ConfigurationError, /#{Regexp.escape(unknown)}/)
    expect { Class.new { include ApiRecipes; api :svc, variables: { shpo: 'acme' } } } # rubocop:disable Style/Semicolon
      .to raise_error(ApiRecipes::ConfigurationError, /#{Regexp.escape(unknown)}/)
  end

  it 'says that an api has no variables when it has none' do
    configure_test_apis(svc: { host: 'api.example.test', endpoints: { ping: nil } })
    expect { ApiRecipes.svc.with(variables: { shop: 'acme' }) }
      .to raise_error(ApiRecipes::ConfigurationError, "1 problem in the configuration\n  variables: unknown variable 'shop' (the api has no variables)")
  end

  it 'does not make a variable of a word in escaped braces, nor of a path parameter' do
    configure_test_apis(svc: { host: 'api.example.test', base_url: 'v/\{draft}', endpoints: { ping: { path: '/\{id}/:id' } } })
    expect(ApiRecipes.svc.definition.variables).to eq({})
    expect(ApiRecipes.svc.ping(7).url.to_s).to eq('https://api.example.test/v/%7Bdraft%7D/%7Bid%7D/7')
  end

  describe 'in the options a class gives to api' do
    before { configure_test_apis(svc: { host: 'api.example.test', variables: { version: { default: 'v1' } }, endpoints: { ping: nil } }) }

    it 'is a variable of the tree of that class, and not of the api of the application' do
      klass = Class.new do
        include ApiRecipes
        api :svc, host: '{tenant}.example.test'
      end
      expect(klass.svc.definition.variables.keys).to eq(%i[version tenant])
      expect(ApiRecipes.svc.definition.variables.keys).to eq(%i[version])
      expect { klass.svc.ping.run }.to raise_error(ApiRecipes::MissingVariable, /'tenant'/)
      expect(klass.svc.with(variables: { tenant: 'acme' }).ping.url.to_s).to eq('https://acme.example.test/ping')
    end

    it 'takes the value the same call to api gives, when the application is configured already and when it is not' do
      declare = lambda do
        Class.new do
          include ApiRecipes
          api :svc, host: '{tenant}.example.test', variables: { tenant: 'acme' }
        end
      end
      expect(declare.call.svc.ping.url.to_s).to eq('https://acme.example.test/ping')
      ApiRecipes.reset!
      klass = declare.call
      configure_test_apis(svc: { host: 'api.example.test', endpoints: { ping: nil } })
      expect(klass.svc.ping.url.to_s).to eq('https://acme.example.test/ping')
    end

    it 'still refuses, when api is called, a value for a name that neither the api nor the options use' do
      expect do
        Class.new do
          include ApiRecipes
          api :svc, host: '{tenant}.example.test', variables: { tenat: 'acme' }
        end
      end.to raise_error(ApiRecipes::ConfigurationError) { |error|
        expect(error.errors).to eq(["svc.variables: unknown variable 'tenat' (variables of the api: tenant, version)"])
      }
    end
  end

  describe 'in a portable recipe' do
    let(:text) do
      recipe_text('shop', 'host' => '{tenant}.example.test', 'default_headers' => { 'X-Key' => '{key}' },
                          'variables' => { 'zone' => { 'default' => 'eu' } }, 'base_url' => '{zone}',
                          'endpoints' => { 'ping' => nil })
    end

    it 'loads, and asks for a value at the first request' do
      Dir.mktmpdir do |dir|
        path = write_recipe(dir, 'shop', text)
        configure_recipes(path)
        expect(ApiRecipes.shop.definition.variables.keys).to eq(%i[zone tenant key])
        expect { ApiRecipes.shop.ping.run }.to raise_error(ApiRecipes::MissingVariable, /'tenant'/)
        configure_recipes(path, values: { shop: { variables: { tenant: 'acme', key: 'k' } } })
        ApiRecipes.shop.ping.run
        expect(WebMock).to have_requested(:get, 'https://acme.example.test/eu/ping').with(headers: { 'X-Key' => 'k' })
      end
    end
  end
end
