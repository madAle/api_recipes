# frozen_string_literal: true

module ApiRecipes
  module Internals
    # Turns configuration Hashes into trees of Definition::Api and
    # Definition::Endpoint. Every rule of the configuration is checked here, once;
    # all the problems found are reported together in one ConfigurationError.
    class Compiler
      API_KEYS = %i[protocol host port base_url timeout on_bad_code mime_type verify_with default_headers
                    default_params endpoints auth variables recipe].freeze
      WITH_API_KEYS = %i[protocol host port base_url timeout on_bad_code mime_type verify_with default_headers
                         default_params variables authorization basic_auth].freeze
      ENDPOINT_KEYS = %i[path verb route ok_code timeout on_bad_code mime_type verify_with default_headers
                         default_params resource endpoints].freeze
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

      # The endpoints that `resource` adds under an endpoint, which is itself
      # the list: the names the importer gives to the same operations.
      RESOURCE = {
        show: { path: '/:id' }.freeze,
        create: { path: '', verb: :post }.freeze,
        update: { path: '/:id', verb: :patch }.freeze,
        replace: { path: '/:id', verb: :put }.freeze,
        delete: { path: '/:id', verb: :delete }.freeze
      }.freeze

      # What the endpoints of one api are checked against. variables: the
      # names a path, a header or a parameter may use, nil when they are not
      # known. credential_param: the query parameter that carries the
      # credential, which default_params cannot set.
      Names = Data.define(:variables, :credential_param)

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
        # variables, for :api only: the names that the options may use beside
        # those they declare; :any when they are not known yet.
        # credential_param, for :api only: the query parameter that carries
        # the credential of the api the options are merged with, which they
        # cannot set unless they give an auth of their own.
        def check_options(options, scope, variables: [], credential_param: nil)
          raise ArgumentError, "unknown scope '#{scope}'" unless %i[api with_api with_endpoint].include?(scope)

          compiler = new
          compiler.check(options, scope, variables, credential_param)
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

        # The names of the endpoints that a value of `resource` adds, in the
        # order of RESOURCE; nil when the value is not valid.
        def resource_names(value)
          case value
          when nil, false, 'no' then []
          when true, 'yes' then RESOURCE.keys
          when Array
            names = value.map { |name| name.is_a?(String) || name.is_a?(Symbol) ? name.to_sym : nil }
            return nil if names.empty? || !names.all? { |name| RESOURCE.key?(name) }

            RESOURCE.keys & names
          end
        end

        private

        # A nil option keeps what the base has. Among endpoints a nil value
        # for a name that the base does not have is kept: it is an endpoint
        # given without options.
        def merge(base, override, endpoints = false)
          merged = base.dup
          override.each do |key, value|
            next if value.nil? && (!endpoints || merged.key?(key))

            merged[key] = if IGNORED_KEY.match?(key.to_s) || !(value.is_a?(Hash) && merged[key].is_a?(Hash))
                            value
                          elsif key == :default_headers && !endpoints
                            merge_headers(merged[key], value)
                          else
                            merge(merged[key], value, !endpoints && key == :endpoints)
                          end
          end
          merged
        end

        # A header of override takes the place of the one of base with its
        # name, however it is written.
        def merge_headers(base, override)
          names = override.each_key.to_h { |name| [Definition.header_key(name), true] }
          base.reject { |name, _| names.key?(Definition.header_key(name)) }.merge(override)
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

      def check(options, scope, variables = [], credential_param = nil)
        unless options.is_a?(Hash)
          add('', 'options must be a Hash')
          return
        end
        options = normalize(options, '')
        scope == :api ? api_attrs(nil, options, '', variables, credential_param) : validate_with(options, scope)
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

      # known: names of variables declared elsewhere, or :any to accept every name.
      # credential_param: the one of the api these options are merged with,
      # used when they give no auth.
      def api_attrs(_name, config, location, known = [], credential_param = nil)
        check_keys(config, API_KEYS, location)
        @option_uses = nil
        variables = config[:variables].is_a?(Hash) ? config[:variables] : {}
        declared = known == :any ? nil : variables.keys + known
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
        credential_param = credential_param(attrs[:auth]) unless config[:auth].nil?
        names = Names.new(variables: declared, credential_param: credential_param)
        attrs[:default_params] = option(:default_params, config, location, :api, names)
        attrs[:variables] = option(:variables, config, location, :api, declared)
        attrs[:recipe] = option(:recipe, config, location, :api, declared)
        attrs[:endpoints] = endpoints_attrs(config[:endpoints], join(location, :endpoints), names)
        check_option_defaults(attrs[:variables], location)
        attrs
      end

      def credential_param(auth)
        auth && auth[:type] == :query ? auth[:name] : nil
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

      def endpoints_attrs(value, location, names)
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
          out[name.to_sym] = endpoint_attrs(name.to_sym, options, node_location, names)
        end
      end

      def endpoint_attrs(name, options, location, names)
        check_keys(options, ENDPOINT_KEYS, location)
        declared = names.variables
        own = {}
        (ENDPOINT_KEYS - %i[endpoints resource]).each do |key|
          value = option(key, options, location, :endpoint, key == :default_params ? names : declared)
          own[key] = value unless value.nil?
        end
        children = with_resource(options[:resource], options[:endpoints], join(location, :resource))
        path = own[:path] || name.to_s
        template = parse_path(path, join(location, :path), options.key?(:path) && !options[:path].nil?)
        unless declared.nil?
          (template.variable_names - declared).each { |variable| add(join(location, :path), "unknown variable #{shown(variable)}") }
        end
        { own: own, template: template,
          children: endpoints_attrs(children, join(location, :endpoints), names) }
      end

      # The endpoints written under an endpoint, with those its `resource`
      # adds before them. An endpoint written with the name of a generated
      # one completes it: its options win, a nil one keeps the generated value.
      def with_resource(value, written, where)
        added = self.class.resource_names(value)
        if added.nil?
          add(where, "must be true, false or a list of: #{RESOURCE.keys.join(', ')}")
          return written
        end
        return written if added.empty? || !(written.nil? || written.is_a?(Hash))

        written ||= {}
        generated = added.to_h do |name|
          given = written[name]
          given = RESOURCE[name].merge(given) { |_key, usual, own| own.nil? ? usual : own } if given.is_a?(Hash)
          [name, given.nil? ? RESOURCE[name] : given]
        end
        generated.merge(written.reject { |name, _| generated.key?(name) })
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
        return option_with_variables(key, value, where, declared) if OptionValue.variable?(key, value)

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
        when :default_params then params(value, where, declared)
        when :auth then auth(value, where)
        when :variables then scope == :with_api ? variable_values(value, where) : variable_declarations(value, where)
        when :recipe then recipe(value, where)
        when :path then path(value, where)
        when :verb then verb(value, where)
        when :route then route(value, where)
        when :ok_code then ok_code(value, where)
        end
      end

      # An option of a request written with {variables}: kept as it is
      # written, and made when the request is built.
      def option_with_variables(key, value, where, declared)
        check_variables(value, where, declared)
        (@option_uses ||= []) << [key, value]
        value.dup.freeze
      end

      # The default of a variable that gives the whole value of an option must
      # be a value of that option.
      def check_option_defaults(variables, location)
        uses = @option_uses || []
        @option_uses = nil
        return unless variables

        uses.uniq.each do |key, value|
          name = OptionValue.whole(value)
          default = name && variables[name] && variables[name][:default]
          next if default.nil? || !OptionValue.typed(key, default).nil?

          add(join(join(join(location, :variables), name), :default), "is used as #{OptionValue::USED_AS.fetch(key)}")
        end
      end

      def one_of(value, allowed, where)
        text = value.is_a?(String) || value.is_a?(Symbol) ? value.to_s : nil
        return text.dup.freeze if text && allowed.include?(text)

        add(where, "#{shown(value)} is not one of #{allowed.join(', ')}")
        nil
      end

      # A String of digits is read as its number, as 2.x did.
      def positive_integer(value, where)
        value = value.to_i if value.is_a?(String) && value.match?(/\A[0-9]{1,5}\z/)
        return value if value.is_a?(Integer) && value.between?(1, 65_535)

        add(where, 'must be an integer from 1 to 65535')
        nil
      end

      def positive_number(value, where)
        return value if (value.is_a?(Integer) || value.is_a?(Rational) || (value.is_a?(Float) && value.finite?)) && value.positive?

        add(where, 'must be a positive number')
        nil
      end

      # A Symbol stays a Symbol: http.rb reads it as one of its aliases (:json).
      def mime_type(value, where)
        text = value.is_a?(String) || value.is_a?(Symbol) ? value.to_s : nil
        if text && !text.empty? && !CONTROL.match?(text)
          return value.is_a?(Symbol) ? value : text.dup.freeze
        end

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
        # Read as a path: the same fixed text, {variables} and \{ of the
        # path of an endpoint, without its placeholders.
        template = begin
          PathTemplate.parse(value.to_s)
        rescue ArgumentError
          nil
        end
        if template.nil? || !template.param_names.empty?
          add(where, 'path placeholders are not allowed here; declare a variable and write {name}')
          return nil
        end
        unless declared.nil?
          (template.variable_names - declared).each { |name| add(where, "unknown variable #{shown(name)}") }
        end
        template.to_s.freeze
      end

      def headers(value, where, declared)
        unless value.is_a?(Hash)
          add(where, 'must be a Hash')
          return nil
        end
        seen = {}
        value.each_with_object({}) do |(name, header), out|
          name = name.to_s
          header_where = join(where, name)
          add(header_where, 'is not a valid header name') unless TOKEN.match?(name)
          first = seen[Definition.header_key(name)] ||= name
          unless first.equal?(name)
            add(header_where, "is given twice, as #{shown(first)} and as #{shown(name)}: the name of a header has " \
                              'no case, and _ is read as -')
          end
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

      # The query parameters sent with every request, as { name => text }.
      # names: a Names, or nil in a with, where nothing is known.
      def params(value, where, names)
        unless value.is_a?(Hash)
          add(where, 'must be a Hash')
          return nil
        end
        value.each_with_object({}) do |(name, param), out|
          name = name.to_s
          if name.empty?
            add(where, 'a parameter name must not be empty')
            next
          end
          param_where = join(where, name)
          add(param_where, 'the name must not contain control characters') if CONTROL.match?(name)
          if names && name == names.credential_param
            add(param_where, 'is the parameter of the credential (auth.name): it cannot be set here')
          end
          unless param.is_a?(String) || param.is_a?(Symbol) || param.is_a?(Numeric) || param == true || param == false
            add(param_where, 'must be a string, a number or a boolean')
            next
          end
          text = param.to_s
          check_variables(text, param_where, names&.variables)
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
        # Kept as text: an object that changes later would move the host after
        # the values were given.
        value.to_h { |name, item| [name, variable_text(item, join(where, name))] }.freeze
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
        params = attrs[:default_params] || {}
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
          default_params: params.freeze,
          auth: attrs[:auth],
          variables: (attrs[:variables] || {}).freeze,
          recipe: attrs[:recipe],
          host_template: Template.new(host, :host),
          base_url_template: base_url && Template.new(base_url, :base_url),
          header_templates: headers.transform_values { |text| Template.new(text, :header) }.freeze,
          param_templates: params.transform_values { |text| Template.new(text, :param) }.freeze,
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
