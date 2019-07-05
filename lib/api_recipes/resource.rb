module ApiRecipes
  class Resource

    def initialize(name, endpoint, routes = {})
      @name = name
      @routes = routes
      @endpoint = endpoint

      generate_routes
    end

    private

    def build_path(route_name, route_attributes, provided_params)
      path = route_attributes[:path] || ''

      required_params_for_path(path).each do |rp|
        unless p = provided_params.delete(rp)
          raise MissingRouteAttribute.new(@name, route_name, rp)
        end
        path.gsub! ":#{rp}", p.to_s
      end
      path = "#{settings[:base_path]}#{settings[:api_version]}/#{@name}#{path}"
      return path, provided_params
    end

    def build_request


    end

    def build_uri_from(path)
      attrs = {
          scheme: settings[:protocol],
          host: settings[:host],
          port: port,
          path: path
      }
      URI::Generic.build attrs
    end

    def check_response_code(route, route_attributes, response)
      # Check if :ok_code is present, check the response
      if ok_code = route_attributes[:ok_code]
        code = response.code
        # If the code does not match, apply the requested strategy (see FAIL_OPTIONS)
        unless code == ok_code
          case settings[:on_nok_code]
            when :do_nothing
            when :raise
              raise ResponseCodeNotAsExpected.new(nil, @name, route, ok_code, code, response.body)
            when :return_false
              return false
          end
        end
      end
    end

    def encode_residual_params(route_attributes, residual_params)
      # If :encode_params_as is specified and avalable use it
      if Settings::AVAILABLE_PARAMS_ENCODINGS.include? route_attributes[:encode_params_as].to_s
        { route_attributes[:encode_params_as].to_sym => residual_params }
      else
        # default to query string params (get) or json (other methods)
        case route_attributes[:method].to_sym
          when :get
            { params: residual_params }
          when :post, :put, :patch, :delete
            { json: residual_params }
        end
      end
    end

    def extract_headers
      settings[:default_headers] || {}
    end

    # Generate routes  some_endpoint.some_resource.some_route  methods
    # e.g. webapp.alarms.index
    def generate_routes
      @routes.each do |route, attrs|
        # Check if route name clashes with resource name
        if route.eql? @name
          raise RouteAndResourceNamesClashError.new(route, @name)
        end
        unless respond_to? route.to_sym
          define_singleton_method route.to_sym do |*params, &block|
            start_request route, attrs, *params, &block
          end
        else
          raise RouteNameClashWithExistentMethod.new(@name, route)
        end
      end
      self
    end

    def timeout
      settings.fetch(:timeout, ApiRecipes::Settings::GLOBAL_TIMEOUT)/3.0
    end

    def port
      settings[:port] || case settings[:protocol]
                           when 'http'
                             80
                           when 'https'
                             443
                         end
    end

    def request_with_auth
      req = HTTP
      req = req.headers(extract_headers)
                .timeout(timeout)

      basic_auth = @endpoint.basic_auth
      if basic_auth
        req = req.basic_auth basic_auth
      end
      authorization = @endpoint.authorization
      if authorization
        req = req.auth authorization
      end
      req
    end

    def required_params_for_path(path)
      path.scan(/:(\w+)/).flatten.map { |p| p.to_sym }
    end

    def settings
      @endpoint.configs
    end

    def start_request(route, route_attributes, *pars)
      unless route_attributes
        route_attributes = {}
      end
      # Merge route attributes with defaults and deep clone route attributes
      route_attributes = Marshal.load(Marshal.dump(Settings::DEFAULT_ROUTE_ATTRIBUTES.merge(route_attributes).deep_symbolize_keys))

      params = pars.extract_options!
      path, residual_params = build_path(route, route_attributes, params)
      residual_params = nil unless residual_params.any?
      uri = build_uri_from path

      response = request_with_auth.send(route_attributes[:method], uri, encode_residual_params(route_attributes, residual_params))
      check_response_code route, route_attributes, response

      if block_given?
        body = Oj.load(response.body.to_s)
        yield body, response.code, response.reason
      else
        response
      end
    end
  end
end
