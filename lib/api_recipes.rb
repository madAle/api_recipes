require 'http'

require 'api_recipes/utils'
require 'api_recipes/exceptions'
require 'api_recipes/configuration'
require 'api_recipes/route'
require 'api_recipes/endpoint'
require 'api_recipes/api'
require 'api_recipes/response'
require 'api_recipes/settings'

# TODO: Sistema i default nelle config

module ApiRecipes

  def self.included(receiver)

    def receiver.api(api_name, configs = {})
      unless api_name.is_a?(String) || api_name.is_a?(Symbol)
        raise ArgumentError, "api name must be a Symbol or String"
      end

      if configs && !configs.is_a?(Hash)
        raise ApiRecipes::ApiConfigIsNotAnHash.new(api_name)
      end

      api_name = api_name.to_sym
      # configs = ApiRecipes._aprcps_merge_apis_configs(api_name, configs.deep_symbolize_keys)
      if self.respond_to? api_name
        raise ApiNameClashError.new(self, api_name)
      else

        define_method api_name do
          configs = ApiRecipes._aprcps_merge_apis_configs(api_name, configs.deep_symbolize_keys)
          api = Api.new(api_name, configs, self)
          ApiRecipes.copy_global_authorizations_to_api api
          api
        end
        define_singleton_method api_name do
          configs = ApiRecipes._aprcps_merge_apis_configs(api_name, configs.deep_symbolize_keys)
          api = Api.new(api_name, configs, self)
          ApiRecipes.copy_global_authorizations_to_api api
          api
        end
      end
    end
  end

  def self.print_urls=(value)
    @print_urls = value
  end

  def self.print_urls
    @print_urls || false
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
      configuration.setup
    else
      configuration
    end
  end

  def self.copy_global_authorizations_to_api(api)
    if _aprcps_global_storage[api.name]
      if auth = _aprcps_global_storage[api.name].basic_auth
        api.basic_auth = auth
      end
      if auth = _aprcps_global_storage[api.name].authorization
        api.authorization = auth
      end
    end
  end

  def self.set_authorization_for_api(authorization, api_name)
    api_name = api_name.to_sym

    # Set authorization on thread storage
    if _aprcps_thread_storage[api_name]
      _aprcps_thread_storage[api_name].each do |_, api|
        api.authorization = authorization
      end
    end
  end

  def self.set_basic_auth_for_api(basic_auth, api_name)
    api_name = api_name.to_sym

    # Set authorization on thread storage
    if _aprcps_thread_storage[api_name]
      _aprcps_thread_storage[api_name].each do |_, api|
        api.authorization = basic_auth
      end
    end
  end

  def self._aprcps_define_global_apis
    configuration.apis_configs.each do |api_name, api_configs|
      api_name = api_name.to_sym
      _aprcps_global_storage[api_name] = Api.new api_name, api_configs, self
      define_singleton_method api_name do
        _aprcps_global_storage[api_name]
      end
    end
  end

  def self._aprcps_global_storage
    unless @storage
      @storage = {}
    end

    @storage
  end

  def self._aprcps_thread_storage
    unless Thread.current[:api_recipes]
      Thread.current[:api_recipes] = {}
    end
    Thread.current[:api_recipes]
  end

  def self._aprcps_merge_apis_configs(api_name, configs = nil)
    unless api_name.is_a?(String) || api_name.is_a?(Symbol)
      raise ArgumentError, "no api_name provided. Given: #{api_name.inspect}"
    end
    global_api_configs = _aprcps_global_storage[api_name]&.configs || {}
    if configs
      global_api_configs.deep_merge(configs) do |_, old_val, new_val|
        if new_val.nil?
          old_val
        else
          new_val
        end
      end
    else
      global_api_configs
    end
  end

  def self.logger
    configuration.logger
  end
end

# Monkey-patch URI so it can accept dashed hostnames like "web-service-1"
module URI
  # Undef DEFAULT_PARSER
  URI.send(:remove_const, :DEFAULT_PARSER)

  # Redefine DEFAULT_PARSER
  DEFAULT_PARSER = Parser.new(HOSTNAME: "(?:(?:[a-zA-Z\\d](?:[-\\_a-zA-Z\\d]*[a-zA-Z\\d])?)\\.)*(?:[a-zA-Z](?:[-\\_a-zA-Z\\d]*[a-zA-Z\\d])?)\\.?")
end
