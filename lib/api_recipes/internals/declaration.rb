# frozen_string_literal: true

module ApiRecipes
  module Internals
    # One `api :name` in a class or a module: its options and the tree they
    # make with the global configuration, compiled at the first use after every
    # configure. Only the class or module that declared it refers to it (an
    # instance variable and the generated methods); its subclasses and the
    # classes that include the module share it.
    #
    # A credential or a variable set through a declaration is stored under it
    # and read only by requests that the same declaration serves (see
    # Levels.chain), so it never reaches the tree of another declaration of the
    # api. An api name is also declared once per hierarchy, checked when `api`
    # is called and again when a declaration serves an owner, to give a clear
    # error when include or extend brings a second one: the levels do not
    # depend on that check.
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
          api_name = name.to_sym
          check_clash(klass, api_name, method_name)
          # What the class gives to its level: values, not options of the tree.
          given = options.slice(*Registry::VALUE_KEYS)
          options = options.except(*Registry::VALUE_KEYS)
          level = Registry.level_from(given, api_name.to_s)
          variables = level.variables
          registry = Registry.current
          global = registry.definitions[api_name]
          auth = global && global.auth
          errors = Compiler.check_options(options, :api, credential_param: auth && auth[:type] == :query ? auth[:name] : nil)
          raise ConfigurationError.new(errors) unless errors.empty?

          declaration = new(klass, api_name, Compiler.frozen_copy(options), variables, level.credential)
          declaration.check_variables(registry) if global
          declared = klass.instance_variable_get(IVAR)
          klass.instance_variable_set(IVAR, (declared.is_a?(Hash) ? declared : {}).merge(api_name => declaration).freeze)
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

        # One declaration of an api name per class hierarchy, never on a
        # singleton class; and no method of the class or of its instances is
        # replaced.
        def check_clash(klass, api_name, method_name)
          raise ApiNameClashError.new(klass, api_name) if klass.singleton_class?

          holder = klass.ancestors.find { |mod| declares?(mod, api_name) }
          holder ||= descendants(klass).find { |mod| declares?(mod, api_name) }
          raise ApiNameClashError.new(klass, api_name, holder) if holder

          taken = Handles::RESERVED.include?(method_name) || klass.respond_to?(method_name, true) ||
                  klass.method_defined?(method_name) || klass.private_method_defined?(method_name)
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

      def initialize(klass, name, options, variables, credential = nil)
        @klass = klass
        @name = name
        @options = options
        @variables = variables
        # What the class or module gives to its level, fixed here: nothing
        # writes it afterwards, and no reset! removes it. See Api#authorization=.
        @level = variables.nil? && credential.nil? ? nil : Level.new(credential: credential, variables: variables)
        @tree = nil
        @lock = Mutex.new
        @checked = ObjectSpace::WeakMap.new
      end

      # The class or module where `api` was called.
      def declared_in = @klass

      # The level of that class or module, or nil.
      attr_reader :level

      # The api for owner: the class or module, a subclass, an includer, or an
      # instance of one of them.
      def api(owner)
        tree = current_tree
        check_owner(owner, tree.generation)
        tree.api_class.new(Context.new(definition: tree.definition, owner: owner, global_definition: tree.global,
                                       handles: tree.handles, declaration: self, generation: tree.generation))
      end

      # The tree of this declaration under the configuration in force.
      def definition = current_tree.definition

      # The credential is never shown.
      def inspect = "#<#{self.class.name} #{@name}>"

      def to_s = inspect

      def pretty_print(queue) = queue.text(inspect)

      # A value given to `api` for a name that is not a variable of the tree
      # of the class, reported where `api` is called when the api of the
      # application is configured already; else the first use reports it.
      # The tree is not kept: the first use compiles it from the registry
      # current then.
      # registry: the one that `api` read, so that a configure that runs
      # meanwhile does not change what the values are checked against.
      def check_variables(registry)
        definition = @options.empty? ? registry.definitions[@name] : Compiler.compile(@name, own_config(registry.configs[@name]))
        problems = Compiler.unknown_variables(@variables, definition, @name.to_s)
        raise ConfigurationError.new(problems) unless problems.empty?
      end

      private

      # Refuses an owner whose hierarchy holds another declaration of this api.
      # The ancestors of its class (the owner itself for a class or module) are
      # checked once per class and registry generation. An owner that reaches a
      # module's declaration through extend has a singleton class: its
      # ancestors are checked too. Only an owner with singleton methods has
      # one, so asking for it never creates one (an object can also reach the
      # declaration through a method copied with define_method).
      def check_owner(owner, generation)
        klass = Module === owner ? owner : owner.class
        unless @checked[klass] == generation
          holder = other_declarer(klass.ancestors)
          raise ApiNameClashError.new(klass, @name, holder) if holder

          @checked[klass] = generation
        end
        return if @klass.is_a?(Class) || klass <= @klass || owner.singleton_methods.empty?

        holder = other_declarer(owner.singleton_class.ancestors)
        raise ApiNameClashError.new(klass, @name, holder) if holder
      end

      def other_declarer(modules)
        modules.find do |mod|
          declared = mod.instance_variable_get(IVAR)
          declared.is_a?(Hash) && declared.key?(@name) && !declared[@name].equal?(self)
        end
      end

      def current_tree
        tree = @tree
        return tree if tree && tree.generation == Registry.current.generation

        @lock.synchronize { refresh }
      end

      # Without options of its own the class uses the global tree; with them,
      # or without a global api, its own tree, compiled from the global
      # configuration and the options of the class. The registry is read under
      # the lock, so an older registry never replaces a newer tree.
      def refresh
        registry = Registry.current
        tree = @tree
        return tree if tree && tree.generation == registry.generation

        global = registry.definitions[@name]
        global_handles = registry.handles[@name]
        if @options.empty? && global
          definition = global
          handles = global_handles
        else
          definition = Compiler.compile(@name, own_config(registry.configs[@name]))
          handles = Handles.new(definition)
          warnings = handles.warnings - (global_handles ? global_handles.warnings : [])
          warnings.each { |message| ApiRecipes.logger.warn(message) }
        end
        problems = Compiler.unknown_variables(@variables, definition, @name.to_s)
        raise ConfigurationError.new(problems) unless problems.empty?

        @tree = Tree.new(generation: registry.generation, definition: definition, handles: handles, global: global,
                         api_class: handles.for(definition))
      end

      # The configuration of the tree of the class: its options over those of
      # the global api. For an api that only the class declares, the names
      # given in variables: are its variables.
      def own_config(global_config)
        return Compiler.deep_merge(global_config, @options) if global_config
        return @options if @variables.nil? || @variables.empty?

        @options.merge(variables: @variables.to_h { |name, _value| [name, {}] })
      end
    end
  end
end
