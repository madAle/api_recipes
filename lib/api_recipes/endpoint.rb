module ApiRecipes
  class Endpoint

    attr_accessor :name, :settings
    attr_reader :resources

    def initialize(name, config)
      @name = name
      @config = config
      @settings = ApiRecipes::Settings::DEFAULT.merge config.endpoints_configs[name]

      # Generate   some_endpoint.some_resource  methods
      # e.g.  github.users
      @resources = [] unless @resources
      @settings[:routes].each do |resource, routes|
        @resources << resource
        res = Resource.new resource, self, routes
        define_singleton_method resource do
          res
        end
      end
    end

    def auth=(value)
      if value
        unless @api_recipes_auth
          @api_recipes_auth = {}
        end
        @api_recipes_auth[name] = value
      end
    end

    def auth
      if a = @api_recipes_auth
        a[name]
      else
        nil
      end
    end

    def basic_auth=(value)
      if value
        unless @api_recipes_basic_auth
          @api_recipes_basic_auth = {}
        end
        @api_recipes_basic_auth[name] = value
      end
    end

    def basic_auth
      if ba = @api_recipes_basic_auth
        ba[name]
      else
        nil
      end
    end
  end
end
