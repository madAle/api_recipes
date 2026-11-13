require 'spec_helper'

describe ApiRecipes do
  it 'has a version number' do
    expect(ApiRecipes::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end

  describe '.configure' do
    it 'yields the configuration and defines a method for each api' do
      yielded = nil
      ApiRecipes.configure do |config|
        yielded = config
        config.logger = Logger.new(IO::NULL)
        config.apis_configs = { svc: { host: 'api.example.test', endpoints: { users: nil } }, other: {} }
      end

      expect(yielded).to equal(ApiRecipes.configuration)
      expect(ApiRecipes.svc).to be_a(ApiRecipes::Api)
      expect(ApiRecipes.other).to be_a(ApiRecipes::Api)
    end

    it 'returns the configuration when no block is given' do
      expect(ApiRecipes.configure).to equal(ApiRecipes.configuration)
    end

    it 'returns the same global api at every call' do
      configure_test_apis
      expect(ApiRecipes.svc).to equal(ApiRecipes.svc)
    end

    it 'gives the ApiRecipes module to global apis as object' do
      configure_test_apis
      expect(ApiRecipes.svc.object).to equal(ApiRecipes)
    end
  end

  describe '.configuration' do
    it 'is created once' do
      expect(ApiRecipes.configuration).to be_a(ApiRecipes::Configuration)
      expect(ApiRecipes.configuration).to equal(ApiRecipes.configuration)
    end
  end

  describe '.logger' do
    it 'is the logger of the configuration' do
      logger = Logger.new(IO::NULL)
      ApiRecipes.configuration.logger = logger
      expect(ApiRecipes.logger).to equal(logger)
    end
  end
end
