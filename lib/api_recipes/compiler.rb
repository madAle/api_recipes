module ApiRecipes
  # Turns configuration Hashes into trees of Definition::Api and
  # Definition::Endpoint. Every rule of the configuration is checked here, once;
  # all the problems found are reported together in one ConfigurationError.
  class Compiler
    API_KEYS = %i[protocol host port base_url timeout on_bad_code mime_type verify_with default_headers
                  endpoints auth variables recipe].freeze
    WITH_API_KEYS = %i[protocol host port base_url timeout on_bad_code mime_type verify_with default_headers
                       variables authorization basic_auth].freeze
    ENDPOINT_KEYS = %i[path verb route ok_code timeout on_bad_code mime_type verify_with endpoints].freeze
    WITH_ENDPOINT_KEYS = %i[timeout on_bad_code ok_code mime_type verify_with].freeze
    SCOPE_KEYS = { api: API_KEYS, with_api: WITH_API_KEYS, endpoint: ENDPOINT_KEYS,
                   with_endpoint: WITH_ENDPOINT_KEYS }.freeze

    PROTOCOLS = %w[http https].freeze
    ON_BAD_CODE = %w[raise ignore].freeze
    AUTH_TYPES = %w[none bearer basic header query].freeze
    TOKEN = /\A[A-Za-z0-9!#$%&'*+.^_|~-]+\z/
    METHOD_NAME = /\A[A-Za-z_]\w*[?!]?\z/
    VARIABLE_NAME = /\A[A-Za-z_]\w*\z/
    HOST_FIXED = /\A[A-Za-z0-9._-]*\z/
    VARIABLE_TOKEN = /(\{[A-Za-z_]\w*\})/
    CONTROL = /[\x00-\x1F\x7F]/
    IGNORED_KEY = /\Ax[-_]/

    class << self
      def compile(name, config)
        compiler = new
        api = compiler.compile(name, config)
        compiler.finish!
        api
      end

      def compile_all(configs)
        compiler = new
        apis = (configs || {}).each_with_object({}) do |(name, config), out|
          out[name.to_sym] = compiler.compile(name, config)
        end
        compiler.finish!
        apis.freeze
      end

      # scope: :api, :with_api or :with_endpoint. Never raises.
      def check_options(options, scope)
        raise ArgumentError, "unknown scope '#{scope}'" unless %i[api with_api with_endpoint].include?(scope)

        compiler = new
        compiler.check(options, scope)
        compiler.errors
      end

      def normalize(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, item), out| out[key.respond_to?(:to_sym) ? key.to_sym : key] = normalize(item) }
        when Array then value.map { |item| normalize(item) }
        else value
        end
      end

      def deep_merge(base, override)
        merged = normalize(base)
        normalize(override).each do |key, value|
          next if value.nil?

          merged[key] = value.is_a?(Hash) && merged[key].is_a?(Hash) ? deep_merge(merged[key], value) : value
        end
        merged
      end
    end

    attr_reader :errors

    def initialize
      @errors = []
    end

    # Validates one api and returns its definition, or nil when it has problems.
    def compile(name, config)
      name = name.to_sym
      config = {} if config.nil?
      unless config.is_a?(Hash)
        add(name.to_s, 'must be a Hash')
        return nil
      end
      attrs = api_attrs(name, self.class.normalize(config))
      build_api(name, attrs) if attrs && @errors.empty?
    end

    # Used by check_options: validates without building.
    def check(options, scope)
      unless options.is_a?(Hash)
        add('', 'options must be a Hash')
        return
      end
      options = self.class.normalize(options)
      case scope
      when :api then api_attrs(nil, options, '')
      else validate_with(options, scope)
      end
    end

    def finish!
      raise ConfigurationError.new(@errors) unless @errors.empty?
    end

    private

    def add(location, message)
      @errors << (location.empty? ? message : "#{location}: #{message}")
    end

    def join(location, key)
      location.empty? ? key.to_s : "#{location}.#{key}"
    end

    def shown(value)
      "'#{value.to_s.gsub(/[^[:print:]]/, '?')[0, 40]}'"
    end

    def check_keys(hash, allowed, location)
      hash.each_key do |key|
        next if IGNORED_KEY.match?(key.to_s)

        add(location, "unknown option #{shown(key)}") unless allowed.include?(key)
      end
    end

    # ---- api ----

    def api_attrs(name, config, location = name.to_s)
      check_keys(config, API_KEYS, location)
      variables = config[:variables].is_a?(Hash) ? config[:variables] : {}
      declared = variables.keys
      attrs = {}
      attrs[:protocol] = option(:protocol, config, location, :api, declared)
      host = option(:host, config, location, :api, declared)
      attrs[:host] = host
      attrs[:port] = option(:port, config, location, :api, declared)
      attrs[:base_url] = option(:base_url, config, location, :api, declared)
      attrs[:timeout] = option(:timeout, config, location, :api, declared)
      attrs[:on_bad_code] = option(:on_bad_code, config, location, :api, declared)
      attrs[:mime_type] = option(:mime_type, config, location, :api, declared)
      attrs[:verify_with] = option(:verify_with, config, location, :api, declared)
      attrs[:default_headers] = option(:default_headers, config, location, :api, declared)
      attrs[:auth] = option(:auth, config, location, :api, declared)
      attrs[:variables] = option(:variables, config, location, :api, declared)
      attrs[:recipe] = option(:recipe, config, location, :api, declared)
      attrs[:endpoints] = endpoints_attrs(config[:endpoints], join(location, :endpoints))
      attrs
    end

    def validate_with(options, scope)
      check_keys(options, SCOPE_KEYS.fetch(scope), '')
      options.each_key do |key|
        next unless SCOPE_KEYS.fetch(scope).include?(key)
        next if %i[authorization basic_auth].include?(key)

        option(key, options, '', scope, nil)
      end
    end

    # ---- endpoints ----

    def endpoints_attrs(value, location)
      return {} if value.nil?

      unless value.is_a?(Hash)
        add(location, 'must be a Hash')
        return {}
      end
      value.each_with_object({}) do |(name, options), out|
        node_location = join(location, name)
        if name.to_s.empty?
          add(location, 'an endpoint name must not be empty')
          next
        end
        if options.nil?
          options = {}
        elsif !options.is_a?(Hash)
          add(node_location, 'must be a Hash or empty')
          next
        end
        out[name.to_sym] = endpoint_attrs(name.to_sym, options, node_location)
      end
    end

    def endpoint_attrs(name, options, location)
      check_keys(options, ENDPOINT_KEYS, location)
      own = {}
      (ENDPOINT_KEYS - %i[endpoints]).each do |key|
        value = option(key, options, location, :endpoint, nil)
        own[key] = value unless value.nil?
      end
      path = own[:path] || name.to_s
      template = parse_path(path, join(location, :path), options.key?(:path) && !options[:path].nil?)
      { own: own, template: template, children: endpoints_attrs(options[:endpoints], join(location, :endpoints)) }
    end

    def parse_path(path, location, written)
      PathTemplate.parse(path)
    rescue ArgumentError => e
      add(location, written ? e.message : "the endpoint name makes an invalid path: #{e.message}")
      PathTemplate.parse('')
    end

    # ---- options ----

    # Validates options[key] and returns its normalized value (nil when absent or invalid).
    def option(key, options, location, scope, declared)
      value = options[key]
      return nil if value.nil?

      where = join(location, key)
      case key
      when :protocol then one_of(value, PROTOCOLS, where)
      when :host then host(value, where, declared)
      when :port then positive_integer(value, where)
      when :base_url then base_url(value, where, declared)
      when :timeout then positive_number(value, where)
      when :on_bad_code then one_of(value, ON_BAD_CODE, where)
      when :mime_type then mime_type(value, where)
      when :verify_with then method_name(value, where)
      when :default_headers then headers(value, where, declared)
      when :auth then auth(value, where)
      when :variables then scope == :with_api ? variable_values(value, where) : variable_declarations(value, where)
      when :recipe then recipe(value, where)
      when :path then path(value, where)
      when :verb then verb(value, where)
      when :route then route(value, where)
      when :ok_code then ok_code(value, where)
      end
    end

    def one_of(value, allowed, where)
      text = value.is_a?(String) || value.is_a?(Symbol) ? value.to_s : nil
      return text if text && allowed.include?(text)

      add(where, "#{shown(value)} is not one of #{allowed.join(', ')}")
      nil
    end

    def positive_integer(value, where)
      return value if value.is_a?(Integer) && value.positive?

      add(where, 'must be a positive integer')
      nil
    end

    def positive_number(value, where)
      return value if (value.is_a?(Integer) || value.is_a?(Rational) || (value.is_a?(Float) && value.finite?)) && value.positive?

      add(where, 'must be a positive number')
      nil
    end

    def mime_type(value, where)
      text = value.is_a?(String) || value.is_a?(Symbol) ? value.to_s : nil
      return text.dup.freeze if text && !text.empty? && !CONTROL.match?(text)

      add(where, 'must be a string without control characters')
      nil
    end

    def method_name(value, where)
      text = value.is_a?(String) || value.is_a?(Symbol) ? value.to_s : nil
      return text.to_sym if text && METHOD_NAME.match?(text)

      add(where, 'must be a valid method name')
      nil
    end

    def check_variables(string, where, declared)
      return if declared.nil?

      names = string.scan(Template::VARIABLE).flatten.map(&:to_sym).uniq
      names.each { |name| add(where, "unknown variable #{shown(name)}") unless declared.include?(name) }
    end

    def host(value, where, declared)
      unless value.is_a?(String) || value.is_a?(Symbol)
        add(where, 'must be a string')
        return nil
      end
      string = value.to_s
      problem = nil
      if string.empty?
        problem = 'must not be empty'
      elsif !HOST_FIXED.match?(string.gsub(Template::VARIABLE, ''))
        problem = "must be a plain host name (letters, digits, '-', '_' and '.'): no scheme, path, port, user, space or other characters"
      end
      if problem
        add(where, problem)
        return nil
      end

      check_variables(string, where, declared)
      string.dup.freeze
    end

    def base_url(value, where, declared)
      unless value.is_a?(String) || value.is_a?(Symbol)
        add(where, 'must be a string')
        return nil
      end
      string = value.to_s
      check_variables(string, where, declared)
      string.split(VARIABLE_TOKEN).map do |piece|
        VARIABLE_TOKEN.match?(piece) ? piece : PathTemplate.parse(piece).to_s
      end.join.freeze
    rescue ArgumentError => e
      add(where, e.message)
      nil
    end

    def headers(value, where, declared)
      unless value.is_a?(Hash)
        add(where, 'must be a Hash')
        return nil
      end
      value.each_with_object({}) do |(name, header), out|
        name = name.to_s
        header_where = join(where, name)
        add(header_where, 'is not a valid header name') unless TOKEN.match?(name)
        unless header.is_a?(String) || header.is_a?(Symbol) || header.is_a?(Numeric)
          add(header_where, 'must be a string')
          next
        end
        text = header.to_s
        add(header_where, 'must not contain control characters') if CONTROL.match?(text.gsub(Template::VARIABLE, ''))
        check_variables(text, header_where, declared)
        out[name.dup.freeze] = text.dup.freeze
      end
    end

    def auth(value, where)
      unless value.is_a?(Hash)
        add(where, 'must be a Hash')
        return nil
      end
      check_keys(value, %i[type name], where)
      type = one_of(value[:type], AUTH_TYPES, join(where, :type)) unless value[:type].nil?
      add(join(where, :type), 'is required') if value[:type].nil?
      name = value[:name]
      if %w[header query].include?(type) && name.nil?
        add(join(where, :name), "is required when type is #{type}")
      elsif !name.nil?
        if (name.is_a?(String) || name.is_a?(Symbol)) && TOKEN.match?(name.to_s)
          name = name.to_s.dup.freeze
        else
          add(join(where, :name), 'must be made of letters, digits and the characters ! # $ % & \' * + . ^ _ | ~ -')
          name = nil
        end
      end
      return nil unless type

      { type: type.to_sym, name: name }.compact.freeze
    end

    def variable_declarations(value, where)
      unless value.is_a?(Hash)
        add(where, 'must be a Hash')
        return nil
      end
      value.each_with_object({}) do |(name, spec), out|
        spec_where = join(where, name)
        add(spec_where, 'is not a valid variable name') unless VARIABLE_NAME.match?(name.to_s)
        spec = {} if spec.nil?
        unless spec.is_a?(Hash)
          add(spec_where, 'must be a Hash or empty')
          next
        end
        check_keys(spec, %i[default description], spec_where)
        default = variable_text(spec[:default], join(spec_where, :default))
        description = variable_text(spec[:description], join(spec_where, :description), numbers: false)
        out[name.to_sym] = { default: default, description: description }.freeze
      end.freeze
    end

    def variable_text(value, where, numbers: true)
      return nil if value.nil?
      return value.to_s.dup.freeze if value.is_a?(String) || (numbers && (value.is_a?(Symbol) || value.is_a?(Numeric)))

      add(where, 'must be a string')
      nil
    end

    def variable_values(value, where)
      unless value.is_a?(Hash)
        add(where, 'must be a Hash')
        return nil
      end
      value.each_key { |name| add(join(where, name), 'is not a valid variable name') unless VARIABLE_NAME.match?(name.to_s) }
      value
    end

    def recipe(value, where)
      return deep_freeze(value) if value.is_a?(Hash)

      add(where, 'must be a Hash')
      nil
    end

    def deep_freeze(value)
      case value
      when Hash then value.each_with_object({}) { |(key, item), out| out[key] = deep_freeze(item) }.freeze
      when Array then value.map { |item| deep_freeze(item) }.freeze
      when String then value.dup.freeze
      else value
      end
    end

    def path(value, where)
      return value.dup.freeze if value.is_a?(String)

      add(where, 'must be a string')
      nil
    end

    def verb(value, where)
      text = value.is_a?(String) || value.is_a?(Symbol) ? value.to_s.downcase : nil
      return text.to_sym if text && HTTP::Request::METHODS.include?(text.to_sym)

      add(where, "#{shown(value)} is not a verb known to http.rb")
      nil
    end

    def route(value, where)
      case value
      when true, 'yes' then true
      when false, 'no' then false
      else
        add(where, "#{shown(value)} is not one of true, false, yes, no")
        nil
      end
    end

    def ok_code(value, where)
      return value if value.is_a?(Integer)
      return value.dup.freeze if value.is_a?(Array) && !value.empty? && value.all?(Integer)

      add(where, 'must be an integer or a list of integers')
      nil
    end

    # ---- build ----

    def build_api(name, attrs)
      host = attrs[:host] || 'localhost'
      base_url = attrs[:base_url]
      headers = attrs[:default_headers] || {}
      Definition::Api.new(
        name: name,
        protocol: attrs[:protocol] || 'https',
        host: host,
        port: attrs[:port],
        base_url: base_url,
        timeout: attrs[:timeout] || 3,
        on_bad_code: attrs[:on_bad_code] || 'raise',
        mime_type: attrs[:mime_type],
        verify_with: attrs[:verify_with],
        default_headers: headers.freeze,
        auth: attrs[:auth],
        variables: (attrs[:variables] || {}).freeze,
        recipe: attrs[:recipe],
        host_template: Template.new(host, :host),
        base_url_template: base_url && Template.new(base_url, :base_url),
        header_templates: headers.transform_values { |text| Template.new(text, :header) }.freeze,
        children: ->(api) { build_endpoints(attrs[:endpoints], api) }
      )
    end

    def build_endpoints(specs, parent)
      specs.each_with_object({}) do |(name, spec), out|
        out[name] = Definition::Endpoint.new(
          name: name, parent: parent, own: spec[:own], template: spec[:template],
          children: ->(node) { build_endpoints(spec[:children], node) }
        )
      end
    end
  end
end
