require 'spec_helper'
require 'json'
require 'yaml'
require 'pp'
require 'stringio'

describe ApiRecipes::Credential do
  it 'never shows its value' do
    credential = described_class.authorization('Bearer SECRET')
    expect(credential.value).to eq('Bearer SECRET')
    expect([credential.inspect, credential.to_s, "#{credential}"]).to all(eq('#<ApiRecipes::Credential authorization [FILTERED]>'))
  end

  it 'treats nil as an explicit absence' do
    expect(described_class.from(:authorization, nil)).to equal(described_class::NONE)
    expect(described_class::NONE.none?).to eq(true)
  end

  ["Bearer X\n", "Bearer X\r", "a\u0000b"].each do |value|
    it "rejects #{value.inspect} without quoting it" do
      expect { described_class.authorization(value) }
        .to raise_error(ApiRecipes::InvalidCredential) { |e| expect(e.message).not_to include('Bearer X') }
    end
  end

  it 'checks basic auth' do
    expect(described_class.basic_auth(user: 'u', pass: 'p').value).to eq(user: 'u', pass: 'p')
    expect { described_class.basic_auth('u:p') }.to raise_error(ApiRecipes::InvalidCredential)
    expect { described_class.basic_auth(user: "u\n", pass: 'p') }.to raise_error(ApiRecipes::InvalidCredential)
  end

  it 'prints no secret with pp' do
    io = StringIO.new
    PP.pp(described_class.authorization('Bearer SECRET'), io)
    expect(io.string).not_to include('SECRET')
  end

  it 'keeps its own frozen copy of the strings' do
    text = +'Bearer SECRET'
    user = +'uSECRET'
    pass = +'pSECRET'
    token = described_class.authorization(text)
    basic = described_class.basic_auth(user: user, pass: pass)
    text << "\r\nX: y"
    user << "\r\nX: y"
    pass << "\r\nX: y"
    expect(token.value).to eq('Bearer SECRET')
    expect(token.value).to be_frozen
    expect(basic.value).to eq(user: 'uSECRET', pass: 'pSECRET')
    expect(basic.value[:user]).to be_frozen
    expect(basic.value[:pass]).to be_frozen
  end

  it 'writes no secret when serialized' do
    credential = described_class.basic_auth(user: 'uSECRET', pass: 'pSECRET')
    [Marshal.dump(credential), YAML.dump(credential), credential.to_json, credential.as_json.to_s].each do |text|
      expect(text).not_to include('SECRET')
    end
    expect(Marshal.load(Marshal.dump(credential)).none?).to eq(true)
  end
end
