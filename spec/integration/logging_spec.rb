describe 'Logging' do
  let(:io) { StringIO.new }
  let(:json) { { 'Content-Type' => 'application/json' } }

  def configure(**options)
    log = io
    ApiRecipes.configure do |config|
      config.log_to = log
      options.each { |key, value| config.public_send("#{key}=", value) }
      config.apis_configs = { svc: { host: 'api.example.test', auth: { type: 'query', name: 'key' },
                                     endpoints: { users: { endpoints: { show: { path: '/:id' } } } } } }
    end
    stub_request(:any, /example\.test/).to_return(status: 200, body: '{"secret":"BODY"}', headers: json)
    ApiRecipes.svc.authorization = 'TOKEN'
  end

  it 'is silent by default' do
    configure
    ApiRecipes.svc.users.show(7).url
    ApiRecipes.svc.users.show(7).run
    expect(io.string).to eq('')
  end

  it 'logs the url once per request with print_urls, never for intermediate nodes' do
    configure(print_urls: true)
    ApiRecipes.svc.users.show(7, params: { page: 2 }).run
    expect(io.string.scan('https://api.example.test/users').size).to eq(1)
    expect(io.string).to include('https://api.example.test/users/7')
  end

  it 'logs verb, url, status and duration at debug level, and nothing secret' do
    configure(log_level: :debug)
    ApiRecipes.svc.users.show(7, params: { page: 2 }, headers: { 'X-Private' => 'HEADER' }).run
    expect(io.string).to match(%r{GET https://api\.example\.test/users/7 -> 200 \(\d+(\.\d+)?ms\)})
    %w[TOKEN BODY HEADER page=2 key=].each { |secret| expect(io.string).not_to include(secret) }
  end

  it 'warns once per endpoint about a slash or an encoded value, without the value' do
    configure
    2.times { ApiRecipes.svc.users.show('private/value').url }
    ApiRecipes.svc.users.show('a%2Fb').url
    expect(io.string.scan("svc.users.show: the value of 'id' contains '/'").size).to eq(1)
    expect(io.string).to include('looks already percent-encoded')
    expect(io.string).not_to include('private')
  end

  it 'can turn the upgrade warnings off' do
    configure(upgrade_warnings: false)
    ApiRecipes.svc.users.show('a/b').url
    expect(io.string).to eq('')
  end

  it 'uses the exact messages' do
    configure
    ApiRecipes.svc.users.show('a/b').url
    ApiRecipes.svc.users.show('a%2Fb').url
    expect(io.string).to include("svc.users.show: the value of 'id' contains '/' and is now sent as %2F. " \
                                 'To span several segments use *id in the path.')
    expect(io.string).to include("svc.users.show: the value of 'id' looks already percent-encoded. " \
                                 'ApiRecipes now encodes path parameters itself.')
  end

  it 'does not warn about a splat value that spans segments' do
    log = io
    ApiRecipes.configure do |config|
      config.log_to = log
      config.apis_configs = { svc: { host: 'api.example.test', endpoints: { files: { path: '/*rest' } } } }
    end
    ApiRecipes.svc.files('a/b/c').url
    expect(io.string).to eq('')
  end

  it 'cannot be forged by a value with a line break' do
    configure(log_level: :debug)
    ApiRecipes.svc.users.show("x\nFORGED line/").run
    lines = io.string.lines
    expect(lines.size).to eq(2)
    expect(lines.first).to include("contains '/'")
    expect(lines.last).to match(%r{GET https://api\.example\.test/users/x%0AFORGED%20line%2F -> 200})
  end

  it 'detects a slash and an encoded sequence in a value that is not valid UTF-8' do
    configure
    ApiRecipes.svc.users.show("\xff/".dup.force_encoding('UTF-8')).url
    expect(io.string).to include("contains '/'")
    expect(io.string).not_to include('percent-encoded')
    io.truncate(0)
    io.rewind
    ApiRecipes.svc.users.show("\xff%41".dup.force_encoding('UTF-8')).url
    expect(io.string).to include('looks already percent-encoded')
    expect(io.string).not_to include("contains '/'")
  end

  it 'does not take a lone percent sign for an encoded value' do
    configure
    ApiRecipes.svc.users.show('100%').url
    ApiRecipes.svc.users.show('%4').url
    expect(io.string).to eq('')
  end

  it 'warns about an encoded sequence in a splat value' do
    log = io
    ApiRecipes.configure do |config|
      config.log_to = log
      config.apis_configs = { svc: { host: 'api.example.test', endpoints: { files: { path: '/*rest' } } } }
    end
    ApiRecipes.svc.files('a/b%41/c').url
    expect(io.string).to include("svc.files: the value of 'rest' looks already percent-encoded")
  end

  it 'leaves the level and the output of a logger given by the application alone' do
    log = Logger.new(io, level: Logger::ERROR)
    ApiRecipes.configure do |config|
      config.logger = log
      config.print_urls = true
      config.apis_configs = { svc: { host: 'api.example.test', endpoints: { users: { path: '/:id' } } } }
    end
    stub_request(:any, /example\.test/).to_return(status: 200)
    ApiRecipes.svc.users(7).run
    expect(log.level).to eq(Logger::ERROR)
    expect(io.string).to eq('')
  end

  it 'works with a logger that only has debug, info and warn' do
    calls = []
    custom = Object.new
    %i[debug info warn].each { |level| custom.define_singleton_method(level) { |message| calls << [level, message] } }
    ApiRecipes.configure do |config|
      config.logger = custom
      config.print_urls = true
      config.apis_configs = { svc: { host: 'api.example.test', endpoints: { users: { path: '/:id' } } } }
    end
    stub_request(:any, /example\.test/).to_return(status: 200)
    ApiRecipes.svc.users('a/b').run
    expect(calls.map(&:first)).to eq(%i[warn info debug])
  end
end
