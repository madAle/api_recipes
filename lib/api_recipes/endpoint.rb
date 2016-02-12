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
  end
end
