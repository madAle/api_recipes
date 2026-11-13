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

  it 'drops the credential when only the scheme or only the port changes' do
    stub_request(:get, 'http://api.example.test:443/plain').to_return(status: 200, body: '')
    stub_request(:get, 'https://api.example.test:8443/port').to_return(status: 200, body: '')
    %w[http://api.example.test:443/plain https://api.example.test:8443/port].each do |location|
      stub_request(:get, 'https://api.example.test/users').to_return(status: 302, headers: { 'Location' => location })
      new_request(base, %i[users], options: { follow: true }).perform
      expect(WebMock).to have_requested(:get, location).with { |r| !r.headers.key?('Authorization') }
    end
  end

  it 'does not give the credential back after a redirect out of the origin and back' do
    stub_request(:get, 'https://api.example.test/users').to_return(to_evil)
    stub_request(:get, 'https://evil.test/steal').to_return(status: 302, headers: { 'Location' => 'https://api.example.test/back' })
    stub_request(:get, 'https://api.example.test/back').to_return(status: 200, body: '')
    new_request(base, %i[users], options: { follow: true }).perform
    expect(WebMock).to have_requested(:get, 'https://evil.test/steal').with { |r| !r.headers.key?('Authorization') }
    expect(WebMock).to have_requested(:get, 'https://api.example.test/back').with { |r| !r.headers.key?('Authorization') }
  end

  it 'calls the on_redirect of the caller after dropping, with Symbol or String keys' do
    stub_request(:get, 'https://api.example.test/users').to_return(to_evil)
    [{ on_redirect: nil, max_hops: 2 }, { 'on_redirect' => nil, 'max_hops' => 2 }].each do |follow|
      seen = []
      hook = ->(_response, request) { seen << [request.uri.host, request.headers['Authorization']] }
      follow = follow.to_h { |key, value| [key, key.to_s == 'on_redirect' ? hook : value] }
      new_request(base, %i[users], options: { follow: follow }).perform
      expect(seen).to eq([['evil.test', nil]])
    end
  end

  it 'does not repeat a credential sent in the query to another origin' do
    query = base.merge(auth: { type: 'query', name: 'api_key' })
    stub_request(:get, %r{\Ahttps://api\.example\.test/users})
      .to_return(status: 302, headers: { 'Location' => 'https://evil.test/steal?api_key=Bearer%20SECRET&x=1' })
    stub_request(:get, %r{\Ahttps://evil\.test/steal}).to_return(status: 200, body: '')
    new_request(query, %i[users], options: { follow: true }).perform
    expect(WebMock).to have_requested(:get, 'https://api.example.test/users').with(query: { 'api_key' => 'Bearer SECRET' })
    expect(WebMock).to have_requested(:get, 'https://evil.test/steal').with(query: { 'x' => '1' })
    expect(WebMock).not_to have_requested(:get, /evil\.test.*SECRET/)
  end

  it 'drops an Authorization header given with the request, also without a credential' do
    stub_request(:get, 'https://api.example.test/users').to_return(to_evil)
    new_request(base, %i[users], overrides: { authorization: nil },
                                 options: { follow: true, headers: { 'Authorization' => 'Bearer USER' } }).perform
    expect(WebMock).to have_requested(:get, 'https://api.example.test/users').with(headers: { 'Authorization' => 'Bearer USER' })
    expect(WebMock).to have_requested(:get, 'https://evil.test/steal').with { |r| !r.headers.key?('Authorization') }
  end

  it 'leaves an unsupported follow value to http.rb, with or without a credential' do
    stub_request(:get, 'https://api.example.test/users').to_return(to_evil)
    [nil, { authorization: nil }].each do |overrides|
      expect { new_request(base, %i[users], overrides: overrides, options: { follow: 'yes' }).perform }
        .to raise_error(HTTP::Error, /follow/)
    end
    expect { new_request(base, %i[users], options: { follow: false }).perform }
      .to raise_error(ApiRecipes::ResponseCodeNotAsExpected)
    expect(WebMock).not_to have_requested(:get, 'https://evil.test/steal')
  end

  it 'does not follow redirects unless asked' do
    stub_request(:get, 'https://api.example.test/users').to_return(to_evil)
    expect { new_request(base, %i[users]).perform }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected)
    expect(WebMock).not_to have_requested(:get, 'https://evil.test/steal')
  end
end
