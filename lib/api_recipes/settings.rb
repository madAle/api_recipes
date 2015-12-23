module ApiRecipes
  module Settings
    GLOBAL_TIMEOUT = 1
    FAIL_OPTIONS = [:return, :raise, :return_false]

    DEFAULT = {
        protocol: 'http',
        host: 'localhost',
        port: nil,
        base_path: '',
        api_version: '',
        timeout: 3,
        on_nok_code: :raise,
        routes: {}
    }

    DEFAULT_ROUTE_ATTRIBUTES = {
      method: :get,
      encode_params_as: :json
    }

    AVAILABLE_PARAMS_ENCODINGS = %w(form params json body)
  end
end
