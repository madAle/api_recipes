module ApiRecipes
  class Endpoint

    attr_reader :api, :name, :params, :route, :children

    def initialize(api: nil, name: nil, path: nil, params: {}, request_params: [], &block)
      @api = api
      @name = name
      @path = path.to_s
      new_params = params.dup || {}
      self.params = new_params
      @children = new_params.delete :endpoints
      @route = nil
      @request_params = request_params.extract_options!
      self.path_params = request_params

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
        ensure_route_does_not_clash @name
        # Generate route
        attrs = params.dup
        attrs.delete(:endpoints)
        # puts "Generating route '#{@name}' with path '#{build_path}'"
        @route = Route.new(api: @api, endpoint: self, path: build_path, attributes: attrs, req_pars: @request_params)
      end
    end

    def generate_children
      # Generate children endpoints if any
      # puts "generating children of #{@name}: #{children.inspect}"
      if children
        children.each do |ep_name, pars|
          # puts "Creating Endpoint '#{@name}' child '#{ep_name}' passing path #{build_path}"
          define_singleton_method ep_name do |*request_params, &block|
            Endpoint.new api: @api, name: ep_name, path: build_path, params: pars, request_params: request_params, &block
          end
        end
      end
      # Route.new(api: @api, endpoint: self, name: route_name, attributes: route_attrs, req_pars: request_params).start_request &block
    end

    def ensure_route_does_not_clash(route_name)
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
      append = params[:path] || @name
      unless append.empty?
        "#{@path}/#{append}"
      else
        "#{@path}"
      end.gsub(/\/+/, '/')   # remove multiple consecutive '//'
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

    def build_path
      final_path = absolute_path
      # Check if provided path_params match with required path params
      req_params = required_params_for_path
      if @path_params.size != req_params.size
        # puts "\nWARNING\n"
        raise PathParamsMismatch.new(final_path, req_params, @path_params)
      end
      # Replace required_params present in path with params provided by user (@path_params)
      @path_params.each { |par| final_path.sub! /(:[^\/]+)/, par.to_s }

      final_path
    end

    def path_params=(params)
      unless params.is_a? Array
        raise ArgumentError, 'path params must be an Array'
      end
      # Merge route attributes with defaults and deep clone route attributes
      @path_params = params
    end

    def required_params_for_path
      absolute_path.scan(/:(\w+)/).flatten.map { |p| p.to_sym }
    end
  end
end
