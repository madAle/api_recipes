module ApiRecipes
  module Settings
    GLOBAL_TIMEOUT = 1

    DEFAULT = {
        protocol: 'https',
        host: 'localhost',
        port: nil,
        base_url: nil,
        timeout: 3,
        on_bad_code: 'raise',
        endpoints: {}
    }

    DEFAULT_ROUTE_ATTRIBUTES = {
        verb: :get,
        route: 'yes',
        path: nil,
        ok_code: nil,
        timeout: DEFAULT[:timeout],
        on_bad_code: DEFAULT[:on_bad_code]
    }

    AVAILABLE_PARAMS_ENCODINGS = %w(form params json body)
  end
end
