# frozen_string_literal: true

module ApiRecipes
  module Core
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
          compile_all({ name => config }).values.first
        end

        # given: the variable values of configure ({ api_name => { name => value } });
        # a name that its api does not declare is reported with the other problems.
        def compile_all(configs, given = nil)
          compiler = new
          apis = compiler.compile_all(configs)
          compiler.check_given_variables(apis, given)
          compiler.finish!
          apis
        end

        # The problems of the names in values (Symbol keys, as the compiler
        # resolves them) that definition does not declare. where is the
        # location of the api, or empty.
        def unknown_variables(values, definition, where = '')
          return [] if values.nil? || values.empty?

          declared = definition.variables.keys.sort
          shown = declared.empty? ? 'none declared' : "declared: #{declared.join(', ')}"
          prefix = where.empty? ? 'variables' : "#{where}.variables"
          values.keys.reject { |name| definition.variables.key?(name) }.map do |name|
            "#{prefix}: unknown variable '#{name}' (#{shown})"
          end
        end

        # scope: :api, :with_api or :with_endpoint. Returns the problems, never raises.
        def check_options(options, scope)
          raise ArgumentError, "unknown scope '#{scope}'" unless %i[api with_api with_endpoint].include?(scope)

          compiler = new
          compiler.check(options, scope)
          compiler.errors
        end

        # The validated options of a `with`, in the form the tree stores them.
        def resolve_options(options, scope)
          raise ArgumentError, "unknown scope '#{scope}'" unless %i[with_api with_endpoint].include?(scope)

          compiler = new
          resolved = compiler.resolve(options, scope)
          compiler.finish!
          resolved
        end

        def normalize(value, kind = :options)
          compiler = new
          normalized = compiler.normalize(value, '', kind)
          compiler.finish!
          normalized
        end

        def deep_merge(base, override)
          merge(normalize(base), normalize(override))
        end

        # A deep copy whose Hashes, Arrays and Strings are frozen: input kept
        # for a later compilation cannot be changed by the caller.
        def frozen_copy(value) = new.frozen_copy(value)

        private

        def merge(base, override)
          merged = base.dup
          override.each do |key, value|
            next if value.nil?

            merged[key] = if IGNORED_KEY.match?(key.to_s) || !(value.is_a?(Hash) && merged[key].is_a?(Hash))
                            value
                          else
                            merge(merged[key], value)
                          end
          end
          merged
        end
      end

      attr_reader :errors

      def initialize
        @errors = []
      end

      def compile_all(configs)
        return {}.freeze if configs.nil?

        unless configs.is_a?(Hash)
          add('apis', 'must be a Hash')
          return {}
        end
        normalize(configs, '', :options_map).each_with_object({}) do |(name, config), out|
          api = compile_one(name, config)
          out[name] = api if api
        end.freeze
      end

      def check(options, scope)
        unless options.is_a?(Hash)
          add('', 'options must be a Hash')
          return
        end
        options = normalize(options, '')
        scope == :api ? api_attrs(nil, options, '') : validate_with(options, scope)
      end

      def resolve(options, scope)
        unless options.is_a?(Hash)
          add('', 'options must be a Hash')
          return {}
        end
        validate_with(normalize(options, ''), scope)
      end

      # A copy with Symbol keys at every level. Strings are checked for their
      # encoding; two keys that become the same Symbol are reported.
      #
      # kind is :options for a Hash of options (the value of an x- key is left
      # alone), :options_map for a Hash of names to options, :free otherwise.
      def normalize(value, location, kind = :options)
        case value
        when Hash, Array then guard_cycle(value, location) { normalize_container(value, location, kind) }
        when String then clean_string(value, location)
        else value
        end
      end

      # The unknown names in given, which can still be raw: what is not a Hash
      # is left to the caller, which reports it.
      def check_given_variables(apis, given)
        return unless given.is_a?(Hash)

        normalize(given, 'variables', :free).each do |name, values|
          definition = apis[name]
          next unless definition && values.is_a?(Hash)

          @errors.concat(self.class.unknown_variables(values, definition, name.to_s))
        end
      end

      def finish!
        raise ConfigurationError.new(@errors) unless @errors.empty?
      end

      def frozen_copy(value) = deep_freeze(value)

      private

      def guard_cycle(value, location)
        @visiting ||= []
        if @visiting.any? { |other| other.equal?(value) }
          add(location, 'must not contain itself')
          return value.is_a?(Hash) ? {} : []
        end
        @visiting.push(value)
        begin
          yield
        ensure
          @visiting.pop
        end
      end

      def normalize_container(value, location, kind)
        return value.map { |item| normalize(item, location, :free) } if value.is_a?(Array)

        normalize_hash(value, location, kind)
      end

      def normalize_hash(hash, location, kind)
        seen = {}
        hash.each_with_object({}) do |(key, item), out|
          unless key.is_a?(String) || key.is_a?(Symbol)
            add(location, 'name must be a String or a Symbol')
            next
          end
          text = key.is_a?(String) ? clean_string(key, location) : key.to_s
          next if text.nil?

          name = text.to_sym
          if seen.key?(name)
            kinds = seen[name] == key.class ? "two #{key.class}s" : 'a String and as a Symbol'
            add(location, "option #{shown(name)} is given twice (as #{kinds})")
            next
          end
          seen[name] = key.class
          out[name] = normalize_item(name, item, location, kind)
        end
      end

      def normalize_item(name, item, location, kind)
        return item if kind == :options && IGNORED_KEY.match?(name.to_s)

        child = kind == :options_map ? :options : :free
        child = :options_map if kind == :options && name == :endpoints
        normalize(item, join(location, name), child)
      end

      def clean_string(string, location)
        text = [Encoding::UTF_8, Encoding::US_ASCII].include?(string.encoding) ? string : string.encode(Encoding::UTF_8)
        return text if text.valid_encoding?

        add(location, 'must be valid UTF-8')
        nil
      rescue EncodingError
        add(location, 'must be valid UTF-8')
        nil
      end

      def compile_one(name, config)
        config = {} if config.nil?
        return nil unless valid_name?(name, '', 'an api')

        unless config.is_a?(Hash)
          add(label(name), 'must be a Hash')
          return nil
        end
        attrs = api_attrs(name, config, label(name))
        build_api(name, attrs) if @errors.empty?
      end

      def valid_name?(name, location, what)
        text = name.to_s
        if text.empty?
          add(location, "#{what} name must not be empty")
        elsif CONTROL.match?(text)
          add(location, "#{what} name #{shown(name)} must not contain control characters")
        else
          return true
        end
        false
      end

      def add(location, message)
        @errors << (location.empty? ? message : "#{location}: #{message}")
      end

      def label(value)
        value.to_s.gsub(/[^[:print:]]/, '?')[0, 40]
      end

      def join(location, key)
        location.empty? ? label(key) : "#{location}.#{label(key)}"
      end

      def shown(value)
        "'#{label(value)}'"
      end

      def check_keys(hash, allowed, location)
        hash.each_key do |key|
          next if IGNORED_KEY.match?(key.to_s)

          add(location, "unknown option #{shown(key)}") unless allowed.include?(key)
        end
      end

      # ---- api ----

      def api_attrs(_name, config, location)
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
        allowed = SCOPE_KEYS.fetch(scope)
        check_keys(options, allowed, '')
        options.each_with_object({}) do |(key, value), out|
          next unless allowed.include?(key)

          resolved = %i[authorization basic_auth].include?(key) ? deep_freeze(value) : option(key, options, '', scope, nil)
          out[key] = resolved unless resolved.nil?
        end.freeze
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
          next unless valid_name?(name, location, 'an endpoint')

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
        repeated = e.message[/\Aplaceholder '(.*?)' is repeated/m, 1]
        problem = repeated ? "placeholder #{shown(repeated)} is repeated" : 'is not a valid path'
        add(location, written ? problem : "the endpoint name makes an invalid path: #{problem}")
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
        return text.dup.freeze if text && allowed.include?(text)

        add(where, "#{shown(value)} is not one of #{allowed.join(', ')}")
        nil
      end

      def positive_integer(value, where)
        return value if value.is_a?(Integer) && value.between?(1, 65_535)

        add(where, 'must be an integer from 1 to 65535')
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
        fixed = string.gsub(Template::VARIABLE, '')
        problem = nil
        if string.empty?
          problem = 'must not be empty'
        elsif !HOST_FIXED.match?(fixed)
          problem = "must be a plain host name (letters, digits, '-', '_' and '.'): no scheme, path, port, user, space or other characters"
        elsif fixed == string && (!string.match?(/[A-Za-z0-9]/) || string.include?('..'))
          problem = "must contain a letter or a digit and must not contain '..'"
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
        placeholder = false
        encoded = string.split(VARIABLE_TOKEN).map do |piece|
          next piece if VARIABLE_TOKEN.match?(piece)

          begin
            template = PathTemplate.parse(piece)
            placeholder ||= !template.param_names.empty?
            template.to_s
          rescue ArgumentError
            placeholder = true
            piece
          end
        end.join
        if placeholder
          add(where, 'path placeholders are not allowed here; declare a variable and write {name}')
          return nil
        end
        encoded.freeze
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
        end.freeze
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
        deep_freeze(value)
      end

      def recipe(value, where)
        return deep_freeze(value) if value.is_a?(Hash)

        add(where, 'must be a Hash')
        nil
      end

      # memo maps what is being copied to its copy, so that the content of an x-
      # option, which is not inspected, can hold a structure that contains itself.
      def deep_freeze(value, memo = {}.compare_by_identity)
        case value
        when Hash
          return memo[value] if memo.key?(value)

          copy = memo[value] = {}
          value.each { |key, item| copy[key] = deep_freeze(item, memo) }
          copy.freeze
        when Array
          return memo[value] if memo.key?(value)

          copy = memo[value] = []
          value.each { |item| copy << deep_freeze(item, memo) }
          copy.freeze
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
end
