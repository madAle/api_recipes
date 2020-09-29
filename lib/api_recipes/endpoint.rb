module ApiRecipes
  class Endpoint

    def initialize(name, api, routes = {})
      @name = name
      @api = api
      @routes = routes

      generate_routes
    end

    private

    def generate_routes
      @routes.each do |route, attrs|
        # Check if route name clashes with resource name
        if route.eql? @name
          raise RouteAndResourceNamesClashError.new(route, @name)
        end
        unless respond_to? route.to_sym
          define_singleton_method route do |*params, &block|
            build_request route, attrs, *params, &block
          end
        else
          raise RouteNameClashWithExistentMethod.new(@name, route)
        end
      end
    end
  end
end
