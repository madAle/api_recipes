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
      VALUE_KEYS = %i[variables authorization basic_auth].freeze

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
            # A configuration that gives no values keeps those in force now,
            # read under the lock: not those of when its block started.
            levels = configuration.value_levels || @current.levels
            definitions = Compiler.compile_all(apis, levels.transform_values(&:variables))
            handles = definitions.transform_values { |definition| Handles.new(definition) }
            WARNED_LOCK.synchronize { @warned = {} }
            # One assignment: the trees and the values of the application
            # change together, for every reader.
            @current = new(configs: Compiler.frozen_copy(apis), definitions: definitions, handles: handles,
                           levels: levels, generation: @current.generation + 1)
            yield if block_given?
            warnings = define_methods(@current.apis) + handles.values.flat_map(&:warnings)
            (levels.keys - definitions.keys).each do |name|
              warnings << "values are given for '#{PlainYaml.label(name.to_s, 40)}', which is not a configured api"
            end
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

        # values as { api name => Level }: what config.values holds. Raises
        # ConfigurationError, or InvalidCredential, without showing a value.
        def value_levels(values)
          values.each_with_object({}) do |(name, given), levels|
            unless name.is_a?(Symbol) || (name.is_a?(String) && name.valid_encoding?)
              raise ConfigurationError.new(['values: the name of an api must be a String or a Symbol'])
            end
            key = name.to_sym
            shown = PlainYaml.label(name.to_s, 40)
            raise ConfigurationError.new(["values.#{shown}: is not the name of an api"]) unless shown == name.to_s && !shown.empty?
            raise ConfigurationError.new(["values.#{key}: is given twice"]) if levels.key?(key)

            levels[key] = level_from(given, "values.#{key}")
          end.freeze
        end

        # The level that given describes: variables, and authorization or
        # basic_auth. A credential given as nil means "send none".
        def level_from(given, where)
          raise ConfigurationError.new(["#{where}: must be a Hash"]) unless given.is_a?(Hash)

          texts = given.keys.map(&:to_s)
          # What is not one of the three names is not shown: a credential
          # written in the wrong place would be.
          unless (texts - VALUE_KEYS.map(&:to_s)).empty?
            raise ConfigurationError.new(["#{where}: takes variables, authorization and basic_auth, and nothing else"])
          end
          twice = texts.find { |text| texts.count(text) > 1 }
          raise ConfigurationError.new(["#{where}: #{twice} is given twice"]) if twice

          names = texts.map(&:to_sym)
          if names.include?(:authorization) && names.include?(:basic_auth)
            raise ConfigurationError.new(["#{where}: takes authorization or basic_auth, not both"])
          end

          resolved = Compiler.resolve_options(given, :with_api)
          kind = (names & %i[authorization basic_auth]).first
          Level.new(credential: kind && Credential.from(kind, resolved[kind]), variables: resolved[:variables])
        rescue ConfigurationError => e
          raise e if e.errors.all? { |problem| problem.start_with?(where) }

          raise ConfigurationError.new(e.errors.map { |problem| "#{where}.#{problem}" })
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

      # levels: what the whole application gives to each api, name => Level.
      attr_reader :configs, :definitions, :handles, :levels, :generation

      def initialize(configs: {}, definitions: {}, handles: {}, levels: {}, generation: 0)
        @configs = configs.freeze
        @definitions = definitions.freeze
        @handles = handles.freeze
        @levels = levels.freeze
        @generation = generation
        @globals = definitions.to_h do |name, definition|
          context = Context.new(definition: definition, owner: ApiRecipes, global_definition: definition,
                                handles: handles[name], generation: generation)
          [name, handles[name].for(definition).new(context)]
        end.freeze
        freeze
      end

      # The level of the application for the api called name, or nil.
      def level(name) = @levels[name]

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
