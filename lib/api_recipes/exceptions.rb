module ApiRecipes
  class RouteNameClashError < Exception
    def initialize(message = nil, route = nil, resource = nil)
      if message
        # Nothing to do
      elsif route
        message = "route name (#{route}) can't be equal to resource name (#{resource}). Please change route or resource name."
      else
        message = "route name can't be equal to resource name. Please change route or resource names."
      end
      super(message)
    end
  end

  class MissingRouteAttribute < Exception
    def initialize(message = nil, resource = nil, route = nil,  attribute = nil)
      if message
        # Nothing to do
      elsif route && attribute
        message = "route '#{resource}.#{route}' requires '#{attribute}' attribute but this was not given"
      end
      super(message)
    end
  end

  class ResponseCodeNotAsExpected < Exception
    def initialize(message = nil, resource = nil, route = nil, expected_code = nil, actual_code = nil, reason = nil)
      if message
        # Nothing to do
      else
        message = "response code for request on route '#{resource}.#{route}' has returned #{actual_code}, but #{expected_code} was expected. Reason: #{reason}"
      end
      super(message)
    end
  end

  class EndpointConfigIsNotAnHash < Exception
    def initialize(message = nil, endpoint = nil)
      if message
        # Nothing to do
      else
        message = "provided config for endpoint '#{endpoint}' must be an Hash"
      end
      super(message)
    end
  end

  class NoConfigurationGivenForEndpoint < Exception
    def initialize(message = nil, endpoint = nil)
      if message
        # Nothing to do
      else
        message = "no configuration provided for endpoint '#{endpoint}'"
      end
      super(message)
    end
  end

  class RouteNameClashWithExistentMethod < Exception
    def initialize(resource, route)
      message = "can't define route '#{route}' method in resource '#{resource}' because method '#{route}' already exists"
      super(message)
    end
  end
end
