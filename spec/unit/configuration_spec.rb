require 'spec_helper'
require 'tmpdir'

describe ApiRecipes::Configuration do
  def fixture(name)
    File.expand_path("../fixtures/#{name}", __dir__)
  end

  def configure_files(*names)
    ApiRecipes.configure do |config|
      config.logger = Logger.new(IO::NULL)
      config.apis_files_paths = names.map { |name| fixture(name) }
    end
  end

  it 'loads apis from a YAML file evaluated with ERB' do
    configure_files('svc.yml.erb')
    expect(ApiRecipes.svc.users.url.to_s).to eq('https://api.example.test/users')
  end

  it 'lets a later file replace an api defined by an earlier one' do
    configure_files('svc.yml.erb', 'svc_override.yml')
    expect(ApiRecipes.svc.definition.host).to eq('other.example.test')
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
      config.apis_files_paths = [fixture('svc.yml.erb'), fixture('svc_override.yml')]
    end
  end

  it 'rejects apis_files_paths that are not an Array' do
    expect { ApiRecipes.configuration.apis_files_paths = fixture('svc.yml.erb') }.to raise_error(ArgumentError)
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

  it 'does not need the logger before the files' do
    logger = Logger.new(IO::NULL)
    expect(logger).to receive(:debug).with(/svc_override\.yml overrides config for 'svc'/)
    ApiRecipes.configure do |config|
      config.apis_files_paths = [fixture('svc.yml.erb'), fixture('svc_override.yml')]
      config.logger = logger
    end
  end

  it 'applies the sources in the order they are assigned' do
    ApiRecipes.configure do |config|
      config.logger = Logger.new(IO::NULL)
      config.apis_files_paths = [fixture('two_apis.yml')]
      config.apis_configs = { svc: { host: 'hash.example.test', endpoints: { users: nil } } }
    end
    expect(ApiRecipes.svc.users.url.to_s).to eq('https://hash.example.test/users')
    expect(ApiRecipes.billing.invoices.url.to_s).to eq('http://billing_service:3000/invoices')
  end

  it 'keeps the options between two calls to configure' do
    configure_files('svc.yml.erb')
    ApiRecipes.configure { |config| config.print_urls = false }
    expect(ApiRecipes.svc.users.url.to_s).to eq('https://api.example.test/users')
  end

  it 'reads no file before load' do
    configuration = ApiRecipes::Configuration.new
    configuration.apis_files_paths = [fixture('missing.yml')]
    expect { configuration.load }.to raise_error(ApiRecipes::RecipeFileError)
  end

  {
    'missing.yml' => /missing\.yml: file not found/,
    'empty.yml'   => /empty\.yml: file is empty/,
    'list.yml'    => /list\.yml: must contain a mapping/,
    'unsafe.yml'  => /unsafe\.yml: invalid YAML/
  }.each do |name, pattern|
    it "names the file when #{name} cannot be loaded" do
      expect { configure_files(name) }.to raise_error(ApiRecipes::RecipeFileError, pattern)
    end
  end

  describe 'files that are hard to read' do
    around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

    def write(name, content)
      File.binwrite(File.join(@dir, name), content)
      File.join(@dir, name)
    end

    def load_from(path)
      ApiRecipes.configure do |config|
        config.logger = Logger.new(IO::NULL)
        config.apis_files_paths = [path]
      end
    end

    it 'loads a file with non-ASCII UTF-8 text' do
      path = write('utf8.yml', "svc:\n  host: api.example.test\n  endpoints:\n    users: { path: 'café' }\n")
      expect { load_from(path) }.not_to raise_error
    end

    it 'names a file that is not valid UTF-8' do
      path = write('latin.yml', "svc: { host: \"caf\xE9\" }\n")
      expect { load_from(path) }.to raise_error(ApiRecipes::RecipeFileError, /latin\.yml: file is not valid UTF-8/)
    end

    it 'names a directory given as a file' do
      expect { load_from(@dir) }.to raise_error(ApiRecipes::RecipeFileError, /cannot read file \(EISDIR\)/)
    end

    it 'refuses a file with ERB when ERB is not asked for, and runs nothing' do
      marker = File.join(@dir, 'marker')
      path = write('erb.yml', "svc: { host: <%= File.write(#{marker.inspect}, '1') %> }\n")
      expect { ApiRecipes::Configuration.new.read_recipe_file(path, erb: false) }
        .to raise_error(ApiRecipes::RecipeFileError, /erb\.yml: contains ERB/)
      expect(File.exist?(marker)).to be(false)
    end

    it 'evaluates ERB with erb: true' do
      path = write('erb.yml', "svc: { host: <%= 'api.example.test' %> }\n")
      expect(ApiRecipes::Configuration.new.read_recipe_file(path, erb: true)).to eq(svc: { host: 'api.example.test' })
    end
  end

  describe 'shared recipes among the files' do
    let(:body) { "<% raise 'evaluated' %>\nsvc:\n  host: evil.test\n" }

    def expect_refused(path)
      expect do
        ApiRecipes.configure { |config| config.apis_files_paths = [path] }
      end.to raise_error(ApiRecipes::RecipeFileError, /recipes_paths/)
    end

    it 'refuses a shared recipe without evaluating its ERB' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'x.recipe.yml')
        File.write(path, body)
        expect_refused(path)
      end
    end

    it 'refuses a shared recipe whatever the letter case of the name' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'x.RECIPE.YML')
        File.write(path, body)
        expect_refused(path)
      end
    end

    it 'refuses a link that points to a shared recipe' do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'x.recipe.yml')
        link = File.join(dir, 'plain.yml')
        File.write(target, body)
        File.symlink(target, link)
        expect_refused(link)
      end
    end
  end

  it 'has defaults for variables and upgrade_warnings' do
    configuration = ApiRecipes::Configuration.new
    expect(configuration.variables).to eq({})
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

    it 'takes the default level from the LOG_LEVEL variable' do
      ENV['LOG_LEVEL'] = 'warn'
      configuration.log_to = StringIO.new
      expect(configuration.logger.level).to eq(Logger::WARN)
    ensure
      ENV.delete('LOG_LEVEL')
    end
  end
end
