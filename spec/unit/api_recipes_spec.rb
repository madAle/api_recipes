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

    it 'keeps the previous configuration, unchanged, when a new one fails' do
      configure_test_apis
      before = ApiRecipes.configuration
      logger = before.logger
      other_logger = Logger.new(IO::NULL)
      failures = [
        ->(config) { config.apis_configs = { svc: { bogus: 1 } } },
        ->(config) { config.apis_files_paths = [File.expand_path('../fixtures/missing.yml', __dir__)] },
        ->(config) { config.variables[:svc] = 'not a Hash' }
      ]
      failures.each do |change|
        expect do
          ApiRecipes.configure do |config|
            config.logger = other_logger
            config.print_urls = true
            change.call(config)
          end
        end.to raise_error(ApiRecipes::ConfigurationError)
        expect(ApiRecipes.configuration).to equal(before)
        expect([before.logger, before.print_urls, before.variables]).to eq([logger, false, {}])
        expect(before.apis_configs.keys).to eq(ApiRecipes.apis)
      end
      ApiRecipes.configure { |config| config.logger = other_logger }
      expect(ApiRecipes.logger).to equal(other_logger)
      expect(ApiRecipes.svc.users.url.to_s).to eq("#{base_url}/users")
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
