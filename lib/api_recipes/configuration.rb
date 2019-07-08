module ApiRecipes
  class Configuration

    attr_accessor :log_to, :log_level

    def endpoints_configs=(configs = {})
      raise ArgumentError, 'endpoints_configs must be an Hash' unless configs.is_a? Hash
      @endpoints_configs = configs.deep_symbolize_keys
      ApiRecipes._aprcps_define_global_endpoints
    end

    def endpoints_configs
      unless @endpoints_configs
        @endpoints_configs = {}
      end
      @endpoints_configs
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
