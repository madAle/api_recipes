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

  module ClassMethods
    def endpoint(name, configs = {})
      configs = configs.deep_symbolize_keys
      name = name.to_sym

      ep = Endpoint.new(name, merge_endpoints_configs(name, configs))
      # Define 'name' method for the class
      define_class_endpoint ep
      # Define 'name' method for the class' instances
      define_instance_endpoint ep
    end

    private

    def define_class_endpoint(ep)
      name = ep.name
      unless method_defined? name
        Thread.current[name] = ep

        define_singleton_method name do
          Thread.current[name]
        end
      end
    end

    def define_instance_endpoint(ep)
      name = ep.name
      send :define_method, name do
        Thread.current[name].clone
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

