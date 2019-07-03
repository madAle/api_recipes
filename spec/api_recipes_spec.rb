require 'spec_helper'
require 'support/constants'
require 'yaml'

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

  context 'Module methods' do
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
        it 'should yield a Configuration object' do
          expect do |blk|
            ApiRecipes.configure &blk
          end.to yield_with_args ApiRecipes.configuration
        end
      end

      context 'when a block is NOT given' do
        it 'should return a Configuration object' do
          expect(ApiRecipes.configure).to be_a ApiRecipes::Configuration
        end
      end
    end

    describe '.configuration' do
      context 'on first call' do
        it 'should return a new Configuration object' do
          expect(ApiRecipes.configuration).to be_a ApiRecipes::Configuration
        end
      end

      context 'on subsequent calls' do
        let!(:config) { ApiRecipes.configuration }

        it 'should return the already initialized Configuration object' do
          expect(ApiRecipes.configuration).to eq config
        end
      end
    end
  end


  # Describe expected behaviour

  context 'When configuration is made first, ApiRecipes module' do
    endpoints_configs = YAML.load_file(File.expand_path('spec/support/apis.yml'))

    before :all do
      ApiRecipes.configure do |config|
        config.endpoints_configs = endpoints_configs
      end
    end

    describe "should define a method named as each defined endpoint's name" do
      context 'E.g. given example configs' do
        endpoints_configs.each do |ep_name, _|
          it "should define '#{ep_name}' method" do
            expect(ApiRecipes).to respond_to ep_name
          end
        end
      end
    end
  end




  # context 'ClassMethods' do
  #   describe '.endpoint' do
  #     it 'should call .define_class_endpoint' do
  #       expect(@klass).to receive :define_class_endpoint
  #       @klass.instance_eval { endpoint ENDPOINT_NAME }
  #     end
  #
  #     it 'should call .define_instance_endpoint' do
  #       expect(@klass).to receive :define_instance_endpoint
  #       @klass.instance_eval { endpoint ENDPOINT_NAME }
  #     end
  #   end
  #
  #   context 'private methods' do
  #     describe '.define_class_endpoint' do
  #       it 'should define a class method named as the endpoint name' do
  #         expect(@klass).to respond_to ENDPOINT_NAME
  #       end
  #     end
  #
  #     describe '.define_instance_endpoint' do
  #       it 'should define an instance method named as the endpoint name' do
  #         expect(@klass.new).to respond_to ENDPOINT_NAME
  #       end
  #     end
  #   end
  # end
end
