module ApiRecipes
  class Api

    attr_accessor :name, :configs, :authorization, :basic_auth

    def initialize(name, configs)
      @name = name
      @configs = ApiRecipes::Settings::DEFAULT.merge configs

      # Generate   some_api.some_endpoint  methods
      # e.g.  github.users
      @configs[:endpoints].each do |ep_name, routes|
        ep = Endpoint.new ep_name, self, routes
        unless respond_to? ep_name
          define_singleton_method ep_name do
            ep
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

    private

    def global?
      ApiRecipes._aprcps_global_storage[name] == self
    end
  end
end
