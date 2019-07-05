require 'spec_helper'
require 'support/constants'
require 'yaml'

describe ApiRecipes do

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

  context 'when configuration is made' do
    describe "should define a method for each configured endpoint's name" do
      endpoints_configs = YAML.load_file(File.expand_path('spec/support/apis.yml'))

      before :all do
        ApiRecipes.configure do |config|
          config.endpoints_configs = endpoints_configs
        end
      end

      context 'E.g. given example configs, ApiRecipe' do
        endpoints_configs.each do |ep_name, _|
          it "is expected to define'#{ep_name}'" do
            expect(ApiRecipes).to respond_to ep_name
          end
        end
      end
    end
  end

  context "module is included into a class named '#{CLASS_NAME}'" do
    let(:klass) { Object.const_get CLASS_NAME }

    before :each do
      klass.send :include, ApiRecipes
    end

    it "should define 'endpoint' method on '#{CLASS_NAME}'" do
      expect(klass).to respond_to(:endpoint).with(1).argument
    end

    describe "an endpoint is defined on '#{CLASS_NAME}'" do
      let(:wrong_endpoint_name) { 1 }

      before do
        klass.send :endpoint, ENDPOINT_NAME
      end

      it 'should raise error if endpoint_name is not a string or symbol' do
        expect { klass.endpoint wrong_endpoint_name }.to raise_error(ArgumentError)
      end

      context "when defining '#{ENDPOINT_NAME}' endpoint" do
        context "'#{CLASS_NAME}' does not already define a method called '#{ENDPOINT_NAME}'" do
          it "should define a class method named '#{ENDPOINT_NAME}'" do
            expect(klass).to respond_to ENDPOINT_NAME
          end

          it "should define an instance method named '##{ENDPOINT_NAME}'" do
            expect(klass.new).to respond_to ENDPOINT_NAME
          end
        end

        context "'#{CLASS_NAME}' already defines a method called '#{ENDPOINT_NAME}'" do
          it 'should raise an error' do
            expect { klass.send :endpoint, ENDPOINT_NAME }.to raise_error(ApiRecipes::EndpointNameClashError)
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
