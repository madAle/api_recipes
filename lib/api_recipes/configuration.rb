require 'yaml'
require 'erb'
require 'logger'

module ApiRecipes
  class Configuration

    attr_accessor :log_to, :log_level, :print_urls, :upgrade_warnings
    attr_reader :variables

    def initialize
      @sources = []
      @apis_configs = {}
      @apis_files_paths = []
      @variables = {}
      @upgrade_warnings = true
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

    def logger=(logger)
      @logger = logger
    end

    def logger
      unless @logger
        log = ::Logger.new(log_to || STDOUT)
        log.level    = normalize_log_level
        log.progname = 'ApiRecipes'
        @logger = log
      end

      @logger
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
    def read_file(path)
      full_path = File.expand_path(path)
      if full_path.end_with?('.recipe.yml')
        raise RecipeFileError.new(path, 'shared recipes are loaded with recipes_paths, not with apis_files_paths')
      end

      begin
        text = File.read(full_path)
      rescue Errno::ENOENT
        raise RecipeFileError.new(path, 'file not found')
      end
      data = begin
               YAML.safe_load(ERB.new(text).result, permitted_classes: [Symbol], aliases: true)
             rescue Psych::Exception => e
               raise RecipeFileError.new(path, "invalid YAML: #{e.message}")
             end
      raise RecipeFileError.new(path, 'file is empty') if data.nil?
      raise RecipeFileError.new(path, 'must contain a mapping of api names') unless data.is_a?(Hash)

      deep_symbolize(data)
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
    def normalize_log_level
      case @log_level
      when :debug, ::Logger::DEBUG, 'debug' then ::Logger::DEBUG
      when :info,  ::Logger::INFO,  'info'  then ::Logger::INFO
      when :warn,  ::Logger::WARN,  'warn'  then ::Logger::WARN
      when :error, ::Logger::ERROR, 'error' then ::Logger::ERROR
      when :fatal, ::Logger::FATAL, 'fatal' then ::Logger::FATAL
      else
        ENV['LOG_LEVEL'] || Logger::DEBUG
      end
    end
  end
end
