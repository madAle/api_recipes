module ApiRecipes
  class Configuration

    attr_accessor :log_to, :log_level

    def apis_configs=(configs = {})
      raise ArgumentError, 'apis_configs must be an Hash' unless configs.is_a? Hash
      @apis_configs = configs.deep_symbolize_keys
      ApiRecipes._aprcps_define_global_apis
    end

    def apis_configs
      unless @apis_configs
        @apis_configs = {}
      end
      @apis_configs
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
