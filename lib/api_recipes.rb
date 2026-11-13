# frozen_string_literal: true

require 'http'

require 'api_recipes/errors'
require 'api_recipes/core/credential'
require 'api_recipes/core/level'
require 'api_recipes/core/path_template'
require 'api_recipes/core/template'
require 'api_recipes/core/definition'
require 'api_recipes/core/compiler'
require 'api_recipes/core/context'
require 'api_recipes/core/request'
require 'api_recipes/response'
require 'api_recipes/configuration'
require 'api_recipes/api'
require 'api_recipes/endpoint'
require 'api_recipes/core/handles'
require 'api_recipes/core/registry'
require 'api_recipes/core/declaration'

module ApiRecipes
  # `include ApiRecipes` adds the class macro `api`. options is a positional
  # Hash, so that `api :github, host: 'x'` works; besides the api options it
  # takes `as` (the name of the method) and `variables` (values for the level
  # of the class).
  def self.included(receiver)
    def receiver.api(name, options = {})
      Core::Declaration.declare(self, name, options)
    end
  end

  # Yields a copy of the configuration, then loads and compiles it. The copy
  # becomes the configuration only if that succeeds, together with the apis
  # built from it: otherwise the previous configuration and apis stay as they
  # were. Without a block, returns the configuration.
  def self.configure
    return configuration unless block_given?

    draft = configuration.dup
    yield draft
    Core::Registry.install(draft) { @configuration = draft }
    nil
  end

  def self.configuration
    @configuration ||= Configuration.new
  end

  # The global api called name, for any name.
  def self.[](name)
    key = name.is_a?(String) && name.valid_encoding? ? name.to_sym : name
    Core::Registry.current.global(key) || raise(UnknownEndpoint.new('ApiRecipes', name, apis))
  end

  def self.apis = Core::Registry.current.apis

  # Removes the global apis and their methods, the configuration and every
  # credential and variable value.
  def self.reset!
    Core::Registry.reset! { @configuration = nil }
    nil
  end

  def self.logger
    configuration.logger
  end
end
