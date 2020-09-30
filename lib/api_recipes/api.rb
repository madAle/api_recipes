module ApiRecipes
  class Api

    attr_accessor :name, :configs, :authorization, :basic_auth
    attr_reader :base_configs

    BASE_CONFIGS_KEYS = [:protocol, :host, :port, :api_version, :timeout, :on_bad_code]

    def initialize(name, configs)
      @name = name
      @configs = ApiRecipes::Settings::DEFAULT.merge configs

      # Generate   some_api.some_endpoint  methods
      # e.g.  github.users
      @configs[:endpoints].each do |ep_name, params|
        unless respond_to? ep_name
          define_singleton_method ep_name do |*request_params, &block|
            # puts "API params: #{params}"
            Endpoint.new api: self, name: ep_name, path: path, params: params, request_params: request_params, &block
          end
        end
      end
    end

    def authorization=(auth)
      @authorization = auth

      # Check if I'm the global api
      if global?
        # Set authorization also on every "children" (classes that define the same api)
        ApiRecipes.set_authorization_for_api auth, name
      end
    end

    def basic_auth=(auth)
      @basic_auth = auth

      # Check if I'm the global api
      if global?
        # Set authorization also on every "children" (classes that define the same api)
        ApiRecipes.set_basic_auth_for_api auth, name
      end
    end

    def base_configs
      @configs.select { |c| BASE_CONFIGS_KEYS.include? c }
    end

    private

    def check_route_name_does_not_clash(route_name)
      # Check if a method named route_name has already been defined on this object
      if respond_to? route_name
        raise RouteNameClashWithExistentMethod.new(@name, route_name)
      end
    end

    def global?
      ApiRecipes._aprcps_global_storage[name] == self
    end

    def path
      '/'
    end
  end
end
