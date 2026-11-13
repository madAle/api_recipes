require 'spec_helper'

describe ApiRecipes::Configuration do
  def configure_files(*names)
    ApiRecipes.configure do |config|
      config.logger = Logger.new(IO::NULL)
      config.apis_files_paths = names.map { |name| "spec/fixtures/#{name}" }
    end
  end

  it 'loads apis from a YAML file evaluated with ERB' do
    configure_files('svc.yml.erb')
    expect(ApiRecipes.svc.users.url.to_s).to eq('https://api.example.test/users')
  end

  it 'lets a later file replace an api defined by an earlier one' do
    configure_files('svc.yml.erb', 'svc_override.yml')
    expect(ApiRecipes.svc.configs[:host]).to eq('other.example.test')
    expect(ApiRecipes.svc).not_to respond_to(:users)
    expect(ApiRecipes.svc).to respond_to(:ping)
  end

  it 'rejects apis_configs that are not a Hash' do
    expect { ApiRecipes.configuration.apis_configs = [] }.to raise_error(ArgumentError)
  end

  it 'loads several apis from one file' do
    configure_files('two_apis.yml')
    expect(ApiRecipes.svc.users.url.to_s).to eq('https://api.example.test/users')
    expect(ApiRecipes.billing.invoices.url.to_s).to eq('http://billing_service:3000/invoices')
  end

  it 'logs when a file replaces an api that is already configured' do
    logger = Logger.new(IO::NULL)
    expect(logger).to receive(:debug).with(/svc_override\.yml overrides config for 'svc'/)
    ApiRecipes.configure do |config|
      config.logger = logger
      config.apis_files_paths = ['spec/fixtures/svc.yml.erb', 'spec/fixtures/svc_override.yml']
    end
  end

  it 'rejects apis_files_paths that are not an Array' do
    expect { ApiRecipes.configuration.apis_files_paths = 'spec/fixtures/svc.yml.erb' }.to raise_error(ArgumentError)
  end

  it 'has no files and no apis until configured' do
    expect(ApiRecipes.configuration.apis_files_paths).to eq([])
    expect(ApiRecipes.configuration.apis_configs).to eq({})
  end

  it 'accepts apis_configs with String keys' do
    configure_test_apis('svc' => { 'host' => 'api.example.test', 'endpoints' => { 'users' => nil } })
    expect(ApiRecipes.configuration.apis_configs.keys).to eq([:svc])
    expect(ApiRecipes.svc.users.url.to_s).to eq('https://api.example.test/users')
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

    it 'builds a logger named ApiRecipes at debug level by default' do
      configuration.log_to = StringIO.new
      expect(configuration.logger.level).to eq(Logger::DEBUG)
      expect(configuration.logger.progname).to eq('ApiRecipes')
    end

    it 'writes to log_to' do
      io = StringIO.new
      configuration.log_to = io
      configuration.logger.warn('hello')
      expect(io.string).to include('hello')
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

    it 'takes the default level from the LOG_LEVEL variable' do
      ENV['LOG_LEVEL'] = 'warn'
      configuration.log_to = StringIO.new
      expect(configuration.logger.level).to eq(Logger::WARN)
    ensure
      ENV.delete('LOG_LEVEL')
    end
  end

  describe 'print_urls' do
    it 'prints each url to STDOUT when it is built' do
      configure_test_apis
      ApiRecipes.configuration.print_urls = true
      expect { ApiRecipes.svc.users.url }.to output("https://api.example.test/users\n").to_stdout
    end

    it 'prints nothing by default' do
      configure_test_apis
      expect { ApiRecipes.svc.users.url }.not_to output.to_stdout
    end
  end
end
