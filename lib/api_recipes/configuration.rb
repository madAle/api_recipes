# frozen_string_literal: true

require 'yaml'
require 'logger'
require 'pathname'

module ApiRecipes
  class Configuration

    attr_accessor :upgrade_warnings
    attr_reader :log_to, :log_level, :print_urls
    # What values= was given inside this call of configure, as
    # { api name => Internals::Level }, or nil. A level never shows or
    # serializes its content. Once the configuration is in force the values
    # are those of the registry, and this is nil again.
    attr_reader :value_levels

    def initialize
      @apis_configs = {}
      @recipes_paths = []
      @value_levels = nil
      @draft = false
      @print_urls = false
      @upgrade_warnings = true
    end

    # configure works on a copy: what a setter or the caller can change in
    # place (the Hashes, Arrays and Strings of apis_configs and of
    # recipes_paths at every depth) is copied, so the
    # original stays as it was. The logger of the application is shared. The
    # copy is the draft that configure yields, the only one that takes values.
    def initialize_copy(source)
      super
      @default_logger = nil
      @apis_configs = deep_copy(@apis_configs)
      @recipes_paths = deep_copy(@recipes_paths)
      @value_levels = nil
      @draft = true
    end

    # Called by configure when the draft becomes the configuration in force.
    def close_draft
      @draft = false
      @value_levels = nil
      self
    end

    # The descriptions of the apis and the variables can hold secrets (header
    # values, tenant names): only the names of the apis are shown.
    def inspect
      "#<#{self.class.name} apis_configs: #{@apis_configs.keys.inspect} " \
        "recipes_paths: #{@recipes_paths.size} " \
        "print_urls: #{@print_urls.inspect}>"
    end

    def to_s = inspect

    def pretty_print(queue) = queue.text(inspect)

    def apis_configs=(configs = {})
      raise ArgumentError, 'apis_configs must be an Hash' unless configs.is_a? Hash

      @apis_configs = Internals::Compiler.normalize(configs, :options_map)
    end

    attr_reader :apis_configs, :recipes_paths

    # 2.x loaded files of the project, YAML with ERB, through this option.
    # An api is now described by a portable recipe, or by apis_configs.
    REMOVED_FILES = 'apis_files_paths was removed in 3.0: an api is described by a portable recipe, loaded with recipes_paths. ' \
                    'Run `api_recipes convert` in the root of the project: it moves every description to a recipe and ' \
                    'changes this configuration'

    def apis_files_paths=(*)
      raise Error, REMOVED_FILES
    end

    def apis_files_paths = raise(Error, REMOVED_FILES)

    # Portable recipes: files written by someone else, installed with the
    # api_recipes command. They are read as data only, never with ERB, and each
    # must match the recipes.lock of its folder.
    def recipes_paths=(paths = [])
      raise ArgumentError, 'recipes_paths must be an Array' unless paths.is_a? Array

      @recipes_paths = paths
    end

    # The credential and the variable values of each api, for the whole
    # application: { github: { authorization: '...', variables: { ... } } }.
    # Each api takes authorization or basic_auth, and variables. They are
    # checked and copied here, and replace those given before. It is the only
    # way to give them at this level, and it works only inside the block of
    # configure: see Api#authorization=.
    def values=(values)
      unless @draft
        raise Error, 'values are given inside the block of ApiRecipes.configure, as config.values = { ... }'
      end
      raise ArgumentError, 'values must be an Hash' unless values.is_a? Hash

      @value_levels = Internals::Registry.value_levels(values)
    end

    # Returns the apis as { name => description }: those of apis_configs,
    # then the recipes of recipes_paths, which replace nothing: a name that
    # apis_configs defines is an error.
    def load
      apis = {}.merge(@apis_configs)
      apis.merge(Internals::Recipe.load_all(@recipes_paths, taken: apis.keys))
    end

    def logger=(logger)
      @logger = logger
    end

    # The logger of the application, or one that writes to log_to or STDERR at
    # warn level: normal use prints nothing, the warnings show.
    def logger
      @logger || (@default_logger ||= default_logger)
    end

    # The default logger is built from the options as they are when it is
    # first needed, so changing one of them drops it.
    def log_to=(target)
      @default_logger = nil
      @log_to = target
    end

    def log_level=(level)
      @default_logger = nil
      @log_level = level
    end

    def print_urls=(value)
      @default_logger = nil
      @print_urls = value
    end

    private

    # @private
    # A copy of value whose Hashes, Arrays and unfrozen Strings are new
    # objects; any other object is the same. A Hash or Array met twice, or
    # that contains itself, is copied once.
    def deep_copy(value, memo = {}.compare_by_identity)
      case value
      when Hash
        return memo[value] if memo.key?(value)

        copy = memo[value] = {}
        value.each { |key, item| copy[deep_copy(key, memo)] = deep_copy(item, memo) }
        copy
      when Array
        return memo[value] if memo.key?(value)

        copy = memo[value] = []
        value.each { |item| copy << deep_copy(item, memo) }
        copy
      when String then value.frozen? ? value : value.dup
      else value
      end
    end

    # @private
    def default_logger
      log = ::Logger.new(log_to || $stderr)
      log.level    = normalize_log_level
      log.progname = 'ApiRecipes'
      log
    end

    # @private
    def normalize_log_level
      case @log_level
      when :debug, ::Logger::DEBUG, 'debug' then ::Logger::DEBUG
      when :info,  ::Logger::INFO,  'info'  then ::Logger::INFO
      when :warn,  ::Logger::WARN,  'warn'  then ::Logger::WARN
      when :error, ::Logger::ERROR, 'error' then ::Logger::ERROR
      when :fatal, ::Logger::FATAL, 'fatal' then ::Logger::FATAL
      else
        env_log_level || (print_urls ? ::Logger::INFO : ::Logger::WARN)
      end
    end

    # @private
    # The level named by LOG_LEVEL in any letter case, or nil: a value that is
    # not a level is ignored.
    def env_log_level
      name = ENV['LOG_LEVEL'].to_s.strip.downcase
      %w[debug info warn error fatal].index(name)
    end
  end
end
