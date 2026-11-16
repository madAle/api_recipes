# frozen_string_literal: true

module ApiRecipes
  module Internals
    # What was assigned to one api at one level: a credential (nil when never
    # assigned, Credential::NONE when removed on purpose) and variable values.
    Level = Data.define(:credential, :variables) do
      def inspect = "#<ApiRecipes::Internals::Level credential=#{credential.inspect} variables=[FILTERED]>"

      def to_s = inspect

      def pretty_print(queue) = queue.text(inspect)

      # Serialized forms never carry values: a rebuilt level is empty and has no credential.
      def _dump(_depth) = ''

      def self._load(_data) = new(credential: Credential::NONE, variables: nil)

      def encode_with(coder)
        coder['sealed'] = true
      end

      def init_with(_coder)
        initialize(credential: Credential::NONE, variables: nil)
      end

      def as_json(*) = '[FILTERED]'

      def to_json(*) = '"[FILTERED]"'
    end

    # Immutable map key => Level. It is stored in the instance variable
    # @__api_recipes of its owner, an object, and is replaced, never changed.
    # The key of a level is the Declaration it was written through, compared
    # by identity. It never writes its content
    # when serialized: a rebuilt LevelSet is sealed and answers "no credential"
    # for every key.
    class LevelSet
      IVAR = :@__api_recipes
      FILTERED = '[FILTERED]'.freeze
      EMPTY = {}.compare_by_identity.freeze
      # A write reads the set of its owner, changes one key and stores a new
      # set: two writes at once would lose one, an assignment of nil included.
      # Reads take no lock. The block of write must not write a level.
      WRITES = Mutex.new

      @generation = 0

      class << self
        # key: a Declaration, or an api name for the global level.
        def read(owner, key)
          set = live_set(owner)
          return nil unless set

          set.fetch(key.is_a?(String) ? key.to_sym : key)
        end

        # Only an object has a set: the level of a class or a module is the
        # one of its declaration, and the level of the application is in the
        # registry. Both are given when the application starts.
        def write(owner, key)
          raise Error, 'a level is written on an object, not on a class or a module' if Module === owner
          if owner.frozen?
            raise Error, 'cannot assign credentials or variables on a frozen object. ' \
                         'Use with(...) to get a modified copy instead'
          end

          key = key.to_sym if key.is_a?(String)
          WRITES.synchronize do
            set = live_set(owner)
            # A write on a sealed set changes only its key: every other key keeps
            # answering "no credential, do not inherit one".
            level = yield(set&.fetch(key) || Level.new(credential: nil, variables: nil))
            store(owner, set, key => level)
            level
          end
        end

        # Why a writer of Api refuses: what is the option (:authorization,
        # :basic_auth, :variables), owner the caller, api the name of the api,
        # plain false for an api returned by with.
        def refusal(what, owner, api, plain)
          return "an api returned by with cannot set #{what} for the caller: use with(#{what}: ...)" unless plain

          if owner.equal?(ApiRecipes)
            "ApiRecipes.#{api} is shared by the whole application, in every thread: give its #{what} to " \
              "ApiRecipes.configure, as config.values = { #{api}: { #{what}: ... } }, or use with(#{what}: ...) for one chain"
          else
            "a class or a module is shared by all its objects, in every thread: give its #{what} to " \
              "`api :#{api}, #{what}: ...`, or use an object or with(#{what}: ...) for one chain"
          end
        end

        def reset!
          @generation += 1
        end

        def generation = @generation

        private

        def store(owner, set, changes)
          entries = (set ? set.entries : EMPTY).merge(changes)
          owner.instance_variable_set(IVAR, new(entries, generation, sealed: set ? set.sealed? : false))
        end

        def live_set(owner)
          set = owner.instance_variable_get(IVAR)
          set if set.is_a?(self) && set.generation == generation
        end
      end

      attr_reader :entries, :generation

      def initialize(entries, generation, sealed: false)
        @entries = entries.freeze
        @generation = generation
        @sealed = sealed
        freeze
      end

      def sealed? = @sealed

      def fetch(key)
        @entries[key] || (@sealed ? Level.new(credential: Credential::NONE, variables: nil) : nil)
      end

      def inspect = "#<ApiRecipes::Internals::LevelSet #{FILTERED}>"

      def to_s = inspect

      def pretty_print(queue) = queue.text(inspect)

      def marshal_dump = nil

      def marshal_load(_data)
        @entries = EMPTY
        @generation = self.class.generation
        @sealed = true
        freeze
      end

      def encode_with(coder)
        coder['sealed'] = true
      end

      def init_with(_coder)
        @entries = EMPTY
        @generation = self.class.generation
        @sealed = true
        freeze
      end

      def as_json(*) = FILTERED

      def to_json(*) = FILTERED.inspect
    end

    module Levels
      # The levels of one request, nearest first, as [kind, level] pairs, with
      # the registry the global one was read from: a request takes the tree in
      # force and the values of the application from the same registry.
      class Chain < Array
        attr_reader :registry

        def initialize(entries, registry)
          super(entries)
          @registry = registry
          freeze
        end
      end

      # Levels that hold a value for one api, nearest first: the one of the
      # object, written through declaration; the one that declaration gives to
      # the class or module where `api` was called, which is the only level a
      # class or a module has; last the level of the application, by api name,
      # which the registry in force holds. A level of another declaration is
      # never returned. Without a declaration (a global api) only the last one.
      def self.chain(owner, api_name, declaration)
        registry = Registry.current
        entries = []
        if declaration
          unless Module === owner
            level = LevelSet.read(owner, declaration)
            entries << [:instance, level] if level
          end
          level = declaration.level
          entries << [:class, level] if level
        end
        level = registry.level(api_name)
        entries << [:global, level] if level
        Chain.new(entries, registry)
      end

      # The level of owner alone: what the readers of an api show.
      def self.own(owner, api_name, declaration)
        return LevelSet.read(owner, declaration) unless Module === owner

        declaration ? declaration.level : Registry.current.level(api_name)
      end
    end
  end
end
