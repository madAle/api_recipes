# frozen_string_literal: true

module ApiRecipes
  # What configure produced: the compiled trees, their handles and one global
  # Api per tree. Immutable: configure builds a new registry and swaps it in
  # with one assignment, so a reader sees the old one or the new one, never a
  # mix. The generation grows at every swap, reset! included.
  class Registry
    LOCK = Mutex.new

    @methods = [].freeze

    class << self
      attr_reader :current

      # Loads and compiles the configuration, then swaps the registry in. If
      # anything raises before the swap, the current registry stays.
      def install(configuration)
        LOCK.synchronize do
          apis = configuration.load
          definitions = Compiler.compile_all(apis)
          handles = definitions.transform_values { |definition| Handles.new(definition) }
          variables = Compiler.normalize(configuration.variables).to_h { |name, values| [name, variable_values(values)] }
          @current = new(configs: Compiler.frozen_copy(apis), definitions: definitions, handles: handles,
                         generation: @current.generation + 1)
          warnings = define_methods(@current.apis) + handles.values.flat_map(&:warnings)
          variables.each { |name, values| LevelSet.write(ApiRecipes, name) { |level| level.with(variables: values) } }
          warnings.each { |message| configuration.logger.warn(message) }
        end
      end

      # Removes the methods generated on ApiRecipes and empties the registry.
      def reset!
        LOCK.synchronize do
          define_methods([])
          @current = new(generation: @current.generation + 1)
        end
      end

      # Variable values as a level stores them: a frozen copy with Symbol keys,
      # or nil. Anything else than a Hash or nil raises ConfigurationError.
      def variable_values(values)
        Compiler.resolve_options({ variables: values }, :with_api)[:variables]
      end

      private

      # One method on ApiRecipes per api, unless the name is taken by another
      # method of the module. Returns the warnings.
      def define_methods(names)
        warnings = []
        defined = names.select do |name|
          next true if @methods.include?(name)

          if taken?(name)
            warnings << "api '#{name}' has the name of a method of ApiRecipes; reach it with ApiRecipes[#{name.inspect}]"
            next false
          end
          ApiRecipes.define_singleton_method(name) { Registry.current.global(name) || ApiRecipes[name] }
          true
        end
        (@methods - defined).each do |name|
          ApiRecipes.singleton_class.remove_method(name) if ApiRecipes.singleton_class.method_defined?(name, false)
        end
        @methods = defined.freeze
        warnings
      end

      # Public methods and the reserved ones are taken; so are the private
      # methods of the module that do not come from Kernel (Ruby calls some
      # of them, such as singleton_method_added). The other private methods of
      # Kernel are free, as for endpoints.
      def taken?(name)
        return true if Handles::RESERVED.include?(name) || ApiRecipes.respond_to?(name)
        return false unless ApiRecipes.respond_to?(name, true)

        ApiRecipes.method(name).owner != Kernel
      end
    end

    attr_reader :configs, :definitions, :handles, :generation

    def initialize(configs: {}, definitions: {}, handles: {}, generation: 0)
      @configs = configs.freeze
      @definitions = definitions.freeze
      @handles = handles.freeze
      @generation = generation
      @globals = definitions.to_h do |name, definition|
        context = Context.new(definition: definition, owner: ApiRecipes, global_definition: definition,
                              handles: handles[name])
        [name, handles[name].for(definition).new(context)]
      end.freeze
      freeze
    end

    # The global api called name, always the same object; nil if unknown.
    def global(name) = @globals[name]

    def apis = @definitions.keys

    def inspect = "#<#{self.class.name} generation #{@generation} apis: #{apis.join(', ')}>"

    def to_s = inspect

    def pretty_print(queue) = queue.text(inspect)

    @current = new
  end
end
