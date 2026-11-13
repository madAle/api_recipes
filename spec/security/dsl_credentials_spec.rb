require 'spec_helper'

# Credentials seen from the DSL only: a token goes to the requests of the
# object that owns it and to the origin it was set for, and nowhere else.
describe 'Credentials through the DSL' do
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:client_class) do
    Class.new do
      include ApiRecipes
      api :svc
      api :shop
    end
  end

  before do
    configure_test_apis(
      svc: { host: 'api.example.test', endpoints: { users: nil } },
      shop: { host: '{shop}.example.test', variables: { shop: {} }, endpoints: { orders: nil } }
    )
    stub_request(:any, /\.test/).to_return(status: 200, body: '{}', headers: json)
  end

  def users_url = 'https://api.example.test/users'

  def sent_without_authorization(url = users_url)
    have_requested(:get, url).with { |request| !request.headers.key?('Authorization') }
  end

  it 'does not use the token of one object for the request of another' do
    a = client_class.new
    b = client_class.new
    a.svc.authorization = 'Bearer A'
    b.svc.users.run
    a.svc.users.run
    expect(WebMock).to have_requested(:get, users_url).with(headers: { 'Authorization' => 'Bearer A' }).once
    expect(WebMock).to sent_without_authorization.once
  end

  it 'lets an instance with no token of its own take the shared one, and never the token of a sibling' do
    ApiRecipes.svc.authorization = 'Bearer SHARED'
    a = client_class.new
    b = client_class.new
    a.svc.authorization = 'Bearer A'
    a.svc.users.run
    b.svc.users.run
    expect(WebMock).to have_requested(:get, users_url).with(headers: { 'Authorization' => 'Bearer A' }).once
    expect(WebMock).to have_requested(:get, users_url).with(headers: { 'Authorization' => 'Bearer SHARED' }).once
  end

  it 'keeps nothing from with' do
    ApiRecipes.svc.with(authorization: 'Bearer ONCE').users.run
    ApiRecipes.svc.users.run
    expect(WebMock).to have_requested(:get, users_url).with(headers: { 'Authorization' => 'Bearer ONCE' }).once
    expect(WebMock).to sent_without_authorization.once
    expect(ApiRecipes.svc.authorization).to be_nil
  end

  it 'refuses to store a credential on an object returned by with' do
    expect { ApiRecipes.svc.with(timeout: 5).authorization = 'Bearer X' }.to raise_error(ApiRecipes::Error, /with/)
    expect { ApiRecipes.svc.with(timeout: 5).basic_auth = { user: 'u', pass: 'p' } }.to raise_error(ApiRecipes::Error, /with/)
  end

  it 'sends no token for a client whose token was set to nil, although a shared one exists' do
    ApiRecipes.svc.authorization = 'Bearer SHARED'
    client = client_class.new
    client.svc.authorization = nil
    client.svc.users.run
    expect(WebMock).to sent_without_authorization
  end

  it 'does not send a shared token to another host, protocol or port selected with with' do
    ApiRecipes.svc.authorization = 'Bearer SHARED'
    [{ host: 'evil.test' }, { protocol: 'http' }, { port: 8443 }, { host: 'evil.test', port: 443, protocol: 'https' }].each do |options|
      expect { ApiRecipes.svc.with(options).users.run }.to raise_error(ApiRecipes::CredentialOriginMismatch)
      expect { ApiRecipes.svc.users.with(options) }.to raise_error(ApiRecipes::ConfigurationError, /unknown option/)
    end
    expect(WebMock).not_to have_requested(:any, /.*/)
  end

  it 'sends a token set together with the destination, and only to it' do
    ApiRecipes.svc.with(host: 'other.example.test', authorization: 'Bearer CHAIN').users.run
    expect(WebMock).to have_requested(:get, 'https://other.example.test/users').with(headers: { 'Authorization' => 'Bearer CHAIN' })
    ApiRecipes.svc.users.run
    expect(WebMock).to sent_without_authorization
  end

  it 'does not send a token to a host a variable selects, when the token was set at a farther level' do
    ApiRecipes.shop.variables = { shop: 'acme' }
    ApiRecipes.shop.authorization = 'Bearer SHOP'
    expect { ApiRecipes.shop.with(variables: { shop: 'evil' }).orders.run }.to raise_error(ApiRecipes::CredentialOriginMismatch)
    client = client_class.new
    client.shop.variables = { shop: 'evil' }
    expect { client.shop.orders.run }.to raise_error(ApiRecipes::CredentialOriginMismatch)
    expect(WebMock).not_to have_requested(:any, /evil\.example\.test/)
    ApiRecipes.shop.orders.run
    expect(WebMock).to have_requested(:get, 'https://acme.example.test/orders').with(headers: { 'Authorization' => 'Bearer SHOP' })
  end

  it 'does not send a token whose own level cannot tell the host a variable selects' do
    ApiRecipes.shop.authorization = 'Bearer SHOP'
    expect { ApiRecipes.shop.with(variables: { shop: 'evil' }).orders.run }.to raise_error(ApiRecipes::CredentialOriginMismatch)
    expect(WebMock).not_to have_requested(:any, /.*/)
  end

  it 'does not let a class that changes the host receive the global token' do
    ApiRecipes.svc.authorization = 'Bearer GLOBAL'
    other = Class.new do
      include ApiRecipes
      api :svc, host: 'other.example.test'
    end
    expect { other.svc.users.run }.to raise_error(ApiRecipes::CredentialOriginMismatch)
    expect { other.new.svc.users.run }.to raise_error(ApiRecipes::CredentialOriginMismatch)
    expect(WebMock).not_to have_requested(:any, /other\.example\.test/)
  end

  describe 'a client object that is restored or frozen' do
    let(:named_class) do
      stub_const('RestoredClient', client_class)
    end

    it 'sends no credential after a Marshal round trip' do
      client = named_class.new
      client.svc.authorization = 'Bearer SECRET'
      restored = Marshal.load(Marshal.dump(client))
      restored.svc.users.run
      expect(WebMock).to sent_without_authorization
      expect(Marshal.dump(client)).not_to include('SECRET')
    end

    it 'sends no credential after a YAML round trip' do
      client = named_class.new
      client.svc.authorization = 'Bearer SECRET'
      dumped = YAML.dump(client)
      expect(dumped).not_to include('SECRET')
      restored = YAML.unsafe_load(dumped)
      restored.svc.users.run
      expect(WebMock).to sent_without_authorization
    end

    it 'sends a restored credential container as no credential, whatever the form' do
      credential = ApiRecipes::Internals::Credential.authorization('Bearer SECRET')
      [Marshal.dump(credential), YAML.dump(credential), JSON.generate(credential)].each do |dumped|
        expect(dumped).not_to include('SECRET')
      end
      expect(Marshal.load(Marshal.dump(credential))).to be_none
      expect(YAML.unsafe_load(YAML.dump(credential))).to be_none
    end

    it 'refuses to store a credential on a frozen object, which can still send one with with' do
      frozen = client_class.new.freeze
      expect { frozen.svc.authorization = 'Bearer FROZEN' }.to raise_error(ApiRecipes::Error, /frozen/)
      frozen.svc.with(authorization: 'Bearer ONCE').users.run
      frozen.svc.users.run
      expect(WebMock).to have_requested(:get, users_url).with(headers: { 'Authorization' => 'Bearer ONCE' }).once
      expect(WebMock).to sent_without_authorization.once
    end
  end

  describe 'a credential with a control character' do
    it 'is refused before it is sent, without showing it' do
      ["Bearer SECRET\n", "Bearer\r\nX-Injected: SECRET", "Bearer SECRET\0"].each do |value|
        expect { ApiRecipes.svc.with(authorization: value).users.run }
          .to raise_error(ApiRecipes::InvalidCredential) { |error| expect(error.message).not_to include('SECRET') }
        expect { ApiRecipes.svc.authorization = value }
          .to raise_error(ApiRecipes::InvalidCredential) { |error| expect(error.message).not_to include('SECRET') }
      end
      expect { ApiRecipes.svc.basic_auth = { user: 'u', pass: "SECRET\n" } }
        .to raise_error(ApiRecipes::InvalidCredential) { |error| expect(error.message).not_to include('SECRET') }
      expect(WebMock).not_to have_requested(:any, /.*/)
    end
  end
end
