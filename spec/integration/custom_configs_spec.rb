require 'spec_helper'
require 'support/constants'
require 'yaml'

describe 'ApiRecipes global configuration' do
  let(:klass) { Object.const_get CLASS_NAME }

  context 'when no global config has been made' do

    before do
      klass.send :include, ApiRecipes
      klass.send :endpoint, ENDPOINT_NAME, CUSTOM_CONFIGS
    end

    it "is expected that Class##{ENDPOINT_NAME} returns an endpoint with only custom configs (no endpoints configured)" do
      expect(klass.send(ENDPOINT_NAME).configs).to include CUSTOM_CONFIGS
    end
  end

  context 'when a global config has been made' do
    endpoints_configs = YAML.load_file(File.expand_path('spec/support/apis.yml'))

    before :all do
      ApiRecipes.configure do |config|
        config.endpoints_configs = endpoints_configs
      end
    end

    before do
      klass.send :include, ApiRecipes
      klass.send :endpoint, ENDPOINT_NAME, CUSTOM_CONFIGS
    end

    it "is expected that Class#{ENDPOINT_NAME} returns an endpoint with merged configs (default + custom)" do
      expect(klass.send(ENDPOINT_NAME).configs).to include CUSTOM_CONFIGS
      expect(klass.send(ENDPOINT_NAME).configs).to eq endpoints_configs.deep_symbolize_keys[ENDPOINT_NAME].merge CUSTOM_CONFIGS
    end
  end
end
