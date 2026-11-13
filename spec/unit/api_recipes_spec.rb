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
      ApiRecipes.configure do |config|
        config.logger = Logger.new(IO::NULL)
        config.apis_configs = { svc: { host: 'hash.example.test', endpoints: { users: nil } } }
        config.apis_files_paths = [File.expand_path('../fixtures/svc_override.yml', __dir__)]
      end
      before = ApiRecipes.configuration
      logger = before.logger
      other_logger = Logger.new(IO::NULL)
      # The last one would also reorder the sources of the previous configuration if they were shared.
      failures = [
        ->(config) { config.apis_files_paths = [File.expand_path('../fixtures/missing.yml', __dir__)] },
        ->(config) { config.variables[:svc] = 'not a Hash' },
        ->(config) { config.apis_configs = { svc: { bogus: 1 } } }
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
      expect(ApiRecipes.svc.ping.url.to_s).to eq('https://other.example.test/ping')
    end

    it 'keeps the previous configuration when a failed configure changed what it holds in place' do
      logger = Logger.new(IO::NULL)
      path = File.expand_path('../fixtures/two_apis.yml', __dir__)
      ApiRecipes.configure do |config|
        config.logger = logger
        config.apis_files_paths = [path.dup]
        config.apis_configs = { svc: { host: 'api.example.test', endpoints: { users: { path: '/people' } } } }
        config.variables = { svc: { region: 'eu' } }
      end
      before = ApiRecipes.configuration
      failures = [
        ->(config) { config.apis_configs[:svc][:bogus] = 1 },
        lambda do |config|
          config.apis_configs[:svc][:endpoints][:users][:path].replace('/evil')
          config.variables[:svc] = 1
        end,
        lambda do |config|
          config.variables[:svc][:region] = 'us'
          config.apis_configs[:svc][:host] = 1
        end,
        ->(config) { config.apis_files_paths.first.replace('missing.yml') }
      ]
      failures.each do |change|
        expect { ApiRecipes.configure { |config| change.call(config) } }.to raise_error(ApiRecipes::ConfigurationError)
      end
      expect(before.apis_configs).to eq(svc: { host: 'api.example.test', endpoints: { users: { path: '/people' } } })
      expect([before.apis_files_paths, before.variables]).to eq([[path], { svc: { region: 'eu' } }])
      shared = nil
      ApiRecipes.configure { |config| shared = config.logger }
      expect(shared).to equal(logger)
      expect(ApiRecipes.svc.users.url.to_s).to eq('https://api.example.test/people')
      expect(ApiRecipes.svc.variables).to eq(region: 'eu')
      expect(ApiRecipes.apis).to contain_exactly(:svc, :billing)
    end
  end

  describe 'concurrent calls' do
    def configure_host(host)
      ApiRecipes.configure do |config|
        config.logger = Logger.new(IO::NULL)
        config.apis_configs = { svc: { host: host, endpoints: { users: nil } } }
      end
    end

    # Runs call in a thread that stops right after the registry method
    # returns, runs other meanwhile, then lets the thread finish.
    def interleave(registry_method, call, other)
      stopped = Queue.new
      resume = Queue.new
      allow(ApiRecipes::Registry).to receive(registry_method).and_wrap_original do |original, *args, &block|
        result = original.call(*args, &block)
        if Thread.current[:api_recipes_spec_stop]
          stopped << true
          resume.pop
        end
        result
      end
      thread = Thread.new do
        Thread.current[:api_recipes_spec_stop] = true
        call.call
      end
      stopped.pop
      other.call
      resume << true
      thread.join
    end

    it 'pairs the configuration with the registry built from it when two configure calls overlap' do
      interleave(:install, -> { configure_host('one.example.test') }, -> { configure_host('two.example.test') })
      expect(ApiRecipes.svc.users.url.to_s).to eq('https://two.example.test/users')
      expect(ApiRecipes.configuration.apis_configs[:svc][:host]).to eq('two.example.test')
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
