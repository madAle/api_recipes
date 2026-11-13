require 'spec_helper'

# What a server can do through its answers, seen from the DSL.
describe 'Responses through the DSL' do
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:account) do
    Class.new do
      attr_accessor :login, :role, :admin
      attr_reader :secret

      private

      def secret=(value)
        @secret = value
      end
    end
  end

  before do
    configure_test_apis(svc: { host: 'api.example.test', endpoints: { users: nil } })
    ApiRecipes.svc.authorization = 'Bearer SECRET'
  end

  def answer(body, headers: json)
    stub_request(:get, "#{base_url}/users").to_return(status: 200, body: body, headers: headers)
  end

  describe 'a redirect' do
    let(:evil) { { status: 302, headers: { 'Location' => 'https://evil.test/steal' } } }

    before do
      stub_request(:get, 'https://evil.test/steal').to_return(status: 200, body: '{}')
      stub_request(:get, "#{base_url}/users").to_return(evil)
    end

    it 'is not followed unless the request asks for it' do
      expect { ApiRecipes.svc.users.run }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected)
      expect(WebMock).not_to have_requested(:get, 'https://evil.test/steal')
    end

    it 'does not take the credential, the header named by auth or the cookie to another origin' do
      ApiRecipes.svc.users(follow: true, headers: { 'Cookie' => 'session=1' }).run
      ApiRecipes.svc.users(follow: { max_hops: 3 }, headers: { 'Cookie' => 'session=1' }).run
      expect(WebMock).to have_requested(:get, 'https://evil.test/steal')
        .with { |request| !request.headers.key?('Authorization') && !request.headers.key?('Cookie') }.twice
    end

    it 'does not take the header named by auth to another origin, nor give it back on the way home' do
      ApiRecipes.reset!
      configure_test_apis(svc: { host: 'api.example.test', auth: { type: 'header', name: 'X-Api-Key' }, endpoints: { users: nil } })
      ApiRecipes.svc.authorization = 'SECRET'
      stub_request(:get, 'https://evil.test/steal')
        .to_return(status: 302, headers: { 'Location' => 'https://api.example.test/back' })
      stub_request(:get, 'https://api.example.test/back').to_return(status: 200, body: '{}')
      ApiRecipes.svc.users(follow: true).run
      expect(WebMock).to have_requested(:get, "#{base_url}/users").with(headers: { 'X-Api-Key' => 'SECRET' })
      %w[https://evil.test/steal https://api.example.test/back].each do |url|
        expect(WebMock).to have_requested(:get, url).with { |request| !request.headers.key?('X-Api-Key') }
      end
    end

    it 'does not take a credential sent in the query to another origin' do
      ApiRecipes.reset!
      configure_test_apis(svc: { host: 'api.example.test', auth: { type: 'query', name: 'key' }, endpoints: { users: nil } })
      ApiRecipes.svc.authorization = 'SECRET'
      stub_request(:get, %r{\Ahttps://api\.example\.test/users})
        .to_return(status: 302, headers: { 'Location' => 'https://evil.test/steal?key=SECRET&x=1' })
      stub_request(:get, %r{\Ahttps://evil\.test/steal}).to_return(status: 200, body: '{}')
      ApiRecipes.svc.users(follow: true).run
      expect(WebMock).to have_requested(:get, 'https://evil.test/steal').with(query: { 'x' => '1' })
      expect(WebMock).not_to have_requested(:get, /evil\.test.*SECRET/)
    end

    it 'refuses a follow value that http.rb would take, before anything is sent' do
      fetcher = Object.new
      def fetcher.fetch(_key, default = nil) = default
      [fetcher, 'yes', 1, [], { unknown: 1 }, { max_hops: '2' }].each do |follow|
        expect { ApiRecipes.svc.users(follow: follow).run }.to raise_error(ApiRecipes::ConfigurationError)
      end
      expect(WebMock).not_to have_requested(:any, /.*/)
    end
  end

  describe 'fill' do
    it 'calls only the public writers that match a plain attribute name' do
      answer('{"login":"a","secret":"x","Role":"r","instance_eval":"1","__send__":"2","login ":"b","a.b":"c","admin\n":"d"}')
      filled = ApiRecipes.svc.users.run.fill(account.new)
      expect(filled.login).to eq('a')
      expect(filled.secret).to be_nil
      expect(filled.role).to be_nil
      expect(filled.admin).to be_nil
    end

    it 'limits a list of objects with only and except, in every form' do
      answer('[{"login":"a","role":"admin"},{"login":"b","role":"admin"}]')
      [{ only: :login }, { only: 'login' }, { only: %w[login] }, { except: :role }, { except: 'role' }, { except: %w[role] }].each do |limit|
        filled = ApiRecipes.svc.users.run.fill(account, **limit)
        expect(filled.map(&:login)).to eq(%w[a b])
        expect(filled.map(&:role)).to eq([nil, nil])
      end
    end

    it 'ignores what is not an object or a list of objects' do
      answer('"text"')
      expect(ApiRecipes.svc.users.run.fill(account.new)).to be_nil
      answer('[1,"x",null]')
      expect(ApiRecipes.svc.users.run.fill(account).map(&:login)).to eq([nil, nil, nil])
    end
  end

  describe 'data' do
    it 'never builds Ruby objects from a body' do
      answer('{"json_class":"Gem::Installer","login":"a"}')
      expect(ApiRecipes.svc.users.run.data).to eq('json_class' => 'Gem::Installer', 'login' => 'a')
    end

    it 'does not read a type that http.rb has no parser for, and so never reads YAML' do
      answer("--- !ruby/object:Gem::Installer\nlogin: a\n", headers: { 'Content-Type' => 'application/x-yaml' })
      expect { ApiRecipes.svc.users.run.data }.to raise_error(HTTP::Error)
    end

    it 'does not read YAML even when the type is forced with mime_type' do
      answer("--- !ruby/object:Gem::Installer\nlogin: a\n")
      expect { ApiRecipes.svc.users.with(mime_type: 'application/x-yaml').run.data }.to raise_error(HTTP::Error)
    end
  end

  it 'sets a timeout of 3 seconds on every request, and no request has none' do
    answer('{}')
    expect_timeout(3)
    ApiRecipes.svc.users.run
  end

  it 'refuses a timeout that would remove the limit, and nil falls back to the default' do
    answer('{}')
    [0, -1, '1', Float::INFINITY, Float::NAN].each do |value|
      expect { ApiRecipes.svc.users.with(timeout: value) }.to raise_error(ApiRecipes::ConfigurationError)
      expect { ApiRecipes.svc.with(timeout: value) }.to raise_error(ApiRecipes::ConfigurationError)
    end
    expect_timeout(3)
    ApiRecipes.svc.with(timeout: nil).users.run
  end
end
