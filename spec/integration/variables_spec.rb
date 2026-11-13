require 'spec_helper'
require 'stringio'

describe 'Variables that the api does not declare' do
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:shopify) do
    { host: '{shop}.example.test', base_url: 'admin/api/{api_version}',
      variables: { shop: {}, api_version: { default: '2026-10' } }, endpoints: { orders: nil } }
  end
  let(:plain) { { host: 'plain.example.test', endpoints: { orders: nil } } }
  let(:unknown_shpo) { "unknown variable 'shpo' (declared: api_version, shop)" }

  before { stub_request(:any, /example\.test/).to_return(status: 200, body: '{}', headers: json) }

  def problems(error) = error.errors

  describe 'with' do
    before { configure_test_apis(shopify: shopify, plain: plain) }

    it 'raises at the with call with the declared names sorted' do
      expect { ApiRecipes.shopify.with(variables: { shpo: 'acme' }) }
        .to raise_error(ApiRecipes::ConfigurationError) { |e| expect(problems(e)).to eq(["variables: #{unknown_shpo}"]) }
    end

    it 'accepts String keys and reports every unknown name' do
      expect { ApiRecipes.shopify.with(variables: { 'shop' => 'a', 'one' => 1, two: 2 }) }
        .to raise_error(ApiRecipes::ConfigurationError) { |e|
          expect(problems(e)).to eq(["variables: unknown variable 'one' (declared: api_version, shop)",
                                     "variables: unknown variable 'two' (declared: api_version, shop)"])
        }
    end

    it 'says that none is declared' do
      expect { ApiRecipes.plain.with(variables: { shop: 'a' }) }
        .to raise_error(ApiRecipes::ConfigurationError) { |e|
          expect(problems(e)).to eq(["variables: unknown variable 'shop' (none declared)"])
        }
    end

    it 'keeps working for declared names, nil included' do
      api = ApiRecipes.shopify.with(variables: { 'shop' => 'acme', 'api_version' => '2027-01' })
      expect(api.orders.url.to_s).to eq('https://acme.example.test/admin/api/2027-01/orders')
      nil_api = ApiRecipes.shopify.with(variables: { shop: 'acme', api_version: nil })
      expect { nil_api.orders.url }.to raise_error(ApiRecipes::InvalidVariable, /api_version/)
    end

    it 'checks a chain of withs against the same api' do
      api = ApiRecipes.shopify.with(variables: { shop: 'acme' })
      expect { api.with(variables: { shpo: 'x' }) }.to raise_error(ApiRecipes::ConfigurationError, /shpo/)
    end
  end

  describe 'variables=' do
    before { configure_test_apis(shopify: shopify, plain: plain) }

    it 'raises on a global handle and keeps the level' do
      ApiRecipes.shopify.variables = { shop: 'acme' }
      expect { ApiRecipes.shopify.variables = { shpo: 'x' } }
        .to raise_error(ApiRecipes::ConfigurationError) { |e| expect(problems(e)).to eq(["variables: #{unknown_shpo}"]) }
      expect(ApiRecipes.shopify.variables).to eq(shop: 'acme')
    end

    it 'raises on a class and on an instance and keeps their levels' do
      klass = Class.new do
        include ApiRecipes
        api :shopify
      end
      klass.shopify.variables = { shop: 'class' }
      expect { klass.shopify.variables = { shpo: 'x' } }.to raise_error(ApiRecipes::ConfigurationError, /shpo/)
      expect(klass.shopify.variables).to eq(shop: 'class')
      object = klass.new
      object.shopify.variables = { shop: 'object' }
      expect { object.shopify.variables = { 'shpo' => 'x' } }.to raise_error(ApiRecipes::ConfigurationError, /shpo/)
      expect(object.shopify.variables).to eq(shop: 'object')
    end

    it 'still clears the level with nil and sets declared names' do
      ApiRecipes.shopify.variables = { 'shop' => 'acme' }
      expect(ApiRecipes.shopify.variables).to eq(shop: 'acme')
      ApiRecipes.shopify.variables = nil
      expect(ApiRecipes.shopify.variables).to eq({})
    end

    it 'says that none is declared' do
      expect { ApiRecipes.plain.variables = { shop: 'a' } }
        .to raise_error(ApiRecipes::ConfigurationError, /unknown variable 'shop' \(none declared\)/)
    end
  end

  describe 'api in a class or a module' do
    it 'raises when the declaration is made if the global api is configured' do
      configure_test_apis(shopify: shopify)
      expect do
        Class.new do
          include ApiRecipes
          api :shopify, variables: { shpo: 'x' }
        end
      end.to raise_error(ApiRecipes::ConfigurationError) { |e|
        expect(problems(e)).to eq(["shopify.variables: #{unknown_shpo}"])
      }
    end

    it 'raises at the first use if the api is not known at declaration' do
      klass = Class.new do
        include ApiRecipes
        api :shopify, variables: { shpo: 'x' }
      end
      configure_test_apis(shopify: shopify)
      expect { klass.shopify }.to raise_error(ApiRecipes::ConfigurationError) { |e|
        expect(problems(e)).to eq(["shopify.variables: #{unknown_shpo}"])
      }
      expect { klass.new.shopify }.to raise_error(ApiRecipes::ConfigurationError, /shpo/)
    end

    it 'raises at the first use for an api declared by the class alone, which has no variables' do
      klass = Class.new do
        include ApiRecipes
        api :local, host: 'local.example.test', variables: { shop: 'x' }
      end
      expect { klass.local }
        .to raise_error(ApiRecipes::ConfigurationError, /local.variables: unknown variable 'shop' \(none declared\)/)
    end

    it 'does not store a declaration that fails' do
      configure_test_apis(shopify: shopify)
      klass = Class.new { include ApiRecipes }
      expect { klass.api :shopify, variables: { shpo: 'x' } }.to raise_error(ApiRecipes::ConfigurationError)
      klass.api :shopify, variables: { 'shop' => 'ok' }
      expect(klass.shopify.orders.url.to_s).to eq('https://ok.example.test/admin/api/2026-10/orders')
    end

    it 'works in a module' do
      configure_test_apis(shopify: shopify)
      expect do
        Module.new do
          include ApiRecipes
          api :shopify, variables: { shpo: 'x' }
        end
      end.to raise_error(ApiRecipes::ConfigurationError, /shopify.variables: unknown variable 'shpo'/)
    end
  end

  describe 'config.variables' do
    let(:log) { StringIO.new }

    def configure_with(variables, apis = { shopify: shopify })
      logger = Logger.new(log)
      ApiRecipes.configure do |config|
        config.logger = logger
        config.apis_configs = apis
        config.variables = variables
      end
    end

    it 'reports an unknown name with the other problems and keeps the previous configuration' do
      configure_with({ shopify: { shop: 'before' } })
      broken = { shopify: shopify, other: { host: 'x.test', on_bad_code: 'explode' } }
      expect { configure_with({ shopify: { shpo: 'acme' } }, broken) }
        .to raise_error(ApiRecipes::ConfigurationError) { |e|
          expect(problems(e)).to include("shopify.variables: #{unknown_shpo}")
          expect(problems(e).size).to eq(2)
        }
      expect(ApiRecipes.apis).to eq([:shopify])
      expect(ApiRecipes.shopify.orders.url.to_s).to eq('https://before.example.test/admin/api/2026-10/orders')
    end

    it 'reports it alone with String keys' do
      expect { configure_with({ 'shopify' => { 'shpo' => 'acme' } }) }
        .to raise_error(ApiRecipes::ConfigurationError) { |e|
          expect(problems(e)).to eq(["shopify.variables: #{unknown_shpo}"])
        }
    end

    it 'accepts declared names' do
      configure_with({ 'shopify' => { 'shop' => 'acme', api_version: '2027-01' } })
      expect(ApiRecipes.shopify.orders.url.to_s).to eq('https://acme.example.test/admin/api/2027-01/orders')
    end

    it 'warns about an api that is not configured, without failing' do
      configure_with({ shpoify: { shop: 'a' } })
      expect(log.string).to include("variables are given for 'shpoify', which is not a configured api")
    end

    it 'does not warn when every api is configured' do
      configure_with({ shopify: { shop: 'a' } })
      expect(log.string).not_to include('not a configured api')
    end

    it 'gives the values to a class that declares that api as its global level' do
      configure_with({ local: { shop: 'global' } })
      klass = Class.new do
        include ApiRecipes
        api :local, host: 'local.example.test'
      end
      context = klass.local.instance_variable_get(:@context)
      expect(context.variables).to eq(shop: 'global')
    end
  end
end
