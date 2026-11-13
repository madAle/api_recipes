# frozen_string_literal: true

module ApiRecipes
  module Internals
    # What configure produced: the compiled trees, their handles and one global
    # Api per tree. Immutable: configure builds a new registry and swaps it in
    # with one assignment, so a reader sees the old one or the new one, never a
    # mix. The generation grows at every swap, reset! included.
    class Registry
      LOCK = Mutex.new
      WARNED_LOCK = Mutex.new

      @warned = {}

      @methods = [].freeze
      @variable_names = [].freeze

      class << self
        attr_reader :current

        # Loads and compiles the configuration, then swaps the registry in and
        # calls the block, which keeps the configuration: both under one lock,
        # so that two calls never pair the configuration of one with the
        # registry of the other. If anything raises before the swap, the
        # current registry stays and the block is not called.
        def install(configuration)
          LOCK.synchronize do
            apis = configuration.load
            definitions = Compiler.compile_all(apis, configuration.variables)
            handles = definitions.transform_values { |definition| Handles.new(definition) }
            variables = Compiler.normalize(configuration.variables).to_h { |name, values| [name, variable_values(values)] }
            WARNED_LOCK.synchronize { @warned = {} }
            @current = new(configs: Compiler.frozen_copy(apis), definitions: definitions, handles: handles,
                           generation: @current.generation + 1)
            yield if block_given?
            warnings = define_methods(@current.apis) + handles.values.flat_map(&:warnings)
            (variables.keys - definitions.keys).each do |name|
              warnings << "variables are given for '#{name}', which is not a configured api"
            end
            # A name that configure set belongs to the configuration: the next
            # successful configure applies its variables again or removes them,
            # so a value assigned directly under such a name is replaced. A value
            # assigned directly to a name that configure never set is not touched.
            LevelSet.replace_variables(ApiRecipes, variables, @variable_names - variables.keys)
            @variable_names = variables.keys.freeze
            warnings.each { |message| configuration.logger.warn(message) }
          end
        end

        # Writes message at warn level the first time it sees key, unless the
        # configuration turned the upgrade warnings off. The message never holds
        # a value of the application.
        def warn_once(key, message)
          configuration = ApiRecipes.configuration
          return unless configuration.upgrade_warnings

          first = WARNED_LOCK.synchronize { @warned.key?(key) ? false : (@warned[key] = true) }
          configuration.logger.warn(message) if first
        end

        # The upgrade warning for a path parameter: kind is :slash or :encoded.
        def warn_upgrade(endpoint, param, kind)
          message = if kind == :slash
                      "#{endpoint}: the value of '#{param}' contains '/' and is now sent as %2F. " \
                        "To span several segments use *#{param} in the path."
                    else
                      "#{endpoint}: the value of '#{param}' looks already percent-encoded. " \
                        'ApiRecipes now encodes path parameters itself.'
                    end
          warn_once([endpoint, param, kind], message)
        end

        # Removes the methods generated on ApiRecipes, empties the registry and
        # the levels, then calls the block, all under the same lock.
        def reset!
          LOCK.synchronize do
            LevelSet.reset!
            @variable_names = [].freeze
            define_methods([])
            WARNED_LOCK.synchronize { @warned = {} }
            @current = new(generation: @current.generation + 1)
            yield if block_given?
          end
        end

        # Variable values as a level stores them: a frozen copy with Symbol keys,
        # or nil. Anything else than a Hash or nil raises ConfigurationError.
        def variable_values(values)
          Compiler.resolve_options({ variables: values }, :with_api)[:variables]
        end

        private

        # One method on ApiRecipes per api, unless the name is taken by another
        # method of the module, with the rule of Handles.taken?. Returns the
        # warnings.
        def define_methods(names)
          warnings = []
          defined = names.select do |name|
            next true if @methods.include?(name)

            if Handles.taken?(ApiRecipes.singleton_class, name)
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
end
