module ApiRecipes
  # One request to one endpoint: builds the URL and the http.rb client, sends
  # the request and checks the outcome.
  class Request
    ORIGIN = %r{\A(https?)://([^:/]+)(?::(\d+))?\z}
    DEFAULT_EXPECTED = '200 <= CODE < 300'.freeze

    def initialize(context:, definition:, path:, options:, overrides: nil)
      @context = context
      @definition = definition
      @path = path
      @options = (options || {}).transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
      @overrides = overrides
    end

    # Scheme, host, port and path. Never a query string: parameters and a
    # credential sent in the query are added only when the request is sent.
    def url
      return nil unless @definition.route?

      scheme, host, port = parts(@context.origin)
      path = @path.start_with?('/') ? @path : "/#{@path}"
      (scheme == 'https' ? URI::HTTPS : URI::HTTP).new(scheme, nil, host, port, nil, path, nil, nil, nil, nil, false)
    end

    def perform
      raise NoRouteExists.new(@definition.name) unless @definition.route?

      origin = @context.origin
      credential = @context.credential(origin)
      address = checked(url, origin)
      http_response = client(credential).request(@definition.verb, address, send_options(credential, origin))
      respond(http_response)
    end

    def inspect = "#<#{self.class.name} #{@definition.full_name}>"

    def to_s = inspect

    def pretty_print(queue) = queue.text(inspect)

    private

    def setting(key) = @context.setting(key, @definition, @overrides)

    def auth = @context.definition.auth || {}

    # [scheme, host, port] of an origin; port is nil when it is the default.
    def parts(origin)
      match = ORIGIN.match(origin)
      raise InvalidUrl, "api '#{@context.definition.name}' has an origin that is not http or https" unless match

      [match[1], match[2], match[3]&.to_i]
    end

    # The url as http.rb reads it must point to the origin that was validated.
    def checked(url, origin)
      address = url.to_s
      uri = HTTP::URI.parse(address)
      raise InvalidUrl, "the url does not point to the origin of api '#{@context.definition.name}'" unless same_origin?(uri, origin)

      address
    rescue Addressable::URI::InvalidURIError
      raise InvalidUrl, "the url of api '#{@context.definition.name}' cannot be parsed"
    end

    def same_origin?(uri, origin)
      scheme, host, port = parts(origin)
      port ||= Context::DEFAULT_PORTS.fetch(scheme)
      uri.scheme.to_s.casecmp?(scheme) && uri.host.to_s.casecmp?(host) &&
        uri.normalized_host.to_s.casecmp?(host) && uri.port == port
    end

    # default_headers, then the credential, then headers: of the request.
    def client(credential)
      client = HTTP.headers(@context.headers).timeout(setting(:timeout))
      return client unless credential

      if credential.kind == :basic_auth
        if %i[header query].include?(auth[:type])
          raise InvalidCredential, "basic_auth cannot be sent with auth type '#{auth[:type]}': assign it with authorization"
        end

        return client.basic_auth(credential.value)
      end
      case auth[:type]
      when :header then client.headers(auth[:name] => credential.value)
      when :query then client
      else client.auth(credential.value)
      end
    end

    def send_options(credential, origin)
      options = @options
      if credential && credential.kind == :authorization && auth[:type] == :query
        params = options[:params].to_a.reject { |key, _| key.to_s == auth[:name] }
        options = options.merge(params: params << [auth[:name], credential.value])
      end
      options = options.merge(follow: follow_option(origin)) if credential && options[:follow]
      options
    end

    # Follows redirects, but drops the credential and the cookies before a
    # request that leaves the origin. Then calls the on_redirect of the caller.
    def follow_option(origin)
      settings = @options[:follow].is_a?(Hash) ? @options[:follow] : {}
      given = settings[:on_redirect]
      names = ['Authorization', 'Cookie', (auth[:name] if auth[:type] == :header)].compact
      settings.merge(on_redirect: lambda do |response, request|
        names.each { |name| request.headers.delete(name) } unless same_origin?(request.uri, origin)
        given.call(response, request) if given.respond_to?(:call)
      end)
    end

    def respond(http_response)
      mime_type = setting(:mime_type)
      hidden = auth[:type] == :query ? auth[:name] : nil
      success, expected, message = outcome(http_response, mime_type, hidden)
      response = Response.new(http_response, mime_type: mime_type, success: success, hidden_param: hidden)
      if !success && setting(:on_bad_code).to_s == 'raise'
        raise ResponseCodeNotAsExpected.new(@path, expected, response, message: message)
      end

      response
    end

    # [success, expected code, message of the error]
    def outcome(http_response, mime_type, hidden)
      verify_with = setting(:verify_with)
      owner = @context.owner
      if verify_with && owner.respond_to?(verify_with, true)
        checked = Response.new(http_response, mime_type: mime_type, hidden_param: hidden)
        valid = owner.send(verify_with, checked) ? true : false
        return [valid, nil, "response for request on route '#{@path}' was not valid. Verified with #{verify_with}."]
      end

      ok_code = setting(:ok_code)
      return [http_response.status.success?, DEFAULT_EXPECTED, nil] if ok_code.nil?

      [Array(ok_code).include?(http_response.code), ok_code, nil]
    end
  end
end
