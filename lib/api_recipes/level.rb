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

  # Immutable map api_name => Level. It is stored in the instance variable
  # @__api_recipes of its owner (an instance, a class or the ApiRecipes module)
  # and is replaced, never changed. It never writes its content when serialized:
  # a rebuilt LevelSet is sealed and answers "no credential" for every api.
  class LevelSet
    IVAR = :@__api_recipes
    FILTERED = '[FILTERED]'.freeze

    @generation = 0

    class << self
      def read(owner, api_name)
        set = live_set(owner)
        return nil unless set

        set.fetch(api_name.to_sym)
      end

      def write(owner, api_name)
        if owner.frozen?
          raise Error, 'cannot assign credentials or variables on a frozen object. ' \
                       'Use with(...) to get a modified copy instead'
        end

        set = live_set(owner)
        key = api_name.to_sym
        current = set && !set.sealed? ? set.entries[key] : nil
        entries = set && !set.sealed? ? set.entries : {}
        level = yield(current || Level.new(credential: nil, variables: nil))
        owner.instance_variable_set(IVAR, new(entries.merge(key => level), generation))
        level
      end

      def reset!
        @generation += 1
      end

      def generation = @generation

      private

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

    def fetch(api_name)
      return Level.new(credential: Credential::NONE, variables: nil) if @sealed

      @entries[api_name]
    end

    def inspect = "#<ApiRecipes::LevelSet #{FILTERED}>"

    def to_s = inspect

    def pretty_print(queue) = queue.text(inspect)

    def marshal_dump = nil

    def marshal_load(_data)
      @entries = {}.freeze
      @generation = self.class.generation
      @sealed = true
      freeze
    end

    def encode_with(coder)
      coder['sealed'] = true
    end

    def init_with(_coder)
      @entries = {}.freeze
      @generation = self.class.generation
      @sealed = true
      freeze
    end

    def as_json(*) = FILTERED

    def to_json(*) = FILTERED.inspect
  end

  module Levels
    # Levels that hold a value for api_name, nearest first: the object, the
    # modules it was extended with, every ancestor of its class (classes and
    # modules, in order; the owner itself for a class or module), then the
    # global level. ApiRecipes among the ancestors is the global level.
    def self.chain(owner, api_name)
      chain = []
      if owner.is_a?(Module)
        klass = owner
      else
        klass = owner.class
        level = LevelSet.read(owner, api_name)
        chain << [:instance, level] if level
        # Only an object with singleton methods has a singleton class, so
        # asking for it here never creates one.
        unless owner.singleton_methods.empty?
          owner.singleton_class.ancestors.each do |mod|
            break if klass <= mod

            level = LevelSet.read(mod, api_name)
            chain << [:class, level] if level
          end
        end
      end
      unless owner.equal?(ApiRecipes)
        klass.ancestors.each do |mod|
          next if mod.equal?(ApiRecipes)

          level = LevelSet.read(mod, api_name)
          chain << [:class, level] if level
        end
      end
      level = LevelSet.read(ApiRecipes, api_name)
      chain << [:global, level] if level
      chain
    end
  end
end
