require 'spec_helper'

describe 'Response#fill with keys chosen by the server' do
  let(:account) do
    Class.new do
      attr_accessor :login, :role
      attr_reader :secret

      private

      def secret=(value)
        @secret = value
      end
    end
  end

  def filled(body, **options)
    stub_request(:get, "#{base_url}/users").to_return(status: 200, body: body, headers: { 'Content-Type' => 'application/json' })
    configure_test_apis
    ApiRecipes.svc.users.run.fill(account.new, **options)
  end

  it 'never calls a private writer' do
    expect(filled('{"login":"a","secret":"x"}').secret).to be_nil
  end

  it 'skips keys that are not plain attribute names' do
    calls = []
    greedy = Class.new do
      attr_accessor :login

      ['Class=', "login\n=", 'a b=', 'instance_variable_set(:@x, 1); login='].each do |name|
        define_method(name) { |value| calls << [name, value] }
      end
    end
    stub_request(:get, "#{base_url}/users").to_return(
      status: 200,
      body: '{"login":"a","Class":"c","login\n":"b","a b":"d","instance_variable_set(:@x, 1); login":"e"}',
      headers: { 'Content-Type' => 'application/json' }
    )
    configure_test_apis
    object = ApiRecipes.svc.users.run.fill(greedy.new)
    expect(calls).to eq([])
    expect(object.login).to eq('a')
  end

  describe 'only and except given in different forms' do
    let(:body) { '{"login":"a","role":"admin"}' }

    it 'accepts Strings for except' do
      result = filled(body, except: %w[role])
      expect([result.login, result.role]).to eq(['a', nil])
    end

    it 'accepts Strings for only' do
      result = filled(body, only: %w[login])
      expect([result.login, result.role]).to eq(['a', nil])
    end

    it 'accepts a single Symbol or String' do
      expect(filled(body, only: :login).role).to be_nil
      expect(filled(body, except: 'role').role).to be_nil
      expect(filled(body, only: 'login').login).to eq('a')
      expect(filled(body, except: :login).login).to be_nil
    end
  end

  it 'limits the attributes with only and except' do
    expect(filled('{"login":"a","role":"admin"}', only: [:login]).role).to be_nil
    expect(filled('{"login":"a","role":"admin"}', except: [:role]).role).to be_nil
  end
end
