module ApiRecipes
  class Endpoint

    attr_accessor :name, :settings, :authorization, :basic_auth
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
  end
end
