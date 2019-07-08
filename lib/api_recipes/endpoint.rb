module ApiRecipes
  class Endpoint

    attr_accessor :name, :configs, :authorization, :basic_auth
    attr_reader :resources

    def initialize(name, configs)
      @name = name
      @configs = ApiRecipes::Settings::DEFAULT.merge configs

      # Generate   some_endpoint.some_resource  methods
      # e.g.  github.users
      @resources = [] unless @resources
      @configs[:routes].each do |resource, routes|
        @resources << resource
        res = Resource.new resource, self, routes
        unless respond_to? resource
          define_singleton_method resource do
            res
          end
        end
      end
    end

    def authorization=(auth)
      @authorization = auth

      # Check if I'm the global endpoint
      if global?
        # Set authorization also on every "children" (classes that define the same endpoint)
        ApiRecipes.set_authorization_for_endpoint auth, name
      end
    end

    def basic_auth=(auth)
      @basic_auth = auth

      # Check if I'm the global endpoint
      if global?
        # Set authorization also on every "children" (classes that define the same endpoint)
        ApiRecipes.set_basic_auth_for_endpoint auth, name
      end
    end

    private

    def global?
      ApiRecipes._aprcps_global_storage[name] == self
    end
  end
end
