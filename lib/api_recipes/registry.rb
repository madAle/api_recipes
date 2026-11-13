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

    # One `api :name` in a class: its options and the tree they make with the
    # global configuration, compiled at the first use after every configure.
    # Only the class that declared it refers to it (an instance variable and
    # the generated methods); its subclasses share it.
    class Declaration
      IVAR = :@__api_recipes_declarations
      Tree = Data.define(:generation, :definition, :handles, :global, :api_class)

      class << self
        # Checks the arguments of `api`, then defines the method on klass and
        # on its instances. Returns the name of the method.
        def declare(klass, name, options)
          unless name.is_a?(String) || name.is_a?(Symbol)
            raise ArgumentError, "api name must be a Symbol or a String, not #{name.class}"
          end
          if name.empty? || (name.is_a?(String) && !name.valid_encoding?)
            raise ArgumentError, 'api name must not be empty and must be valid UTF-8'
          end
          raise ApiConfigIsNotAnHash.new(name) unless options.nil? || options.is_a?(Hash)

          options = Compiler.normalize(options || {})
          method_name = method_for(options.delete(:as), name)
          variables = options.delete(:variables)
          api_name = name.to_sym
          check_clash(klass, api_name, method_name)
          variables = Registry.variable_values(variables)
          errors = Compiler.check_options(options, :api)
          raise ConfigurationError.new(errors) unless errors.empty?

          declaration = new(klass, api_name, Compiler.frozen_copy(options), variables)
          declared = klass.instance_variable_get(IVAR)
          klass.instance_variable_set(IVAR, (declared.is_a?(Hash) ? declared : {}).merge(api_name => declaration).freeze)
          declaration.write_variables
          klass.define_method(method_name) { declaration.api(self) }
          klass.define_singleton_method(method_name) { declaration.api(self) }
          method_name
        end

        private

        def method_for(as, name)
          return name.to_sym if as.nil?
          return as.to_sym if (as.is_a?(String) || as.is_a?(Symbol)) && Compiler::METHOD_NAME.match?(as.to_s)

          raise ConfigurationError.new(['as: must be a valid method name'])
        end

        # One declaration of an api name per class hierarchy, so that every
        # class level of a credential chain reads the same tree; and no
        # method of the class or of its instances is replaced.
        def check_clash(klass, api_name, method_name)
          holder = klass.ancestors.find { |mod| declares?(mod, api_name) }
          holder ||= descendants(klass).find { |mod| declares?(mod, api_name) }
          raise ApiNameClashError.new(klass, api_name, holder) if holder

          taken = klass.respond_to?(method_name, true) || klass.method_defined?(method_name) ||
                  klass.private_method_defined?(method_name)
          raise ApiNameClashError.new(klass, method_name) if taken
        end

        def declares?(mod, api_name)
          declared = mod.instance_variable_get(IVAR)
          declared.is_a?(Hash) && declared.key?(api_name)
        end

        def descendants(klass)
          return [] unless klass.is_a?(Class)

          found = []
          pending = klass.subclasses
          until pending.empty?
            subclass = pending.pop
            found << subclass
            pending.concat(subclass.subclasses)
          end
          found
        end
      end

      def initialize(klass, name, options, variables)
        @klass = klass
        @name = name
        @options = options
        @variables = variables
        @variables_generation = nil
        @tree = nil
        @lock = Mutex.new
      end

      # The api for owner (the class, a subclass or an instance).
      def api(owner)
        tree = current_tree
        tree.api_class.new(Context.new(definition: tree.definition, owner: owner, global_definition: tree.global,
                                       handles: tree.handles))
      end

      # Writes the declared variables in the level of the class, again after
      # a reset! of the levels.
      def write_variables
        return if @variables.nil?

        LevelSet.write(@klass, @name) { |level| level.with(variables: @variables) }
        @variables_generation = LevelSet.generation
      end

      def inspect = "#<#{self.class.name} #{@name}>"

      def to_s = inspect

      def pretty_print(queue) = queue.text(inspect)

      private

      def current_tree
        registry = Registry.current
        tree = @tree
        return tree if tree && tree.generation == registry.generation

        @lock.synchronize { refresh(registry) }
      end

      # Without options of its own the class uses the global tree; with them,
      # or without a global api, its own tree, compiled from the global
      # configuration and the options of the class.
      def refresh(registry)
        tree = @tree
        return tree if tree && tree.generation == registry.generation

        global = registry.definitions[@name]
        global_handles = registry.handles[@name]
        if @options.empty? && global
          definition = global
          handles = global_handles
        else
          definition = Compiler.compile(@name, Compiler.deep_merge(registry.configs[@name] || {}, @options))
          handles = Handles.new(definition)
          warnings = handles.warnings - (global_handles ? global_handles.warnings : [])
          warnings.each { |message| ApiRecipes.logger.warn(message) }
        end
        write_variables if @variables_generation != LevelSet.generation
        @tree = Tree.new(generation: registry.generation, definition: definition, handles: handles, global: global,
                         api_class: handles.for(definition))
      end
    end
  end
end
