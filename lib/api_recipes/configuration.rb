module ApiRecipes
  class Configuration

    def endpoints_configs=(configs = {})
      raise ArgumentError, 'endpoints_configs must be an Hash' unless configs.is_a? Hash
      @endpoints_configs = configs.deep_symbolize_keys
    end

    def endpoints_configs
      unless @endpoints_configs
        @endpoints_configs = {}
      end
      @endpoints_configs
    end
  end
end
