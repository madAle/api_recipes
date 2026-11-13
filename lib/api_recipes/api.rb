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

    # Sets the credential of the caller's level; nil means "send none".
    def authorization=(value)
      credential = Credential.from(:authorization, value)
      LevelSet.write(@context.owner, @context.definition.name) { |level| level.with(credential: credential) }
    end

    def basic_auth
      credential = @context.assigned_credential
      credential && credential.kind == :basic_auth ? credential.value : nil
    end

    def basic_auth=(value)
      credential = Credential.from(:basic_auth, value)
      LevelSet.write(@context.owner, @context.definition.name) { |level| level.with(credential: credential) }
    end

    # The variable values of the caller's level.
    def variables
      level = LevelSet.read(@context.owner, @context.definition.name)
      (level && level.variables) || {}
    end

    # Sets the variable values of the caller's level; nil removes them.
    def variables=(values)
      values = Registry.variable_values(values)
      LevelSet.write(@context.owner, @context.definition.name) { |level| level.with(variables: values) }
    end

    def inspect
      definition = @context.definition
      list = definition.endpoints.empty? ? '' : " endpoints: #{definition.endpoints.keys.join(', ')}"
      "#<ApiRecipes::Api #{definition.name} #{@context.shown_origin}#{list}>"
    end
  end
end
