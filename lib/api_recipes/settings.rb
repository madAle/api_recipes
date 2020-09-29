module ApiRecipes
  module Settings
    GLOBAL_TIMEOUT = 1
    FAIL_OPTIONS = [:return, :raise, :return_false]

    DEFAULT = {
        protocol: 'https',
        host: 'localhost',
        port: nil,
        base_path: '',
        api_version: '',
        timeout: 3,
        on_wrong_http_code: :raise,
        endpoints: {}
    }

    DEFAULT_ROUTE_ATTRIBUTES = {
        method: :get
    }

    AVAILABLE_PARAMS_ENCODINGS = %w(form params json body)
  end
end
