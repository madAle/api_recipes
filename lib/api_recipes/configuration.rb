require 'yaml'
require 'erb'
require 'logger'
require 'pathname'

module ApiRecipes
  class Configuration

    attr_accessor :upgrade_warnings
    attr_reader :log_to, :log_level, :print_urls
    attr_reader :variables

    def initialize
      @sources = []
      @apis_configs = {}
      @apis_files_paths = []
      @variables = {}
      @print_urls = false
      @upgrade_warnings = true
    end

    # configure works on a copy: what a setter or the caller can change in
    # place (the list of sources, and the Hashes, Arrays and Strings of
    # apis_configs, apis_files_paths and variables at every depth) is copied,
    # so the original stays as it was. The logger of the application is shared.
    def initialize_copy(source)
      super
      @default_logger = nil
      @sources = @sources.dup
      @apis_configs = deep_copy(@apis_configs)
      @apis_files_paths = deep_copy(@apis_files_paths)
      @variables = deep_copy(@variables)
    end

    # The descriptions of the apis and the variables can hold secrets (header
    # values, tenant names): only the names of the apis are shown.
    def inspect
      "#<#{self.class.name} apis_configs: #{@apis_configs.keys.inspect} " \
        "apis_files_paths: #{@apis_files_paths.size} print_urls: #{@print_urls.inspect}>"
    end

    def to_s = inspect

    def pretty_print(queue) = queue.text(inspect)

    def apis_configs=(configs = {})
      raise ArgumentError, 'apis_configs must be an Hash' unless configs.is_a? Hash

      @apis_configs = Internals::Compiler.normalize(configs, :options_map)
      record_source(:hash)
    end

    attr_reader :apis_configs, :apis_files_paths

    def apis_files_paths=(paths = [])
      raise ArgumentError, 'apis_files_paths must be an Array' unless paths.is_a? Array

      @apis_files_paths = paths
      record_source(:files)
    end

    def variables=(variables)
      raise ArgumentError, 'variables must be an Hash' unless variables.is_a? Hash

      @variables = variables
    end

    # Applies the sources in the order they were assigned and returns the
    # apis as { name => description }. A later source replaces whole apis.
    def load
      apis = {}
      @sources.each do |kind|
        if kind == :hash
          apis.merge!(@apis_configs)
        else
          @apis_files_paths.each { |path| merge_file(apis, path) }
        end
      end
      apis
    end

    # Reads one file with the rules of apis_files_paths and returns the apis as
    # { name => description }. ERB is evaluated only with erb: true; without it a
    # file that contains ERB is refused and nothing in it is run.
    def read_recipe_file(path, erb: true)
      read_file(path, erb: erb)
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
    def record_source(kind)
      @sources.delete(kind)
      @sources << kind
    end

    # @private
    def merge_file(apis, path)
      read_file(path).each do |api, params|
        logger.debug "File at #{path} overrides config for '#{api}' API" if apis.key?(api)
        apis[api] = params
      end
    end

    # @private
    def read_file(path, erb: true)
      unless (path.is_a?(String) || path.is_a?(Pathname)) && !path.to_s.include?("\0")
        raise ConfigurationError.new(['apis_files_paths: every path must be a String or a Pathname, without null bytes'])
      end

      full_path = File.expand_path(path)
      if shared_recipe?(full_path)
        raise RecipeFileError.new(path, 'shared recipe files (.recipe.yml) are not supported by this version')
      end

      text = read_text(path, full_path)
      if erb
        text = ERB.new(text).result
      elsif text.include?('<%')
        raise RecipeFileError.new(path, 'contains ERB: run again with --erb to evaluate it ' \
                                        '(this executes the code in the file)')
      end
      data = begin
               YAML.safe_load(text, permitted_classes: [Symbol], aliases: true)
             rescue Psych::Exception => e
               raise RecipeFileError.new(path, "invalid YAML: #{e.message}")
             end
      raise RecipeFileError.new(path, 'file is empty') if data.nil?
      raise RecipeFileError.new(path, 'must contain a mapping of api names') unless data.is_a?(Hash)

      Internals::Compiler.normalize(data, :options_map)
    end

    # @private
    def read_text(path, full_path)
      text = File.read(full_path, encoding: 'UTF-8')
      raise RecipeFileError.new(path, 'file is not valid UTF-8') unless text.valid_encoding?

      text
    rescue Errno::ENOENT
      raise RecipeFileError.new(path, 'file not found')
    rescue SystemCallError => e
      raise RecipeFileError.new(path, "cannot read file (#{e.class.name.split('::').last})")
    end

    # @private
    def shared_recipe?(full_path)
      names = [full_path]
      names << File.realpath(full_path) if File.exist?(full_path)
      names.any? { |name| name.downcase.end_with?('.recipe.yml') }
    end

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
