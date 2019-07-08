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

  describe '._aprcps_define_global_endpoints' do
    endpoints_configs = YAML.load_file(File.expand_path('spec/support/apis.yml'))

    before do
      ApiRecipes.configure do |config|
        config.endpoints_configs = endpoints_configs
      end
    end

    it "should define a method for each configured endpoint's name" do
      endpoints_configs.each do |ep_name, _|
        expect(ApiRecipes).to respond_to ep_name
      end
    end
  end

  describe '._aprcps_global_storage' do
    context 'on first call' do
      it 'should init ApiRecipes storage as an Hash' do
        expect { ApiRecipes._aprcps_global_storage }.to change { ApiRecipes.instance_variable_get :@storage }.from(nil).to(Hash)
      end
    end

    it 'should return an Hash' do
      expect(ApiRecipes._aprcps_global_storage).to be_a(Hash)
    end
  end

  describe '._aprcps_merge_endpoints_configs' do
    context 'when a configuration has been made' do
      endpoints_configs = YAML.load_file(File.expand_path('spec/support/apis.yml'))

      before do
        ApiRecipes.configure do |config|
          config.endpoints_configs = endpoints_configs
        end
      end

      context 'and provided params are NOT OK' do
        context "when 'endpoint_name' param is NOT a String or Symbol" do
          it 'is expectec to raise an error' do
            expect { ApiRecipes._aprcps_merge_endpoints_configs(nil, {}) }.to raise_error(ArgumentError)
          end
        end
      end

      context 'and provided params are OK' do
        context "when 'config' param is nil" do
          it 'is expected to return only configured endpoint configs' do
            expect(ApiRecipes._aprcps_merge_endpoints_configs(ENDPOINT_NAME, nil)).to eq ApiRecipes.configuration.endpoints_configs[ENDPOINT_NAME]
          end
        end

        context "when 'config' param is and empty Hash {}" do
          it 'is expected to return only configured endpoint configs' do
            expect(ApiRecipes._aprcps_merge_endpoints_configs(ENDPOINT_NAME, nil)).to eq ApiRecipes.configuration.endpoints_configs[ENDPOINT_NAME]
          end
        end

        context "when 'endpoint_name' params is a String or a Symbol" do
          it 'should return an Hash' do
            expect(ApiRecipes._aprcps_merge_endpoints_configs(ENDPOINT_NAME.to_s, nil)).to be_a(Hash)
            expect(ApiRecipes._aprcps_merge_endpoints_configs(ENDPOINT_NAME.to_sym, nil)).to be_a(Hash)
          end
        end

        context "when 'config' param is a non-empty Hash" do
          let(:configs) { CUSTOM_CONFIGS }

          it 'should return the merge of configured enpoint configs and provided ones' do
            expect(ApiRecipes._aprcps_merge_endpoints_configs(ENDPOINT_NAME, configs)).to eq ApiRecipes.configuration.endpoints_configs[ENDPOINT_NAME].merge(configs)
          end

          it "is expected to not overwrite keys not present in 'config'" do
            expect(ApiRecipes._aprcps_merge_endpoints_configs(ENDPOINT_NAME, configs)[:routes]).to_not be_nil
          end
        end
      end
    end
  end

  # Describe expected behaviour

  context "module is included into a class named '#{CLASS_NAME}'" do
    let(:klass) { Object.const_get CLASS_NAME }

    before do
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
end
