require 'spec_helper'

# A secret placed in every possible place of a request never reaches a log.
describe 'Logging through the DSL' do
  let(:io) { StringIO.new }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:secrets) { %w[SECRET-TOKEN SECRET-USER SECRET-PASS SECRET-HEADER SECRET-DEFAULT SECRET-PARAM SECRET-BODY SECRET-COOKIE] }

  def configure(auth, **settings)
    log = io
    ApiRecipes.configure do |config|
      config.log_to = log
      settings.each { |key, value| config.public_send("#{key}=", value) }
      config.apis_configs = { svc: { host: 'api.example.test', auth: auth, default_headers: { 'X-Default' => 'SECRET-DEFAULT' },
                                     endpoints: { users: nil, show: { path: '/:id' } } } }
    end
  end

  def call_everything
    ApiRecipes.svc.users(headers: { 'X-Private' => 'SECRET-HEADER', 'Cookie' => 'SECRET-COOKIE' },
                         params: { token: 'SECRET-PARAM' }, body: 'SECRET-BODY').run
    ApiRecipes.svc.show(1, params: { token: 'SECRET-PARAM' }).run
    ApiRecipes.svc.with(authorization: 'Bearer SECRET-TOKEN').users.run
  end

  [{ type: 'header', name: 'X-Api-Key' }, { type: 'query', name: 'key' }, nil].each do |auth|
    context "with auth #{auth.inspect}" do
      before do
        configure(auth, log_level: :debug, print_urls: true)
        stub_request(:any, /\.test/).to_return(status: 200, body: '{"echo":"SECRET-BODY"}', headers: json)
        ApiRecipes.svc.authorization = 'Bearer SECRET-TOKEN'
      end

      it 'puts no secret in the debug lines and in the printed urls' do
        call_everything
        expect(io.string).to include('GET https://api.example.test/users')
        secrets.each { |secret| expect(io.string).not_to include(secret) }
        expect(io.string).not_to match(/token=|key=|Bearer/)
      end
    end
  end

  it 'puts no secret in the debug lines for a basic_auth credential' do
    configure(nil, log_level: :debug, print_urls: true)
    stub_request(:any, /\.test/).to_return(status: 200, body: '{}', headers: json)
    ApiRecipes.svc.basic_auth = { user: 'SECRET-USER', pass: 'SECRET-PASS' }
    ApiRecipes.svc.users.run
    expect(io.string).to include('GET https://api.example.test/users')
    %w[SECRET-USER SECRET-PASS U0VDUkVU].each { |secret| expect(io.string).not_to include(secret) }
  end

  it 'puts no secret in the log of a request that fails' do
    configure({ type: 'query', name: 'key' }, log_level: :debug)
    stub_request(:any, /\.test/).to_return(status: 500, body: 'SECRET-BODY')
    ApiRecipes.svc.authorization = 'Bearer SECRET-TOKEN'
    expect { ApiRecipes.svc.users(params: { token: 'SECRET-PARAM' }).run }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected)
    secrets.each { |secret| expect(io.string).not_to include(secret) }
  end

  it 'puts no secret in the log when the configuration is refused' do
    log = io
    expect do
      ApiRecipes.configure do |config|
        config.log_to = log
        config.log_level = :debug
        config.apis_configs = { svc: { host: 'api.example.test', default_headers: { 'X-Default' => "SECRET-DEFAULT\r\nX: y" } } }
      end
    end.to raise_error(ApiRecipes::ConfigurationError) { |error| expect(error.message).not_to include('SECRET-DEFAULT') }
    expect(io.string).not_to include('SECRET-DEFAULT')
  end

  it 'puts no value in the upgrade warnings, and nothing about the request' do
    configure(nil)
    stub_request(:any, /\.test/).to_return(status: 200, body: '{}', headers: json)
    ApiRecipes.svc.authorization = 'Bearer SECRET-TOKEN'
    ApiRecipes.svc.show('SECRET-PARAM/x').url
    ApiRecipes.svc.show('SECRET-PARAM%2Fx').url
    expect(io.string).to include("contains '/'")
    expect(io.string).to include('percent-encoded')
    secrets.each { |secret| expect(io.string).not_to include(secret) }
  end

  it 'writes to STDERR at warn level when the application gives no logger' do
    ApiRecipes.configure do |config|
      config.apis_configs = { svc: { host: 'api.example.test', endpoints: { users: nil, show: { path: '/:id' } } } }
    end
    stub_request(:any, /\.test/).to_return(status: 200, body: '{}', headers: json)
    ApiRecipes.svc.authorization = 'Bearer SECRET-TOKEN'
    expect do
      ApiRecipes.svc.users.run
      ApiRecipes.svc.show('SECRET-PARAM/x').run
    end.to output(/WARN.*contains '\/'/).to_stderr
    expect { ApiRecipes.svc.users.run }.not_to output.to_stdout
  end
end
