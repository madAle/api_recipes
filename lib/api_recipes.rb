require 'oj'
require 'oj_mimic_json'
require 'http'
require 'active_support/core_ext/hash/indifferent_access'
require 'active_support/core_ext/hash/keys'
require 'active_support/core_ext/array/extract_options'

require 'api_recipes/exceptions'
require 'api_recipes/configuration'
require 'api_recipes/resource'
require 'api_recipes/endpoint'
require 'api_recipes/settings'

module ApiRecipes

  def self.included(base)
    base.send :include, InstanceAndClassMethods
    base.extend ClassMethods
    base.extend InstanceAndClassMethods
  end

  class << self
    attr_accessor :configuration
  end

  def self.configure
    if block_given?
      yield(configuration)
    else
      configuration
    end
  end

  def self.configuration
    unless @configuration
      @configuration = Configuration.new
    end
    @configuration
  end

  module ClassMethods
    def endpoint(name, configs = {})
      configs = configs.deep_symbolize_keys
      name = name.to_sym

      # Define 'name' method for the class
      define_class_endpoint name, configs
      # Define 'name' method for the class' instances
      define_instance_endpoint name, configs
    end

    private

    def define_class_endpoint(endpoint_name, configs)
      class_var = :@@ep

      ep = Endpoint.new(endpoint_name, merge_endpoints_configs(endpoint_name, configs))
      # class_var is an hash mapping endpoint names with Endpoint instances
      # e.g { :endpoint_1 => #<ApiRecipes::Endpoint:0x007f9069cd9be0> }
      if class_variable_defined?(class_var) && endpoints = class_variable_get(class_var)
        # Update the class variable with new endpoints settings
        endpoints[endpoint_name] = ep
      else
        # Define class variable
        class_variable_set class_var, { endpoint_name => ep }
      end

      define_singleton_method endpoint_name do
        class_variable_get(class_var)[endpoint_name]
      end
    end

    def define_instance_endpoint(endpoint_name, configs)
      instance_var = :@ep

      ep = Endpoint.new(endpoint_name, merge_endpoints_configs(endpoint_name, configs))
      send :define_method, endpoint_name do
        # instance_var is an hash mapping endpoint names with Endpoint instances
        # e.g { :endpoint_1 => #<ApiRecipes::Endpoint:0x007f9069cd9be0> }
        if instance_variable_defined?(instance_var) && endpoints = instance_variable_get(instance_var)
          unless endpoints[endpoint_name]
            # Create/replace the associated key
            endpoints[endpoint_name] = ep
          end
          return endpoints[endpoint_name]
        else
          # Define instance variable
          instance_variable_set instance_var, { endpoint_name => ep }
        end
        ep
      end
    end
  end

  module InstanceAndClassMethods

    private

    def merge_endpoints_configs(endpoint, configs)
      if configs && !configs.is_a?(Hash)
        raise EndpointConfigIsNotAnHash.new(endpoint)
      end
      unless ApiRecipes.configuration.endpoints_configs[endpoint]
        ApiRecipes.configuration.endpoints_configs[endpoint] = {}
      end
      ApiRecipes.configuration.endpoints_configs[endpoint].merge! configs
      ApiRecipes.configuration
    end
  end
end

