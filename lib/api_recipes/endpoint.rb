module ApiRecipes
  class Endpoint

    attr_reader :api, :name, :params, :route, :children

    def initialize(api: nil, name: nil, path: nil, params: {}, request_params: {}, &block)
      @api = api
      @name = name
      @path = path.to_s
      new_params = params.dup
      self.params = new_params
      @children = new_params.delete :endpoints
      @route = nil
      @request_params = request_params

      generate_route
      generate_children
      if block_given?
        run &block
      end
    end

    def run(&block)
      if @route
        @route.start_request &block
      else
        raise NoRouteExists.new @name
      end
    end

    private

    def generate_route
      # Check if we have to generate route for this endpoint
      if create_route?
        check_route_name_does_not_clash @name
        # Generate route
        attrs = params.dup
        attrs.delete(:endpoints)
        # puts "generating #{@name} with path #{absolute_path}"
        @route = Route.new(api: @api, endpoint: self, path: absolute_path, attributes: attrs, req_pars: @request_params)
      end
    end

    def generate_children
      # Generate children endpoints if any
      if children
        children.each do |ep_name, pars|
          # puts "creating Endpoint #{ep_name} passing path #{absolute_path}"
          define_singleton_method ep_name do |*request_params, &block|
            Endpoint.new api: @api, name: ep_name, path: absolute_path, params: pars, request_params: request_params, &block
          end
        end
      end
      # Route.new(api: @api, endpoint: self, name: route_name, attributes: route_attrs, req_pars: request_params).start_request &block
    end

    # def generate_routes
    #   @routes.each do |route_name, route_attrs|
    #     # Check if route_name clashes with resource name
    #     if route_name.eql? @name
    #       raise RouteAndResourceNamesClashError.new(route_name, @name)
    #     end
    #     # Check if a method named route_name has already been defined on this object
    #     unless respond_to? route_name
    #       # Define #route_name method
    #       define_singleton_method route_name do |*request_params, &block|
    #         handle_route route_name, *request_params, block
    #         Route.new(api: @api, endpoint: self, name: route_name, attributes: route_attrs, req_pars: request_params).start_request &block
    #       end
    #     else
    #       raise RouteNameClashWithExistentMethod.new(@name, route_name)
    #     end
    #   end
    # end

    def check_route_name_does_not_clash(route_name)
      # Check if a method named route_name has already been defined on this object
      if respond_to? route_name
        raise RouteNameClashWithExistentMethod.new(@name, route_name)
      end
    end

    def create_route?
      res = params[:route].eql?('yes') || params[:route].eql?(true)
      res
    end

    def absolute_path
      # Append path passed to initialize and (params[:path] || @name)
      "#{@path}/#{params[:path] || @name}".gsub(/\/+/, '/')
    end

    def params=(attrs)
      unless attrs.is_a? Hash
        raise ArgumentError, "provided 'attrs' must be an Hash"
      end
      # Merge DEFAULT_ROUTE_ATTRIBUTES with Api base_configs
      # Then merge the result with provided attributes

      @params = Settings::DEFAULT_ROUTE_ATTRIBUTES.inject({}) do |out, key_val|
        new_val = @api.base_configs[key_val.first]
        out[key_val.first] = new_val.nil? ? key_val.last : new_val
        out
      end.inject({}) do |out, key_val|
        new_val = attrs[key_val.first]
        out[key_val.first] = new_val.nil? ? key_val.last : new_val
        out
      end
    end
  end
end
