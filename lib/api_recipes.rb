require 'http'
require 'oj'

require 'api_recipes/utils'
require 'api_recipes/exceptions'
require 'api_recipes/configuration'
require 'api_recipes/resource'
require 'api_recipes/endpoint'
require 'api_recipes/settings'

module ApiRecipes

  def self.included(receiver)

    def receiver.endpoint(endpoint_name, configs = {})
      unless endpoint_name.is_a?(String) || endpoint_name.is_a?(Symbol)
        raise ArgumentError, "endpoint name must be a Symbol or String"
      end

      if configs && !configs.is_a?(Hash)
        raise ApiRecipes::EndpointConfigIsNotAnHash.new(endpoint_name)
      end

      endpoint_name = endpoint_name.to_sym
      configs = ApiRecipes._aprcps_merge_endpoints_configs(endpoint_name, configs.deep_symbolize_keys)
      if self.respond_to? endpoint_name
        raise EndpointNameClashError.new(self, endpoint_name)
      else
        ApiRecipes._aprcps_storage[endpoint_name] = {}
        ApiRecipes._aprcps_storage[endpoint_name][self] = Endpoint.new(endpoint_name, configs)
        define_method endpoint_name do
          ApiRecipes._aprcps_storage[endpoint_name][self.class]
        end
        define_singleton_method endpoint_name do
          ApiRecipes._aprcps_storage[endpoint_name][self]
        end
      end
    end
  end

  def self.configuration
    unless @configuration
      @configuration = Configuration.new
    end
    @configuration
  end

  def self.configure
    if block_given?
      yield(configuration)
    else
      configuration
    end
  end

  def self.set_authorization_for_endpoint(authorization, endpoint_name)
    endpoint_name = endpoint_name.to_sym

    if _aprcps_storage[endpoint_name]
      _aprcps_storage[endpoint_name].each do |_, endpoint|
        endpoint.authorization = authorization
      end
    end
  end

  def self.set_basic_auth_for_endpoint(authorization, endpoint_name)
    endpoint_name = endpoint_name.to_sym

    if _aprcps_storage[endpoint_name]
      _aprcps_storage[endpoint_name].each do |_, endpoint|
        endpoint.basic_auth = authorization
      end
    end
  end

  def self._aprcps_define_global_endpoints
    configuration.endpoints_configs.each do |endpoint_name, endpoint_configs|
      endpoint_name = endpoint_name.to_sym
      unless method_defined? endpoint_name
        _aprcps_storage[:global][endpoint_name] = Endpoint.new endpoint_name, endpoint_configs
        define_singleton_method endpoint_name do
          _aprcps_storage[:global][endpoint_name]
        end
      end
    end
  end

  def self._aprcps_storage
    unless Thread.current[:api_recipes]
      Thread.current[:api_recipes] = { global: {} }
    end
    Thread.current[:api_recipes]
  end

  def self._aprcps_merge_endpoints_configs(endpoint_name, configs = nil)
    unless endpoint_name.is_a?(String) || endpoint_name.is_a?(Symbol)
      raise ArgumentError, "no enpoint_name provided. Given: #{endpoint_name.inspect}"
    end
    unless ApiRecipes.configuration.endpoints_configs[endpoint_name]
      ApiRecipes.configuration.endpoints_configs[endpoint_name] = {}
    end
    if configs
      ApiRecipes.configuration.endpoints_configs[endpoint_name].merge(configs) do |_, old_val, new_val|
        if new_val.nil?
          old_val
        else
          new_val
        end
      end
    else
      ApiRecipes.configuration.endpoints_configs[endpoint_name]
    end
  end
end

# Monkey-patch URI so it can accept dashed hostnames like "web-service-1"
module URI
  # Undef DEFAULT_PARSER
  URI.send(:remove_const, :DEFAULT_PARSER)

  # Redefine DEFAULT_PARSER
  DEFAULT_PARSER = Parser.new(HOSTNAME: "(?:(?:[a-zA-Z\\d](?:[-\\_a-zA-Z\\d]*[a-zA-Z\\d])?)\\.)*(?:[a-zA-Z](?:[-\\_a-zA-Z\\d]*[a-zA-Z\\d])?)\\.?")
end
