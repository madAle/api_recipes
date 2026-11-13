module ApiRecipes
  # Who uses which api: the compiled tree, the owner whose levels hold
  # credentials and variables, and the options given to with. Immutable: with
  # returns a new context. Values are read when a request is built, never cached.
  class Context
    # Levels by distance from the request: the smaller, the nearer.
    RANKS = { with: 0, instance: 1, class: 2, global: 3 }.freeze
    DEFAULT_PORTS = { 'http' => 80, 'https' => 443 }.freeze

    attr_reader :definition, :owner, :global_definition, :overrides, :handles

    def initialize(definition:, owner:, global_definition: nil, overrides: nil, handles: nil)
      @definition = definition
      @owner = owner
      @global_definition = global_definition
      @overrides = (overrides || {}).freeze
      @handles = handles
      freeze
    end

    # A new context with these options on top of the current ones, as the
    # compiler resolved them. default_headers and variables add up, the other
    # options replace. A key given with nil: no credential for authorization
    # and basic_auth, no override for the others.
    def with(options)
      resolved = Compiler.resolve_options(options, :with_api)
      merged = @overrides.dup
      options.each_key do |key|
        name = key.to_sym
        merge_option(merged, name, resolved[name]) if Compiler::WITH_API_KEYS.include?(name)
      end
      self.class.new(definition: @definition, owner: @owner, global_definition: @global_definition,
                     overrides: merged, handles: @handles)
    end

    # The value of an option, from the nearest place that has one.
    def setting(key, endpoint = nil, endpoint_overrides = nil)
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
    def variables(up_to: :with)
      chain = levels
      sum_variables(definition_for(up_to), chain, start_of(chain, up_to), up_to == :with)
    end

    # "scheme://host" or "scheme://host:port". Only :with applies the protocol,
    # host and port given to with. nil when a variable is missing or there is
    # no global definition, except for :with, which raises MissingVariable.
    def origin(up_to: :with)
      chain = levels
      origin_from(definition_for(up_to), chain, start_of(chain, up_to), with: up_to == :with)
    end

    def base_path
      text = @overrides[:base_url]
      template = text ? Template.new(text, :base_url) : @definition.base_url_template
      return '/' unless template

      "/#{template.expand(variables, api: @definition.name)}".squeeze('/')
    end

    # The default headers with their variables filled, then the ones given to with.
    def headers
      values = variables
      templates = @definition.header_templates
      added = @overrides[:default_headers] || {}
      templates = templates.merge(added.transform_values { |text| Template.new(text, :header) }) unless added.empty?
      templates.transform_values { |template| template.expand(values, api: @definition.name) }
    end

    # The nearest credential: the one given to with, then the levels from the
    # instance to the global api. An explicit "none" ends the search with nil.
    # A credential taken from a level is bound to the origin of that level: if
    # destination (the origin of the request, by default) is another one, it
    # raises CredentialOriginMismatch.
    def credential(destination = nil)
      given = @overrides[:credential]
      return (given.none? ? nil : given) if given

      chain = levels
      chain.each_with_index do |(_kind, level), index|
        found = level.credential
        next if found.nil?
        return nil if found.none?

        check_origin(chain, index, destination || origin)
        return found
      end
      nil
    end

    def inspect = "#<#{self.class.name} #{@definition.name}>"

    def to_s = inspect

    def pretty_print(queue) = queue.text(inspect)

    private

    def levels = Levels.chain(@owner, @definition.name)

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
      protocol = (with && @overrides[:protocol]) || api.protocol
      port = (with && @overrides[:port]) || api.port
      port = nil if port == DEFAULT_PORTS[protocol]
      "#{protocol}://#{host.expand(values, api: api.name)}#{":#{port}" if port}"
    rescue MissingVariable
      raise if with

      nil
    end

    # The origin of a credential comes from its own level and the farther ones,
    # by position: a nearer level that moves the destination does not move it.
    # The global level uses the global definition, the others the owner's one.
    # This relies on one declaration of an api name per class hierarchy, so
    # that every class level of the chain reads the owner's tree.
    def check_origin(chain, index, destination)
      bound = origin_from(definition_for(chain[index].first), chain, index, with: false)
      return if bound && destination && bound.casecmp?(destination)

      raise CredentialOriginMismatch.new(@definition.name, bound, destination)
    end

    # value is the one resolved by the compiler, nil when the key was given as nil.
    def merge_option(merged, key, value)
      if %i[authorization basic_auth].include?(key)
        merged[:credential] = Credential.from(key, value)
      elsif value.nil?
        merged.delete(key)
      elsif %i[default_headers variables].include?(key)
        merged[key] = (merged[key] || {}).merge(value).freeze
      else
        merged[key] = value
      end
    end
  end
end
