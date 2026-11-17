# frozen_string_literal: true

module ApiRecipes
  module Internals
    # Who uses which api: the compiled tree, the owner whose levels hold
    # credentials and variables, the declaration in use (nil for a global api)
    # and the options given to with. Immutable: with returns a new context.
    # Values are read when a request is built, never cached. generation is the
    # one of the registry the tree was compiled for (nil: a context built by
    # hand, which no configure replaces).
    class Context
      # Levels by distance from the request: the smaller, the nearer.
      RANKS = { with: 0, instance: 1, class: 2, global: 3 }.freeze
      DEFAULT_PORTS = { 'http' => 80, 'https' => 443 }.freeze

      attr_reader :definition, :owner, :global_definition, :overrides, :handles, :declaration

      def initialize(definition:, owner:, global_definition: nil, overrides: nil, handles: nil, declaration: nil,
                     generation: nil)
        @definition = definition
        @owner = owner
        @global_definition = global_definition
        @overrides = (overrides || {}).freeze
        @handles = handles
        @declaration = declaration
        @generation = generation
        freeze
      end

      # A new context with these options on top of the current ones, as the
      # compiler resolved them. default_headers, default_params and variables
      # add up, the other options replace. A key given with nil: no credential for authorization
      # and basic_auth, no override for the others.
      def with(options)
        resolved = Compiler.resolve_options(options, :with_api)
        problems = Compiler.unknown_variables(resolved[:variables], @definition)
        raise ConfigurationError.new(problems) unless problems.empty?

        # The names as the compiler reads them, in the order given, nil ones included.
        names = Compiler.normalize(options.to_h { |key, _value| [key, nil] }).keys
        merged = @overrides.dup
        names.each do |name|
          merge_option(merged, name, resolved[name]) if Compiler::WITH_API_KEYS.include?(name)
        end
        self.class.new(definition: @definition, owner: @owner, global_definition: @global_definition,
                       overrides: merged, handles: @handles, declaration: @declaration, generation: @generation)
      end

      # The key of the levels of this api for its readers and writers: the
      # declaration in use, or the api name for a global api.
      def level_key = @declaration || @definition.name

      # The levels that hold a value for this api, nearest first. A request
      # reads them once and passes them as chain to the methods below.
      def levels = Levels.chain(@owner, @definition.name, @declaration)

      # The level of the owner alone, or nil.
      def own_level = Levels.own(@owner, @definition.name, @declaration)

      # The value of an option, from the nearest place that has one. An
      # option written with variables is made from those of chain.
      def setting(key, endpoint = nil, endpoint_overrides = nil, chain: nil)
        resolve(key, written(key, endpoint, endpoint_overrides), chain: chain)
      end

      # value as the option key: what is written with variables is filled
      # with those of chain and checked for the option; anything else is
      # returned as it is.
      def resolve(key, value, chain: nil)
        return value unless OptionValue.variable?(key, value)

        OptionValue.resolve(key, value, variables(chain: chain || levels), api: @definition.name)
      end

      # The verb as inspect shows it: made from the variables, or as it is
      # written when one is missing.
      def shown_verb(verb)
        OptionValue.shown_verb(resolve(:verb, verb))
      rescue Error
        OptionValue.shown_verb(verb)
      end

      # The option as it is written, from the nearest place that has one.
      def written(key, endpoint = nil, endpoint_overrides = nil)
        if endpoint
          value = endpoint_overrides && endpoint_overrides[key]
          return value unless value.nil?

          value = endpoint.own(key)
          return value unless value.nil?
        end
        value = @overrides[key]
        return value unless value.nil?

        @definition.respond_to?(key) ? @definition.public_send(key) : nil
      end

      # Declared defaults, then the levels from the farthest up to up_to. For
      # :global the defaults are those of the global definition (none without it).
      def variables(up_to: :with, chain: levels)
        sum_variables(definition_for(up_to), chain, start_of(chain, up_to), up_to == :with)
      end

      # "scheme://host" or "scheme://host:port". Only :with applies the protocol,
      # host and port given to with. nil when a variable is missing or there is
      # no global definition, except for :with, which raises MissingVariable.
      def origin(up_to: :with, chain: levels)
        origin_from(definition_for(up_to), chain, start_of(chain, up_to), with: up_to == :with)
      end

      def base_path
        text = @overrides[:base_url]
        template = text ? Template.new(text, :base_url) : @definition.base_url_template
        return '/' unless template

        "/#{template.expand(variables, api: @definition.name)}".squeeze('/')
      end

      # The default headers with their variables filled: those of the api,
      # then the ones given to with, then the ones of endpoint and of the
      # endpoints above it. A header replaces the one with its name, whatever
      # the case.
      def headers(chain: levels, endpoint: nil)
        filled(layers(:header, @definition.header_templates, @overrides[:default_headers],
                      endpoint && endpoint.header_templates), chain)
      end

      # The default query parameters with their variables filled, as
      # { name => text }, in the same order as the headers.
      def params(chain: levels, endpoint: nil)
        filled(layers(:param, @definition.param_templates, @overrides[:default_params],
                      endpoint && endpoint.param_templates), chain)
      end

      # The nearest credential: the one given to with, then the levels from the
      # instance to the global api. An explicit "none" ends the search with nil.
      # A credential taken from a level is bound to the origin of that level: if
      # destination (the origin of the request, by default) is another one, it
      # raises CredentialOriginMismatch.
      def credential(destination = nil, chain: nil)
        given = @overrides[:credential]
        return (given.none? ? nil : given) if given

        chain ||= levels
        chain.each_with_index do |(_kind, level), index|
          found = level.credential
          next if found.nil?
          return nil if found.none?

          check_origin(chain, index, destination || origin(chain: chain))
          return found
        end
        nil
      end

      # The credential a request would look at first, as assigned, without
      # checking its origin: what the readers of an api return. Nil when no
      # level has one; Credential::NONE when the nearest one is "none".
      def assigned_credential
        given = @overrides[:credential]
        return given if given

        levels.each do |_kind, level|
          return level.credential unless level.credential.nil?
        end
        nil
      end

      # The origin for inspect. It never raises: a host whose variables have
      # no valid value is shown as written.
      def shown_origin
        origin
      rescue Error
        address(@definition, @overrides[:host] || @definition.host, nil, with: true)
      end

      def inspect = "#<#{self.class.name} #{@definition.name}>"

      def to_s = inspect

      def pretty_print(queue) = queue.text(inspect)

      # The options of with can hold header values: a Context is never serialized.
      def marshal_dump = raise(TypeError, 'an ApiRecipes::Internals::Context cannot be serialized')

      def encode_with(_coder) = raise(TypeError, 'an ApiRecipes::Internals::Context cannot be serialized')

      private

      NONE = {}.freeze

      # The templates of the api, of with and of the endpoint, the later over
      # the earlier.
      def layers(position, api, given, endpoint)
        templates = api
        unless given.nil? || given.empty?
          templates = over(position, templates, given.transform_values { |text| Template.new(text, position) })
        end
        templates = over(position, templates, endpoint) unless endpoint.nil? || endpoint.empty?
        templates
      end

      def over(position, base, added)
        position == :header ? Definition.over_headers(base, added) : base.merge(added)
      end

      # The variables are read only when there is something to fill.
      def filled(templates, chain)
        return NONE if templates.empty?

        values = variables(chain: chain)
        templates.transform_values { |template| template.expand(values, api: @definition.name) }
      end

      # The tree a level reads: the global one for the global level, else the owner's.
      def definition_for(kind) = kind == :global ? @global_definition : @definition

      # Index of the first level of chain at or farther than up_to.
      def start_of(chain, up_to)
        rank = RANKS.fetch(up_to) { raise ArgumentError, "unknown level '#{up_to}'" }
        chain.index { |kind, _| RANKS.fetch(kind) >= rank } || chain.size
      end

      def sum_variables(api, chain, start, with)
        values = {}
        api&.variables&.each { |name, spec| values[name] = spec[:default] unless spec[:default].nil? }
        chain[start..].reverse_each do |_kind, level|
          level.variables&.each { |name, value| values[name.respond_to?(:to_sym) ? name.to_sym : name] = value }
        end
        values.merge!(@overrides[:variables]) if with && @overrides[:variables]
        values
      end

      # The origin of api with the variables of the levels from start to the
      # farthest; with: true also applies the options given to with.
      def origin_from(api, chain, start, with:)
        return nil unless api

        values = sum_variables(api, chain, start, with)
        host = with && @overrides[:host] ? Template.new(@overrides[:host], :host) : api.host_template
        address(api, host.expand(values, api: api.name), values, with: with)
      rescue MissingVariable
        raise if with

        nil
      end

      # "scheme://host" or "scheme://host:port", without the default port. A
      # protocol or a port written with variables is made from values, and
      # shown as it is written when values is nil.
      def address(api, host, values, with:)
        protocol = (with && @overrides[:protocol]) || api.protocol
        port = (with && @overrides[:port]) || api.port
        if values
          protocol = OptionValue.resolve(:protocol, protocol, values, api: api.name)
          port = OptionValue.resolve(:port, port, values, api: api.name)
        end
        port = nil if port == DEFAULT_PORTS[protocol]
        "#{protocol}://#{host}#{":#{port}" if port}"
      end

      # The origin of a credential comes from its own level and the farther ones,
      # by position: a nearer level that moves the destination does not move it.
      # The global level uses the global definition, the others the owner's one:
      # every other level of the chain was written through the declaration in
      # use, whose tree that is.
      def check_origin(chain, index, destination)
        registry = chain.respond_to?(:registry) ? chain.registry : Registry.current
        bound = origin_from(definition_in_force(chain[index].first, registry), chain, index, with: false)
        return if bound && destination && bound.casecmp?(destination)

        raise CredentialOriginMismatch.new(@definition.name, bound, destination)
      end

      # The tree a level reads now. An api or an endpoint kept across a
      # configure still holds the tree it was created with, and so its
      # destination, while the levels are read when the request is sent: their
      # credentials are bound to the origin that the configuration in force
      # gives them. nil when that configuration no longer has the api. registry
      # is the one the levels of the request were read from.
      def definition_in_force(kind, registry)
        return definition_for(kind) if @generation.nil? || @generation == registry.generation
        return registry.definitions[@definition.name] if kind == :global || @declaration.nil?

        @declaration.definition
      end

      # value is the one resolved by the compiler, nil when the key was given as nil.
      def merge_option(merged, key, value)
        if %i[authorization basic_auth].include?(key)
          merged[:credential] = Credential.from(key, value)
        elsif value.nil?
          merged.delete(key)
        elsif key == :default_headers
          merged[key] = Definition.over_headers(merged[key] || {}, value)
        elsif %i[default_params variables].include?(key)
          merged[key] = (merged[key] || {}).merge(value).freeze
        else
          merged[key] = value
        end
      end
    end
  end
end
