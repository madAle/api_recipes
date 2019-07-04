module ApiRecipes

  class EndpointNameClashError < Exception
    def initialize(object, endpoint_name)
      message = "#{object.class} already defines a method called '#{endpoint_name}'. Tip: change endpoint name"
      super(message)
    end
  end

  class RouteAndResourceNamesClashError < Exception
    def initialize(route_name, resource_name)
      message = "route name (#{route_name}) can't be equal to resource name (#{resource_name}). Please change route or resource name."
      super(message)
    end
  end

  class MissingRouteAttribute < Exception
    attr_reader :resource, :route, :attribute

    def initialize(message = nil, resource = nil, route = nil,  attribute = nil)
      @resource = resource; @route = route; @attribute = attribute
      if message
        # Nothing to do
      elsif @route && @attribute
        message = "route '#{@resource}.#{@route}' requires '#{@attribute}' attribute but this was not given"
      end
      super(message)
    end
  end

  class ResponseCodeNotAsExpected < Exception
    attr_reader :resource, :route, :expected_code, :response_code, :response_body

    def initialize(message = nil, resource = nil, route = nil, expected_code = nil, response_code = nil, response_body = nil)
      @resource = resource; @route = route; @expected_code = expected_code; @response_code = response_code; @response_body = response_body
      if message
        # Nothing to do
      else
        message = "response code for request on route '#{@resource}.#{@route}' has returned #{@response_code}, but #{@expected_code} was expected. Reason: #{@response_body}"
      end
      super(message)
    end
  end

  class EndpointConfigIsNotAnHash < Exception
    attr_reader :endpoint

    def initialize(message = nil, endpoint = nil)
      @endpoint = endpoint
      if message
        # Nothing to do
      else
        message = "provided config for endpoint '#{@endpoint}' must be an Hash"
      end
      super(message)
    end
  end

  class NoConfigurationGivenForEndpoint < Exception
    attr_reader :endpoint

    def initialize(message = nil, endpoint = nil)
      @endpoint = endpoint
      if message
        # Nothing to do
      else
        message = "no configuration provided for endpoint '#{@endpoint}'"
      end
      super(message)
    end
  end

  class RouteNameClashWithExistentMethod < Exception
    attr_reader :resource, :route

    def initialize(resource, route)
      @resource = resource; @route = route
      message = "can't define route '#{@route}' method in resource '#{@resource}' because method '#{@route}' already exists"
      super(message)
    end
  end
end
