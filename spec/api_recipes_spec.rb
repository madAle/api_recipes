require 'spec_helper'
require 'support/constants'

describe ApiRecipes do
  before :each do
    @klass = Class.new
    @klass.instance_eval do
      include ApiRecipes
      endpoint ENDPOINT_NAME
    end
  end

  it 'has a version number' do
    expect(ApiRecipes::VERSION).not_to be nil
  end

  context 'module methods' do
    describe '.configuration' do
      it 'should return an ApiRecipes::Configuration object' do
        expect(ApiRecipes.configuration).to be_a ApiRecipes::Configuration
      end

      it 'should define a variable named @configuration' do
        ApiRecipes.configuration
        expect(ApiRecipes.instance_variable_get :@configuration).to_not be_nil
      end
    end

    describe '.configure' do
      context 'when a block is given' do
        it 'should yield' do
          expect do |b|
            ApiRecipes.configure &b
          end.to yield_with_args ApiRecipes.configuration
        end
      end

      context 'when a block is NOT given' do
        it 'should return a Configuration object' do
          expect(ApiRecipes.configure).to be_a ApiRecipes::Configuration
        end
      end
    end
  end

  context 'ClassMethods' do
    describe '.endpoint' do
      it 'should call .define_class_endpoint' do
        expect(@klass).to receive :define_class_endpoint
        @klass.instance_eval { endpoint ENDPOINT_NAME }
      end

      it 'should call .define_instance_endpoint' do
        expect(@klass).to receive :define_instance_endpoint
        @klass.instance_eval { endpoint ENDPOINT_NAME }
      end
    end

    context 'private methods' do
      describe '.define_class_endpoint' do
        it 'should define a class method named as the endpoint name' do
          expect(@klass).to respond_to ENDPOINT_NAME
        end
      end

      describe '.define_instance_endpoint' do
        it 'should define an instance method named as the endpoint name' do
          expect(@klass.new).to respond_to ENDPOINT_NAME
        end
      end
    end
  end
end
