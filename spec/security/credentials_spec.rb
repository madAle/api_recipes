require 'spec_helper'

describe 'Credentials' do
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:base) { { host: 'api.example.test', endpoints: { users: nil } } }
  let(:klass) { Class.new }

  # The levels of classes and objects belong to a declaration (one for every
  # owner here); the global level keeps the api name.
  let(:declaration) { ApiRecipes::Core::Declaration.new(klass, :svc, {}, nil) }

  before { stub_request(:any, /example\.test/).to_return(status: 200, body: '{}', headers: json) }

  def declaration_for(owner) = owner.equal?(ApiRecipes) ? nil : declaration

  def assign(owner, value)
    credential = ApiRecipes::Core::Credential.from(:authorization, value)
    ApiRecipes::Core::LevelSet.write(owner, declaration_for(owner) || :svc) { |l| l.with(credential: credential) }
  end

  # The helper of TestApis, with the levels of owner read through the declaration.
  def new_request(*args, owner: ApiRecipes, **options)
    super(*args, owner: owner, declaration: declaration_for(owner), **options)
  end

  def sent(headers) = have_requested(:get, 'https://api.example.test/users').with(headers: headers)

  def sent_without_authorization
    have_requested(:get, 'https://api.example.test/users').with { |r| !r.headers.key?('Authorization') }
  end

  it 'gives each object its own token' do
    a = klass.new
    b = klass.new
    assign(a, 'Bearer a')
    assign(b, 'Bearer b')
    new_request(base, %i[users], owner: a).perform
    expect(WebMock).to sent('Authorization' => 'Bearer a')
  end

  it 'walks instance, class, global' do
    assign(ApiRecipes, 'Bearer global')
    new_request(base, %i[users], owner: klass.new).perform
    expect(WebMock).to sent('Authorization' => 'Bearer global')
    assign(klass, 'Bearer class')
    new_request(base, %i[users], owner: klass.new).perform
    expect(WebMock).to sent('Authorization' => 'Bearer class')
  end

  it 'stops at an explicit nil instead of using the shared token' do
    assign(ApiRecipes, 'Bearer global')
    object = klass.new
    assign(object, nil)
    new_request(base, %i[users], owner: object).perform
    new_request(base, %i[users], overrides: { authorization: nil }).perform
    expect(WebMock).to sent_without_authorization.twice
  end

  it 'does not send a token to an origin it was not set for' do
    assign(ApiRecipes, 'Bearer global')
    global = ApiRecipes::Core::Compiler.compile(:svc, base)
    other = base.merge(host: 'other.example.test')
    expect { new_request(other, %i[users], owner: klass, global: global).perform }
      .to raise_error(ApiRecipes::CredentialOriginMismatch, /other\.example\.test/)
    expect { new_request(base, %i[users], overrides: { host: 'other.example.test' }).perform }
      .to raise_error(ApiRecipes::CredentialOriginMismatch)
    expect { new_request(base, %i[users], overrides: { port: 8443 }).perform }
      .to raise_error(ApiRecipes::CredentialOriginMismatch)
    expect(WebMock).not_to have_requested(:any, /example\.test/)
  end

  it 'does not send a token over another scheme' do
    assign(ApiRecipes, 'Bearer global')
    expect { new_request(base, %i[users], overrides: { protocol: 'http' }).perform }
      .to raise_error(ApiRecipes::CredentialOriginMismatch, %r{http://api\.example\.test})
    expect(WebMock).not_to have_requested(:any, /example\.test/)
  end

  it 'says so when the origin of a token cannot be determined at its level' do
    config = base.merge(host: '{shop}.example.test', variables: { shop: {} })
    assign(ApiRecipes, 'Bearer global')
    expect { new_request(config, %i[users], overrides: { variables: { shop: 'acme' } }).perform }
      .to raise_error(ApiRecipes::CredentialOriginMismatch, /cannot be determined/)
  end

  it 'sends it when the same level sets destination and token' do
    assign(klass, 'Bearer class')
    global = ApiRecipes::Core::Compiler.compile(:svc, base)
    new_request(base.merge(host: 'other.example.test'), %i[users], owner: klass, global: global).perform
    new_request(base, %i[users], overrides: { host: 'third.example.test', authorization: 'Bearer chain' }).perform
    expect(WebMock).to have_requested(:get, 'https://other.example.test/users').with(headers: { 'Authorization' => 'Bearer class' })
    expect(WebMock).to have_requested(:get, 'https://third.example.test/users').with(headers: { 'Authorization' => 'Bearer chain' })
  end

  it 'binds a token to the host a variable selects' do
    config = base.merge(host: '{shop}.example.test', variables: { shop: {} })
    assign(ApiRecipes, 'Bearer global')
    expect { new_request(config, %i[users], overrides: { variables: { shop: 'acme' } }).perform }
      .to raise_error(ApiRecipes::CredentialOriginMismatch)
  end

  it 'binds a superclass token to the host the superclass selects, not a subclass variable' do
    config = base.merge(host: '{shop}.example.test', variables: { shop: { default: 'api' } })
    parent = Class.new
    child = Class.new(parent)
    assign(parent, 'Bearer parent')
    ApiRecipes::Core::LevelSet.write(child, declaration) { |l| l.with(variables: { shop: 'other' }.freeze) }
    expect { new_request(config, %i[users], owner: child.new).perform }
      .to raise_error(ApiRecipes::CredentialOriginMismatch, /other\.example\.test/)
    expect(WebMock).not_to have_requested(:any, /example\.test/)
    assign(child, 'Bearer child')
    new_request(config, %i[users], owner: child.new).perform
    expect(WebMock).to have_requested(:get, 'https://other.example.test/users').with(headers: { 'Authorization' => 'Bearer child' })
  end
end
