require 'spec_helper'

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
end
