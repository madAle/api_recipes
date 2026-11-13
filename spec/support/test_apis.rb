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

  # Base url of the svc test api.
  def base_url
    'https://api.example.test'
  end

  def configure_test_apis(apis = TEST_APIS)
    ApiRecipes.configure do |config|
      config.logger = Logger.new(IO::NULL)
      config.apis_configs = apis
    end
  end

  # Anonymous class that declares the two test apis.
  def new_client_class
    Class.new do
      include ApiRecipes
      api :svc
      api :versioned
    end
  end

  # Builds a context and a request on the new core, without the DSL. Each node
  # of endpoint_path takes from values as many values as its path params.
  def new_request(config, endpoint_path, values = [], owner: ApiRecipes, overrides: nil, options: {}, global: :same)
    definition = ApiRecipes::Compiler.compile(:svc, config)
    context = ApiRecipes::Context.new(definition: definition, owner: owner,
                                      global_definition: global == :same ? definition : global)
    context = context.with(overrides) if overrides
    remaining = values.dup
    node = definition
    path = endpoint_path.reduce(context.base_path) do |parent_path, name|
      node = node.endpoints.fetch(name)
      own = remaining.shift(node.path_params.size)
      [parent_path, node.template.expand(own, endpoint: node.full_name)].join('/').squeeze('/')
    end
    ApiRecipes::Request.new(context: context, definition: node, path: path, options: options)
  end
end
