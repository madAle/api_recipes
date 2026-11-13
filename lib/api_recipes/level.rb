module ApiRecipes
  # What was assigned to one api at one level: a credential (nil when never
  # assigned, Credential::NONE when removed on purpose) and variable values.
  Level = Data.define(:credential, :variables) do
    def inspect = "#<ApiRecipes::Level credential=#{credential.inspect} variables=[FILTERED]>"

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
  # @__api_recipes of its owner (an instance, a class, a module or the
  # ApiRecipes module) and is replaced, never changed. The key of a level
  # written through a declaration is that Declaration, compared by identity;
  # the key of the global level is the api name. It never writes its content
  # when serialized: a rebuilt LevelSet is sealed and answers "no credential"
  # for every key.
  class LevelSet
    IVAR = :@__api_recipes
    FILTERED = '[FILTERED]'.freeze
    EMPTY = {}.compare_by_identity.freeze

    @generation = 0

    class << self
      # key: a Declaration, or an api name for the global level.
      def read(owner, key)
        set = live_set(owner)
        return nil unless set

        set.fetch(key.is_a?(String) ? key.to_sym : key)
      end

      def write(owner, key)
        if owner.frozen?
          raise Error, 'cannot assign credentials or variables on a frozen object. ' \
                       'Use with(...) to get a modified copy instead'
        end

        set = live_set(owner)
        key = key.to_sym if key.is_a?(String)
        # A write on a sealed set changes only its key: every other key keeps
        # answering "no credential, do not inherit one".
        level = yield(set&.fetch(key) || Level.new(credential: nil, variables: nil))
        store(owner, set, key => level)
        level
      end

      # Sets the variables of the levels in values (name => variables) and
      # removes those of the levels named in cleared, in one replacement of
      # the set. The credentials are not touched.
      def replace_variables(owner, values, cleared)
        set = live_set(owner)
        changes = cleared.to_h do |name|
          level = set&.fetch(name)
          [name, level && level.variables ? level.with(variables: nil) : level]
        end.compact
        values.each do |name, variables|
          changes[name] = (set&.fetch(name) || Level.new(credential: nil, variables: nil)).with(variables: variables)
        end
        store(owner, set, changes) unless changes.empty?
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

    def inspect = "#<ApiRecipes::LevelSet #{FILTERED}>"

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
    # Levels that hold a value for one api, nearest first. Those of an object,
    # a class or a module are the ones written through declaration: the
    # object, every ancestor of its class (the owner itself for a class or a
    # module), then the class or module that declared the api when it is not
    # among them (an object or a class extended with it). A level written
    # through another declaration is never returned. Last the global level,
    # by api name. Without a declaration (a global api) only the global level.
    def self.chain(owner, api_name, declaration)
      chain = []
      if declaration
        if owner.is_a?(Module)
          klass = owner
        else
          klass = owner.class
          level = LevelSet.read(owner, declaration)
          chain << [:instance, level] if level
        end
        klass.ancestors.each do |mod|
          level = LevelSet.read(mod, declaration)
          chain << [:class, level] if level
        end
        declared_in = declaration.declared_in
        unless klass <= declared_in
          level = LevelSet.read(declared_in, declaration)
          chain << [:class, level] if level
        end
      end
      level = LevelSet.read(ApiRecipes, api_name)
      chain << [:global, level] if level
      chain
    end
  end
end
