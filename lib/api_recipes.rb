require 'http'
require 'oj'

require 'api_recipes/utils'
require 'api_recipes/exceptions'
require 'api_recipes/configuration'
require 'api_recipes/resource'
require 'api_recipes/endpoint'
require 'api_recipes/settings'

module ApiRecipes

  def self.included(base)

    def base.endpoint(endpoint_name, configs = {})
      configs = ApiRecipes._aprcps_merge_endpoints_configs(endpoint_name, configs.deep_symbolize_keys)
      endpoint_name = endpoint_name.to_sym

      # Define 'endpoint_name' method for the class
      ApiRecipes._aprcps_define_class_endpoint endpoint_name, configs, self, true
      # Define 'endpoint_name' method for the class' instances
      ApiRecipes._aprcps_define_instance_endpoint endpoint_name, self
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
      _aprcps_define_global_endpoints
    else
      configuration
    end
  end

  def self._aprcps_define_global_endpoints
    configuration.endpoints_configs.each do |endpoint_name, endpoint_configs|
      unless method_defined? endpoint_name
        unless _aprcps_storage[endpoint_name]
          _aprcps_storage[endpoint_name] = Endpoint.new endpoint_name, endpoint_configs
        end
        define_singleton_method endpoint_name do
          _aprcps_storage[endpoint_name]
        end
      end
    end
  end

  def self._aprcps_storage
    unless Thread.current[:api_recipes]
      Thread.current[:api_recipes] = {}
    end
    Thread.current[:api_recipes]
  end


  def self._aprcps_define_class_endpoint(ep_name, configs, obj, overwrite)
    unless obj.method_defined? ep_name
      if overwrite
        ep = Endpoint.new(ep_name, configs)
      else
        ep = _aprcps_storage[ep_name]
      end
      obj.define_singleton_method ep_name do
        ep
      end
    end
  end

  def self._aprcps_define_instance_endpoint(ep_name, obj)
    obj.instance_eval do
      unless obj.method_defined? ep_name
        define_method ep_name do
          self.class.send ep_name
        end
      end
    end
  end

  def self._aprcps_merge_endpoints_configs(endpoint_name, configs)
    if configs && !configs.is_a?(Hash)
      raise ApiRecipes::EndpointConfigIsNotAnHash.new(endpoint_name)
    end
    unless ApiRecipes.configuration.endpoints_configs[endpoint_name]
      ApiRecipes.configuration.endpoints_configs[endpoint_name] = {}
    end
    ApiRecipes.configuration.endpoints_configs[endpoint_name].merge configs
  end
end

# Monkey-patch URI so it can accept dashed hostnames like "web-service-1"
module URI
  # Undef DEFAULT_PARSER
  URI.send(:remove_const, :DEFAULT_PARSER)

  # Redefine DEFAULT_PARSER
  DEFAULT_PARSER = Parser.new(HOSTNAME: "(?:(?:[a-zA-Z\\d](?:[-\\_a-zA-Z\\d]*[a-zA-Z\\d])?)\\.)*(?:[a-zA-Z](?:[-\\_a-zA-Z\\d]*[a-zA-Z\\d])?)\\.?")
end
