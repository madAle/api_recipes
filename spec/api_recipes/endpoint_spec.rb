require 'spec_helper'
require 'support/constants'

module ApiRecipes
  describe Endpoint do
    before :each do
      @klass = Class.new
      @klass.instance_eval do
        include ApiRecipes
        endpoint ENDPOINT_NAME
      end
    end

    describe '.initialize' do

    end
  end
end
