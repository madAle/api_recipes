require 'yaml'
require 'erb'
require 'logger'

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

    # configure works on a copy: the lists and Hashes that a setter or the
    # caller can change in place are copied, so the original stays as it was.
    def initialize_copy(source)
      super
      @default_logger = nil
      @sources = @sources.dup
      @apis_configs = @apis_configs.dup
      @apis_files_paths = @apis_files_paths.dup
      @variables = @variables.dup
    end

    def apis_configs=(configs = {})
      raise ArgumentError, 'apis_configs must be an Hash' unless configs.is_a? Hash

      @apis_configs = configs.transform_keys(&:to_sym)
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
          apis.merge!(deep_symbolize(@apis_configs))
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
      full_path = File.expand_path(path)
      if shared_recipe?(full_path)
        raise RecipeFileError.new(path, 'shared recipes are loaded with recipes_paths, not with apis_files_paths')
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

      deep_symbolize(data)
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
    def deep_symbolize(value)
      case value
      when Hash then value.each_with_object({}) { |(k, v), h| h[k.respond_to?(:to_sym) ? k.to_sym : k] = deep_symbolize(v) }
      when Array then value.map { |v| deep_symbolize(v) }
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
        ENV['LOG_LEVEL'] || (print_urls ? ::Logger::INFO : ::Logger::WARN)
      end
    end
  end
end
