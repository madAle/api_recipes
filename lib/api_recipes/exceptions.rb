module ApiRecipes

  class ApiNameClashError < Exception
    def initialize(object, endpoint_name)
      message = "#{object.class} already defines a method called '#{endpoint_name}'. Tip: change api name"
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
    def initialize(endpoint = nil, route = nil,  attribute = nil)
      message = "route '#{endpoint}.#{route}' requires '#{attribute}' attribute but this was not provided"
      super(message)
    end
  end

  class PathParamsMismatch < Exception
    def initialize(path, expected_params, provided_params)
      if expected_params.size == 0
        message = "route '#{path}' requires NO PARAMS but #{provided_params} were provided"
      else
        message = "route '#{path}' requires params #{expected_params} but #{provided_params} were provided"
      end
      super(message)
    end
  end

  class ProvidedObjectNotAsResponseData < Exception
    def initialize(object_class, data_class)
      message = "provided object #{object_class} is not compatible with response data that is of type #{data_class}"
      super(message)
    end
  end

  class ResponseCodeNotAsExpected < Exception

    def initialize(endpoint = nil, route = nil, expected_code = nil, response_code = nil, response_body = nil)
      message = "response code for request on route '#{endpoint}.#{route}' has returned #{response_code}, but #{expected_code} was expected. Reason: #{response_body}"
      super(message)
    end
  end

  class ApiConfigIsNotAnHash < Exception
    def initialize(endpoint)
      message = "provided config for endpoint '#{endpoint}' must be an Hash"
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
    def initialize(endpoint_name, route_name)
      message = "can't define route '#{route_name}' method in endpoint '#{endpoint_name}' because method '#{route_name}' has already been defined"
      super(message)
    end
  end

  class NoRouteExists < Exception
    def initialize(endpoint_name)
      message = "no route defined on #{endpoint_name}"
      super(message)
    end
  end
end
