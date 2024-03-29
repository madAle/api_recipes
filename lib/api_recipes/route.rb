module ApiRecipes
  class Route

    attr_reader :request, :response, :url
    attr_accessor :request_params, :attributes, :path

    def initialize(api: nil, endpoint: nil, path: nil, attributes: {}, req_pars: {})
      @api = api
      @endpoint = endpoint
      @path = path.to_s
      @attributes = attributes
      self.request_params = req_pars
      @url = nil

      prepare_request
    end

    def fill(object)
      data = @response.parse @attributes[:mime_type]
      if block_given?
        tap do
          try_to_fill object, data
          yield object, data, @response.status
        end
      else
        try_to_fill object, data
      end
    end

    def start_request(&block)
      original_response = @request.send http_verb, @url, request_params
      @response = Response.new original_response, attributes
      check_response_code

      if block_given?
        tap { block.call @response }
      else
        response
      end
    end

    private

    def build_url_from_path
      attrs = {
          scheme: settings[:protocol].to_s,
          host: settings[:host],
          port: port,
          path: path
      }
      URI::Generic.build2 attrs
    end

    def check_response_code
      ok_code = false
      code = @response.code
      message = nil

      verify_with = attributes[:verify_with]
      if verify_with && @api.object.respond_to?(verify_with, true )
        ok_code = @api.object.send verify_with, @response
        message = "response for request on route '#{path}' was not valid. Verified with #{@api.object}##{verify_with}.\n\nResponse body:\n #{@response.body}"
      else
        # If :ok_code property is present, check the response code
        if expected_code = attributes[:ok_code]
          # If the code does not match, apply the requested strategy
          ok_code = true if code == expected_code
        else
          # Default: 200 <= OK < 300
          ok_code = true if @response.status.success?
          expected_code = '200 <= CODE < 300'
        end
      end

      unless ok_code
        case attributes[:on_bad_code].to_s
        when 'ignore'
        when 'raise'
          raise ResponseCodeNotAsExpected.new(path, expected_code, @response, message: message)
        end
      end
    end

    def extract_headers
      settings[:default_headers] || {}
    end

    def timeout
      attributes.fetch(:timeout, ApiRecipes::Settings::GLOBAL_TIMEOUT)
    end

    def port
      settings[:port].to_s || case settings[:protocol].to_s
                              when 'http'
                                '80'
                              when 'https'
                                '443'
                              end
    end

    def prepare_request
      @url = build_url_from_path
      puts @url if ApiRecipes.configuration.print_urls

      @request = request_with_auth
    end

    def request_params=(params)
      unless params.is_a? Hash
        raise ArgumentError, 'provided params must be an Hash'
      end
      # Merge route attributes with defaults and deep clone route attributes
      @request_params = params
    end

    def request_with_auth
      req = HTTP
      req = req.headers(extract_headers)
                .timeout(timeout)

      basic_auth = @api.basic_auth
      if basic_auth
        req = req.basic_auth basic_auth
      end
      authorization = @api.authorization
      if authorization
        req = req.auth authorization
      end
      req
    end

    def settings
      @api.configs
    end

    def try_to_fill(object, data)
      case data
      when Hash
        res = fill_object_with object, data
      when Array
        res = []
        data.each do |element|
          res << fill_object_with(object.new, element)
        end
      end

      res
    end

    def fill_object_with(object, data)
      data.each do |key, value|
        begin
          object.send "#{key}=", value
        rescue
        end
      end

      object
    end

    def http_verb
      attributes[:verb]
    end
  end
end
