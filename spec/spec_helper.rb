require 'simplecov'
SimpleCov.start do
  add_filter '/spec/'
  # Enforced on CI only, so that running a single file locally does not fail.
  minimum_coverage 90 if ENV['CI']
end

require 'webmock/rspec'
require 'api_recipes'
require 'support/test_apis'

WebMock.disable_net_connect!

RSpec.configure do |config|
  config.include TestApis
  config.before(:each) { ApiRecipes.reset! }
  config.order = :random
end
