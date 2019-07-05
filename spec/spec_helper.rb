$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)

require 'bundler'
Bundler.require(:default, :test)

require 'api_recipes'

RSpec.configure do |config|

  config.before(:suite) do
  end

  config.after(:suite) do
  end

  config.before :each do
    if Module.const_defined?('ApiRecipes')
      Object.send(:remove_const, 'ApiRecipes')
      # Reloads the module and all other files
      load 'api_recipes.rb'
      Dir.glob('lib/api_recipes/**').each do |filename|
        load filename
      end
    end

    # Remove CLASS_NAME definition
    Object.send(:remove_const, CLASS_NAME.to_s)
    # Re-define CLASS_NAME
    eval("class #{CLASS_NAME}; end")
  end

  config.order = :random
end
