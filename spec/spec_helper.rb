$LOAD_PATH.unshift File.expand_path('../lib', __FILE__)

require 'bundler'
Bundler.require(:default, :test)

require 'api_recipes'

RSpec.configure do |config|

  config.before(:suite) do
  end

  config.after(:suite) do
  end

  config.before :each do
    # Remove CLASS_NAME definition
    Object.send(:remove_const, CLASS_NAME.to_s)
    # Re-define CLASS_NAME
    eval("class #{CLASS_NAME}; end")
  end

  config.order = :random
end
