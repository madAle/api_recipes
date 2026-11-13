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
    expect { filled('{"login":"a","instance_variable_set(:@x, 1); login":"b","Class":"c","a b":"d"}') }.not_to raise_error
  end

  it 'limits the attributes with only and except' do
    expect(filled('{"login":"a","role":"admin"}', only: [:login]).role).to be_nil
    expect(filled('{"login":"a","role":"admin"}', except: [:role]).role).to be_nil
  end
end
