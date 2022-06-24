require 'yaml'
require 'erb'

module ApiRecipes
  class Configuration

    attr_accessor :log_to, :log_level, :print_urls, :apis_files_paths

    def apis_configs=(configs = {})
      raise ArgumentError, 'apis_configs must be an Hash' unless configs.is_a? Hash

      @apis_configs = configs.deep_symbolize_keys
    end

    def apis_configs
      unless @apis_configs
        @apis_configs = {}
      end
      @apis_configs
    end

    def apis_files_paths=(paths = [])
      raise ArgumentError, 'apis_files_paths must be an Array' unless paths.is_a? Array

      @apis_files_paths = paths
      @apis_files_paths.each do |file_path|
        template = ERB.new File.read File.expand_path(file_path)
        data = begin
                 YAML.load(template.result(binding), aliases: true)
               rescue ArgumentError
                 YAML.load(template.result binding)
               end.deep_symbolize_keys
        # Merge file contents into apis_configs
        data.each do |api, params|
          if apis_configs[api]
            logger.warn "File at #{file_path} overrides config for '#{api}' API"
          end
          apis_configs[api] = params
        end
      end
    end

    def apis_files_paths
      unless @apis_files_paths
        @apis_files_paths = []
      end
      @apis_files_paths
    end

    def logger=(logger)
      @logger = logger
    end

    def logger
      unless @logger
        log = ::Logger.new(log_to)
        log.level    = normalize_log_level
        log.progname = 'ApiRecipes'
        @logger = log
      end

      @logger
    end

    def setup
      ApiRecipes._aprcps_define_global_apis
    end

    private

    # @private
    def normalize_log_level
      case @log_level
      when :debug, ::Logger::DEBUG, 'debug' then ::Logger::DEBUG
      when :info,  ::Logger::INFO,  'info'  then ::Logger::INFO
      when :warn,  ::Logger::WARN,  'warn'  then ::Logger::WARN
      when :error, ::Logger::ERROR, 'error' then ::Logger::ERROR
      when :fatal, ::Logger::FATAL, 'fatal' then ::Logger::FATAL
      else
        Logger::ERROR
      end
    end
  end
end
