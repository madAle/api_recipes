module ApiRecipes
  class Error < StandardError; end

  class ConfigurationError < Error
    attr_reader :errors

    def initialize(errors)
      @errors = errors
      count = errors.size
      noun = count == 1 ? 'problem' : 'problems'
      super("#{count} #{noun} in the configuration\n  #{errors.join("\n  ")}")
    end
  end

  class RecipeFileError < ConfigurationError
    attr_reader :path

    def initialize(path, reason)
      @path = path
      super(["#{path}: #{reason}"])
    end
  end

  class InvalidPathParameter < Error
    def initialize(endpoint, param, reason)
      super("invalid value for path parameter '#{param}' of '#{endpoint}': #{reason}")
    end
  end

  class UnknownEndpoint < Error
    def initialize(parent, name, available)
      super("'#{parent}' has no endpoint '#{name}'. Available: #{available.join(', ')}")
    end
  end

  class MissingVariable < Error
    def initialize(api, variable)
      super("api '#{api}' requires the variable '#{variable}' but it was not provided")
    end
  end

  class InvalidVariable < Error
    def initialize(api, variable, reason)
      super("invalid value for variable '#{variable}' of api '#{api}': #{reason}")
    end
  end

  class InvalidCredential < Error
    def initialize(reason)
      super("invalid credential: #{reason}")
    end
  end

  class InvalidUrl < Error
    def initialize(reason)
      super("invalid url: #{reason}")
    end
  end

  class CredentialOriginMismatch < Error
    def initialize(api, credential_origin, request_origin)
      super("api '#{api}': the credential is bound to #{credential_origin.inspect} but the request goes to " \
            "#{request_origin.inspect}. Set the credential at the level that changes the destination, " \
            'or set it to nil to send none')
    end
  end

  class ApiNameClashError < Error
    def initialize(object, endpoint_name)
      message = "#{object.class} already defines a method called '#{endpoint_name}'. Tip: change api name"
      super(message)
    end
  end

  class PathParamsMismatch < Error
    def initialize(path, expected_params, provided_params)
      if expected_params.size == 0
        message = "route '#{path}' requires NO PARAMS but #{provided_params} were provided"
      else
        message = "route '#{path}' requires params #{expected_params} but #{provided_params} were provided"
      end
      super(message)
    end
  end

  class ResponseCodeNotAsExpected < Error

    attr_reader :path, :expected_code, :response

    def initialize(path, expected_code = nil, response = nil, message: nil)
      @path = path
      @expected_code = expected_code
      @response = response
      unless message
        message = "response code for request on route '#{@path}' has returned '#{@response.code}', but '#{@expected_code}' was expected"
      end
      super(message)
    end
  end

  class ApiConfigIsNotAnHash < Error
    def initialize(endpoint)
      message = "provided config for endpoint '#{endpoint}' must be an Hash"
      super(message)
    end
  end

  class RouteNameClashWithExistentMethod < Error
    def initialize(endpoint_name, route_name)
      message = "can't define route '#{route_name}' method in endpoint '#{endpoint_name}' because method '#{route_name}' has already been defined"
      super(message)
    end
  end

  class NoRouteExists < Error
    def initialize(endpoint_name)
      message = "no route defined on #{endpoint_name}"
      super(message)
    end
  end
end
