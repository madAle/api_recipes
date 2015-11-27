$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)
require 'api_recipes'

#require "simplecov"
#SimpleCov.start

RSpec.configure do |config|

  config.before(:suite) do
  end

  config.after(:suite) do
  end

  config.order = :random
end
