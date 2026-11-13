require 'logger'

module TestApis
  TEST_APIS = {
    svc: {
      host: 'api.example.test',
      default_headers: { accept: 'application/json' },
      endpoints: {
        users:   { endpoints: { show: { path: '/:id' } } },
        repos:   { path: '/repos/:owner', endpoints: { contributors: nil } },
        files:   { path: '/files/:name.json' },
        create:  { path: '/users', verb: :post, ok_code: 201 },
        lenient: { on_bad_code: 'ignore' },
        checked: { verify_with: :response_ok? },
        group:   { route: false, endpoints: { ping: {} } }
      }
    },
    versioned: {
      protocol: 'http', host: 'api.example.test', port: 8080, base_url: 'v1',
      endpoints: { ping: {} }
    }
  }.freeze

  BASE = 'https://api.example.test'.freeze

  def configure_test_apis(apis = TEST_APIS)
    ApiRecipes.configure do |config|
      config.logger = Logger.new(IO::NULL)
      config.apis_configs = apis
    end
  end

  # Classe anonima che dichiara le due API di test.
  def new_client_class
    Class.new do
      include ApiRecipes
      api :svc
      api :versioned
    end
  end
end
