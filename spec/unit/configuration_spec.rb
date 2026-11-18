require 'spec_helper'
require 'tmpdir'
require 'rbconfig'

describe ApiRecipes::Configuration do
  it 'rejects apis_configs that are not a Hash' do
    expect { ApiRecipes.configuration.apis_configs = [] }.to raise_error(ArgumentError)
  end

  it 'has no apis and no recipes until configured' do
    expect(ApiRecipes.configuration.apis_configs).to eq({})
    expect(ApiRecipes.configuration.recipes_paths).to eq([])
  end

  it 'accepts apis_configs with String keys' do
    configure_test_apis('svc' => { 'host' => 'api.example.test', 'endpoints' => { 'users' => nil } })
    expect(ApiRecipes.configuration.apis_configs.keys).to eq([:svc])
    expect(ApiRecipes.svc.users.url.to_s).to eq('https://api.example.test/users')
  end

  it 'keeps the options between two calls to configure' do
    configure_test_apis('svc' => { 'host' => 'api.example.test', 'endpoints' => { 'users' => nil } })
    ApiRecipes.configure { |config| config.print_urls = false }
    expect(ApiRecipes.svc.users.url.to_s).to eq('https://api.example.test/users')
  end

  describe 'apis_files_paths, which 2.x had' do
    let(:message) { /\Aapis_files_paths was removed in 3\.0: an api is described by a portable recipe, loaded with recipes_paths\. Run `api_recipes convert`/ }

    it 'is refused when it is assigned, with the command that moves the files to recipes' do
      expect { ApiRecipes.configure { |config| config.apis_files_paths = ['config/apis/github.yml'] } }.to raise_error(ApiRecipes::Error, message)
      expect { ApiRecipes.configure { |config| config.apis_files_paths = [] } }.to raise_error(ApiRecipes::Error, message)
      expect(ApiRecipes.apis).to eq([])
    end

    it 'is refused when it is read, so that adding to it says the same' do
      expect { ApiRecipes.configure { |config| config.apis_files_paths += ['x.yml'] } }.to raise_error(ApiRecipes::Error, message)
    end

    it 'leaves the configuration in force as it was' do
      configure_test_apis
      expect { ApiRecipes.configure { |config| config.apis_files_paths = ['x.yml'] } }.to raise_error(ApiRecipes::Error)
      expect(ApiRecipes.apis).to include(:svc)
    end

    it 'loads no file and does not need ERB' do
      expect(described_class.instance_methods).not_to include(:read_recipe_file)
      loaded = `#{RbConfig.ruby} -I#{File.expand_path('../../lib', __dir__)} -e 'require "api_recipes"; print defined?(ERB).inspect'`
      expect(loaded).to eq('nil')
    end
  end

  it 'has defaults for values and upgrade_warnings' do
    configuration = ApiRecipes::Configuration.new
    expect(configuration.value_levels).to be_nil
    expect { configuration.values = { svc: { authorization: 'Bearer x' } } }
      .to raise_error(ApiRecipes::Error, 'values are given inside the block of ApiRecipes.configure, as config.values = { ... }')
    expect(configuration.value_levels).to be_nil
    expect(configuration.upgrade_warnings).to eq(true)
  end

  describe 'logger' do
    let(:configuration) { ApiRecipes::Configuration.new }

    around do |example|
      saved = ENV.delete('LOG_LEVEL')
      example.run
      ENV['LOG_LEVEL'] = saved if saved
    end

    it 'uses the logger it is given' do
      logger = Logger.new(IO::NULL)
      configuration.logger = logger
      expect(configuration.logger).to equal(logger)
    end

    it 'builds a logger named ApiRecipes at warn level by default' do
      configuration.log_to = StringIO.new
      expect(configuration.logger.level).to eq(Logger::WARN)
      expect(configuration.logger.progname).to eq('ApiRecipes')
    end

    it 'writes to log_to when it is an IO' do
      io = StringIO.new
      configuration.log_to = io
      configuration.logger.warn('hello')
      expect(io.string).to include('hello')
    end

    it 'writes to log_to when it is a path' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'api_recipes.log')
        configuration.log_to = path
        configuration.logger.warn('hello')
        configuration.logger.close
        expect(File.read(path)).to include('hello')
      end
    end

    it 'writes to STDERR by default' do
      expect { configuration.logger.warn('hello') }.to output(/hello/).to_stderr_from_any_process
    end

    {
      debug: Logger::DEBUG, info: Logger::INFO, warn: Logger::WARN, error: Logger::ERROR, fatal: Logger::FATAL
    }.each do |name, level|
      it "accepts log_level #{name} as a Symbol, a String or a Logger constant" do
        [name, name.to_s, level].each do |value|
          config = ApiRecipes::Configuration.new
          config.log_to = StringIO.new
          config.log_level = value
          expect(config.logger.level).to eq(level)
        end
      end
    end

    it 'lowers the default level to info with print_urls when no level was chosen' do
      configuration.log_to = StringIO.new
      configuration.print_urls = true
      expect(configuration.logger.level).to eq(Logger::INFO)
    end

    it 'keeps the chosen level with print_urls' do
      configuration.log_to = StringIO.new
      configuration.print_urls = true
      configuration.log_level = :error
      expect(configuration.logger.level).to eq(Logger::ERROR)
    end

    it 'keeps the level of LOG_LEVEL with print_urls' do
      ENV['LOG_LEVEL'] = 'error'
      configuration.log_to = StringIO.new
      configuration.print_urls = true
      expect(configuration.logger.level).to eq(Logger::ERROR)
    ensure
      ENV.delete('LOG_LEVEL')
    end

    it 'ignores a LOG_LEVEL that is not a level, as if it was not set' do
      ENV['LOG_LEVEL'] = 'bogus'
      configuration.log_to = StringIO.new
      expect(configuration.logger.level).to eq(Logger::WARN)
      configuration.print_urls = true
      expect(configuration.logger.level).to eq(Logger::INFO)
    ensure
      ENV.delete('LOG_LEVEL')
    end

    it 'honours LOG_LEVEL in any letter case' do
      { 'debug' => Logger::DEBUG, 'DEBUG' => Logger::DEBUG, 'Info' => Logger::INFO, 'ERROR' => Logger::ERROR }
        .each do |value, level|
        ENV['LOG_LEVEL'] = value
        config = ApiRecipes::Configuration.new
        config.log_to = StringIO.new
        expect(config.logger.level).to eq(level)
      end
    ensure
      ENV.delete('LOG_LEVEL')
    end

    it 'takes the default level from the LOG_LEVEL variable' do
      ENV['LOG_LEVEL'] = 'warn'
      configuration.log_to = StringIO.new
      expect(configuration.logger.level).to eq(Logger::WARN)
    ensure
      ENV.delete('LOG_LEVEL')
    end
  end
end
