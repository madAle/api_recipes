# frozen_string_literal: true

module ApiRecipes
  # One configured api, as ApiRecipes.github, MyClass.github and
  # client.github return it. The subclass generated for the tree adds a
  # method per root endpoint.
  #
  # Every method of this class is a name an endpoint cannot use as a method:
  # the class has only the public methods below, and inside them the only
  # private methods called are raise and block_given?.
  class Api
    def initialize(context)
      @context = context
    end

    # The root endpoint called name. With a block, sends its request at once.
    def [](name, *args, &block)
      endpoint = @context.handles.endpoint(@context, @context.definition, @context.base_path, name, args)
      endpoint.run(&block) if block
      endpoint
    end

    # A copy with options for the chain that follows it only.
    def with(options) = self.class.new(@context.with(options))

    def definition = @context.definition

    # The credential resolved along the chain; nil for the other kind.
    def authorization
      credential = @context.assigned_credential
      credential && credential.kind == :authorization ? credential.value : nil
    end

    # Sets the credential of an object; nil means "send none". Only an object
    # has writers: what the whole application or a class uses is shared by
    # every thread, so it is given where the application starts, to
    # ApiRecipes.configure (config.values) or to `api` in the class. The
    # writers also refuse an api returned by with: its options belong to its
    # chain.
    def authorization=(value)
      if Module === @context.owner || !@context.overrides.empty?
        raise Error, Internals::LevelSet.refusal(:authorization, @context.owner, @context.definition.name, @context.overrides.empty?)
      end

      credential = Internals::Credential.from(:authorization, value)
      Internals::LevelSet.write(@context.owner, @context.level_key) { |level| level.with(credential: credential) }
    end

    def basic_auth
      credential = @context.assigned_credential
      credential && credential.kind == :basic_auth ? credential.value : nil
    end

    def basic_auth=(value)
      if Module === @context.owner || !@context.overrides.empty?
        raise Error, Internals::LevelSet.refusal(:basic_auth, @context.owner, @context.definition.name, @context.overrides.empty?)
      end

      credential = Internals::Credential.from(:basic_auth, value)
      Internals::LevelSet.write(@context.owner, @context.level_key) { |level| level.with(credential: credential) }
    end

    # The variable values of the caller's level.
    def variables
      level = @context.own_level
      (level && level.variables) || {}
    end

    # Sets the variable values of an object; nil removes them. See authorization=.
    def variables=(values)
      if Module === @context.owner || !@context.overrides.empty?
        raise Error, Internals::LevelSet.refusal(:variables, @context.owner, @context.definition.name, @context.overrides.empty?)
      end

      values = Internals::Registry.variable_values(values)
      problems = Internals::Compiler.unknown_variables(values, @context.definition)
      raise ConfigurationError.new(problems) unless problems.empty?

      Internals::LevelSet.write(@context.owner, @context.level_key) { |level| level.with(variables: values) }
    end

    def inspect
      definition = @context.definition
      list = definition.endpoints.empty? ? '' : " endpoints: #{definition.endpoints.keys.join(', ')}"
      "#<ApiRecipes::Api #{definition.name} #{@context.shown_origin}#{list}>"
    end

    # An Api holds options that can contain secrets: it is never serialized.
    def marshal_dump = raise(TypeError, 'an ApiRecipes::Api cannot be serialized')

    def encode_with(_coder) = raise(TypeError, 'an ApiRecipes::Api cannot be serialized')

    def as_json(*) = raise(TypeError, 'an ApiRecipes::Api cannot be serialized')

    def to_json(*) = raise(TypeError, 'an ApiRecipes::Api cannot be serialized')
  end
end
