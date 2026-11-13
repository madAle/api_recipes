require 'spec_helper'

describe 'Redirects' do
  let(:base) { { host: 'api.example.test', endpoints: { users: nil } } }
  let(:to_evil) { { status: 302, headers: { 'Location' => 'https://evil.test/steal' } } }

  before do
    ApiRecipes::LevelSet.write(ApiRecipes, :svc) { |l| l.with(credential: ApiRecipes::Credential.authorization('Bearer SECRET')) }
    stub_request(:get, 'https://evil.test/steal').to_return(status: 200, body: '')
    stub_request(:get, 'https://api.example.test/moved').to_return(status: 200, body: '')
  end

  it 'drops the credential and the cookies when the redirect leaves the origin' do
    stub_request(:get, 'https://api.example.test/users').to_return(to_evil)
    new_request(base, %i[users], options: { follow: true, headers: { 'Cookie' => 'session=1' } }).perform
    expect(WebMock).to have_requested(:get, 'https://evil.test/steal')
      .with { |r| !r.headers.key?('Authorization') && !r.headers.key?('Cookie') }
  end

  it 'drops the header named by auth' do
    stub_request(:get, 'https://api.example.test/users').to_return(to_evil)
    new_request(base.merge(auth: { type: 'header', name: 'X-Api-Key' }), %i[users], options: { follow: true }).perform
    expect(WebMock).to have_requested(:get, 'https://evil.test/steal').with { |r| !r.headers.key?('X-Api-Key') }
  end

  it 'keeps the credential on a redirect inside the origin' do
    stub_request(:get, 'https://api.example.test/users').to_return(status: 302, headers: { 'Location' => '/moved' })
    new_request(base, %i[users], options: { follow: true }).perform
    expect(WebMock).to have_requested(:get, 'https://api.example.test/moved').with(headers: { 'Authorization' => 'Bearer SECRET' })
  end

  it 'does not follow redirects unless asked' do
    stub_request(:get, 'https://api.example.test/users').to_return(to_evil)
    expect { new_request(base, %i[users]).perform }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected)
    expect(WebMock).not_to have_requested(:get, 'https://evil.test/steal')
  end
end
