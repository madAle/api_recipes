module ApiRecipes
  # One request to one endpoint: builds the URL and the http.rb client, sends
  # the request and checks the outcome.
  class Request
    ORIGIN = %r{\A(https?)://([^:/]+)(?::(\d+))?\z}
    DEFAULT_EXPECTED = '200 <= CODE < 300'.freeze
    FOLLOW_PROBLEM = 'follow: must be true, false or a Hash'.freeze
    FOLLOW_OPTIONS = %i[strict max_hops on_redirect].freeze

    def initialize(context:, definition:, path:, options:, overrides: nil)
      @context = context
      @definition = definition
      @path = path
      @options = symbol_keys(options || {})
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

      check_follow
      origin = @context.origin
      credential = @context.credential(origin)
      address = checked(url, origin)
      http_response = client(credential).request(@definition.verb, address, **send_options(credential, origin))
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
    # http.rb hands to Addressable, an optional gem, what Ruby's URI cannot
    # parse, and its failures there are not ours to predict. So the address is
    # first read with Ruby's URI alone: anything that is not ASCII or that Ruby
    # refuses is refused, and http.rb then never reaches Addressable.
    def checked(url, origin)
      address = url.to_s
      scheme, host, port = parts(origin)
      raise InvalidUrl, "the url of api '#{@context.definition.name}' cannot be parsed" unless plain_uri?(address)

      stdlib = ::URI.parse(address)
      same = stdlib.scheme.to_s.casecmp?(scheme) && stdlib.host.to_s.casecmp?(host) &&
             stdlib.port == (port || Context::DEFAULT_PORTS.fetch(scheme))
      raise InvalidUrl, "the url does not point to the origin of api '#{@context.definition.name}'" unless same

      uri = HTTP::URI.parse(address)
      raise InvalidUrl, "the url does not point to the origin of api '#{@context.definition.name}'" unless same_origin?(uri, origin)

      address
    rescue HTTP::URI::InvalidError
      raise InvalidUrl, "the url of api '#{@context.definition.name}' cannot be parsed"
    end

    def plain_uri?(address)
      address.ascii_only? && ::URI.parse(address) && true
    rescue ::URI::InvalidURIError
      false
    end

    def same_origin?(uri, origin)
      scheme, host, port = parts(origin)
      port ||= Context::DEFAULT_PORTS.fetch(scheme)
      uri.scheme.to_s.casecmp?(scheme) && uri.host.to_s.casecmp?(host) &&
        uri.normalized_host.to_s.casecmp?(host) && uri.port == port
    end

    # An HTTP::Client, not the HTTP::Session the chainable methods of http.rb
    # return: along redirects a session keeps a cookie jar and sets every
    # cookie in it on each hop, after on_redirect and whatever the origin.
    def client(credential)
      HTTP::Client.new(configured(credential).default_options)
    end

    # default_headers, then the credential, then headers: of the request.
    def configured(credential)
      session = HTTP.headers(@context.headers).timeout(setting(:timeout))
      return session unless credential

      if credential.kind == :basic_auth
        if %i[header query].include?(auth[:type])
          raise InvalidCredential, "basic_auth cannot be sent with auth type '#{auth[:type]}': assign it with authorization"
        end

        return session.basic_auth(**credential.value)
      end
      case auth[:type]
      when :header then session.headers(auth[:name] => credential.value)
      when :query then session
      else session.auth(credential.value)
      end
    end

    def send_options(credential, origin)
      options = @options
      if credential && credential.kind == :authorization && auth[:type] == :query
        params = options[:params].to_a.reject { |key, _| key.to_s == auth[:name] }
        options = options.merge(params: params << [auth[:name], credential.value])
      end
      follow = options[:follow]
      options = options.merge(follow: protected_follow(follow, origin)) if follow.equal?(true) || follow.is_a?(Hash)
      options
    end

    # http.rb follows any value that responds to fetch, so only the values the
    # protection can wrap are accepted. http.rb reads the options of a Hash
    # only once the first response is in: they are checked here, before
    # anything is sent.
    def check_follow
      follow = @options[:follow]
      case follow
      when nil, true, false then nil
      when Hash then check_follow_options(symbol_keys(follow))
      else raise ConfigurationError.new([FOLLOW_PROBLEM])
      end
    end

    def check_follow_options(settings)
      unknown = settings.keys.find { |key| !FOLLOW_OPTIONS.include?(key) }
      raise ConfigurationError.new(["follow: unknown option '#{unknown.to_s.scrub('?')}'"]) if unknown

      return if !settings.key?(:max_hops) || settings[:max_hops].is_a?(Integer)

      raise ConfigurationError.new(['follow.max_hops: must be an integer'])
    end

    # true or a Hash: follows redirects, but a request that leaves the origin
    # loses Authorization, Cookie and what auth names, wherever they came from.
    # Then the on_redirect of the caller is called.
    def protected_follow(follow, origin)
      settings = follow.is_a?(Hash) ? symbol_keys(follow) : {}
      given = settings[:on_redirect]
      settings.merge(on_redirect: lambda do |response, request|
        leave_origin(request) unless same_origin?(request.uri, origin)
        given.call(response, request) if given.respond_to?(:call)
      end)
    end

    def leave_origin(request)
      name = auth[:name]
      ['Authorization', 'Cookie', name].compact.each { |header| request.headers.delete(header) }
      drop_param(request.uri, name) if auth[:type] == :query
    end

    def drop_param(uri, name)
      return if uri.query.nil?

      kept = uri.query.split('&').reject { |pair| param_named?(pair, name) }
      uri.query = kept.empty? ? nil : kept.join('&')
    end

    def param_named?(pair, name)
      key = pair.split('=', 2).first.to_s
      key == name || URI.decode_www_form_component(key) == name
    rescue ArgumentError
      false
    end

    # A plain Hash whose String keys become Symbols, read as UTF-8 like the
    # compiler reads names. A key that cannot be read is left as it is.
    def symbol_keys(hash)
      hash.each_with_object({}) { |(key, value), out| out[symbol_key(key)] = value }
    end

    def symbol_key(key)
      return key unless key.is_a?(String)

      key.encode(Encoding::UTF_8).to_sym
    rescue EncodingError
      key
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
