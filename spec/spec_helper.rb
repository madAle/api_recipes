require 'simplecov'
SimpleCov.start { add_filter '/spec/' }

require 'webmock/rspec'
require 'api_recipes'
require 'support/test_apis'

WebMock.disable_net_connect!

RSpec.configure do |config|
  config.include TestApis
  config.before(:each) { ApiRecipes.reset! }
  config.order = :random
end
