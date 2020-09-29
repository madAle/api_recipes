require 'spec_helper'
require 'support/constants'
require 'yaml'

describe 'ApiRecipes global configuration' do

  apis_configs = YAML.load_file(File.expand_path('spec/support/apis.yml'))

  before do
    ApiRecipes.configure do |config|
      config.apis_configs = apis_configs
    end

    class Foo
      include ApiRecipes

      endpoint ENDPOINT_NAME

      def self.global_access_test
        ApiRecipes.send ENDPOINT_NAME
      end
    end

    class Bar
      include ApiRecipes

      def self.global_access_test
        ApiRecipes.send ENDPOINT_NAME
      end
    end

    class FooBar
    end
  end

  after do
    Object.send :remove_const, 'Foo'
    Object.send :remove_const, 'Bar'
    Object.send :remove_const, 'FooBar'
  end

  it 'is expected that Foo can access ApiRecipes global endpoints' do
    expect { Foo.global_access_test }.to_not raise_error
  end

  it 'is expected that Bar can access ApiRecipes global endpoints' do
    expect { Bar.global_access_test }.to_not raise_error
  end

  it 'is expected that FooBar CAN NOT access ApiRecipes global endpoints' do
    expect { FooBar.global_access_test }.to raise_error(NoMethodError)
  end
end
