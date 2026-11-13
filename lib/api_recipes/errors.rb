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
    # A name that is not printable text in a known encoding is shown with inspect.
    def initialize(parent, name, available)
      shown = name.to_s if name.is_a?(String) || name.is_a?(Symbol)
      unless shown && [Encoding::UTF_8, Encoding::US_ASCII].include?(shown.encoding) && shown.valid_encoding? &&
             !shown.match?(/[[:cntrl:]]/)
        shown = name.inspect
      end
      super("'#{parent}' has no endpoint '#{shown}'. Available: #{available.join(', ')}")
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
      if credential_origin
        super("api '#{api}': the credential is bound to #{credential_origin.inspect} but the request goes to " \
              "#{request_origin.inspect}. Set the credential at the level that changes the destination, " \
              'or set it to nil to send none')
      else
        super("api '#{api}': the origin of the credential cannot be determined at the level that holds it " \
              '(for example, a variable of the host has no value there), so it is not sent to ' \
              "#{request_origin.inspect}. Set the credential at the level that sets the destination, " \
              'or give the level that holds it the values its host needs')
      end
    end
  end

  class ApiNameClashError < Error
    # declared_in: the class or module of the hierarchy that already declares the api.
    def initialize(owner, name, declared_in = nil)
      if owner.is_a?(Module) && owner.singleton_class?
        super("api '#{name}' cannot be declared on a singleton class: declare it in a module and extend the " \
              'object with it')
      elsif declared_in
        super("api '#{name}' is already declared by #{declared_in}: an api can be declared once per class " \
              'hierarchy. Use with(...) for other options')
      else
        super("#{owner} already has a method called '#{name}'. Give the api another method name with as:")
      end
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

  class NoRouteExists < Error
    def initialize(endpoint_name)
      message = "no route defined on #{endpoint_name}"
      super(message)
    end
  end
end
