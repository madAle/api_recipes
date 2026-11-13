require 'spec_helper'

describe 'Redirects' do
  let(:base) { { host: 'api.example.test', endpoints: { users: nil } } }
  let(:to_evil) { { status: 302, headers: { 'Location' => 'https://evil.test/steal' } } }

  before do
    ApiRecipes::Internals::LevelSet.write(ApiRecipes, :svc) { |l| l.with(credential: ApiRecipes::Internals::Credential.authorization('Bearer SECRET')) }
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

  it 'does not give back the header named by auth after a redirect out of the origin and back' do
    stub_request(:get, 'https://api.example.test/users').to_return(to_evil)
    stub_request(:get, 'https://evil.test/steal').to_return(status: 302, headers: { 'Location' => 'https://api.example.test/back' })
    stub_request(:get, 'https://api.example.test/back').to_return(status: 200, body: '')
    new_request(base.merge(auth: { type: 'header', name: 'X-Api-Key' }), %i[users], options: { follow: true }).perform
    expect(WebMock).to have_requested(:get, 'https://api.example.test/users').with(headers: { 'X-Api-Key' => 'Bearer SECRET' })
    %w[https://evil.test/steal https://api.example.test/back].each do |url|
      expect(WebMock).to have_requested(:get, url).with { |r| !r.headers.key?('X-Api-Key') }
    end
  end

  # No cookie jar along the chain: the Cookie of the request goes on inside the
  # origin and stops at the first other origin; a Set-Cookie of any server,
  # the origin included, is never sent on a later hop.
  it 'does not carry cookies along the chain, whoever set them' do
    stub_request(:get, 'https://api.example.test/users')
      .to_return(status: 302, headers: { 'Location' => '/moved', 'Set-Cookie' => 'origin=1' })
    stub_request(:get, 'https://api.example.test/moved').to_return(to_evil)
    stub_request(:get, 'https://evil.test/steal')
      .to_return(status: 302, headers: { 'Location' => 'https://api.example.test/back', 'Set-Cookie' => 'evil=1' })
    stub_request(:get, 'https://api.example.test/back').to_return(status: 200, body: '')
    new_request(base, %i[users], options: { follow: true, headers: { 'Cookie' => 'session=1' } }).perform
    expect(WebMock).to have_requested(:get, 'https://api.example.test/moved').with(headers: { 'Cookie' => 'session=1' })
    %w[https://evil.test/steal https://api.example.test/back].each do |url|
      expect(WebMock).to have_requested(:get, url).with { |r| !r.headers.key?('Cookie') }
    end
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

  it 'refuses any follow value other than true, false, nil or a Hash, with or without a credential' do
    stub_request(:get, 'https://api.example.test/users').to_return(to_evil)
    fetcher = Object.new
    def fetcher.fetch(_key, default = nil) = default
    options = [fetcher, 'yes', 1, []].map { |follow| { follow: follow } } +
              [{ 'follow' => fetcher }, { 'follow'.encode('UTF-16LE') => fetcher }]
    options.each do |given|
      [nil, { authorization: nil }].each do |overrides|
        request = new_request(base, %i[users], overrides: overrides, options: given.merge(headers: { 'Cookie' => 's=1' }))
        expect { request.perform }.to raise_error(ApiRecipes::ConfigurationError) { |error|
          expect(error.errors).to eq(['follow: must be true, false or a Hash'])
        }
      end
    end
    expect(WebMock).not_to have_requested(:any, /example\.test|evil\.test/)
  end

  it 'refuses follow options that http.rb would refuse, before sending anything' do
    stub_request(:get, 'https://api.example.test/users').to_return(to_evil)
    {
      { unknown: 1 } => "follow: unknown option 'unknown'",
      { 'max_hop' => 2 } => "follow: unknown option 'max_hop'",
      { max_hops: nil } => 'follow.max_hops: must be an integer',
      { 'max_hops' => '2' } => 'follow.max_hops: must be an integer'
    }.each do |follow, message|
      expect { new_request(base, %i[users], options: { follow: follow }).perform }
        .to raise_error(ApiRecipes::ConfigurationError) { |error| expect(error.errors).to eq([message]) }
    end
    expect(WebMock).not_to have_requested(:any, /example\.test|evil\.test/)
  end

  it 'follows with true or a Hash, and not with false or nil' do
    stub_request(:get, 'https://api.example.test/users').to_return(to_evil)
    [false, nil].each do |follow|
      expect { new_request(base, %i[users], options: { follow: follow }).perform }
        .to raise_error(ApiRecipes::ResponseCodeNotAsExpected)
    end
    expect(WebMock).not_to have_requested(:get, 'https://evil.test/steal')
    [true, { max_hops: 2 }, { 'max_hops' => 2 }].each do |follow|
      new_request(base, %i[users], options: { follow: follow }).perform
    end
    expect(WebMock).to have_requested(:get, 'https://evil.test/steal').with { |r| !r.headers.key?('Authorization') }.times(3)
  end

  it 'does not follow redirects unless asked' do
    stub_request(:get, 'https://api.example.test/users').to_return(to_evil)
    expect { new_request(base, %i[users]).perform }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected)
    expect(WebMock).not_to have_requested(:get, 'https://evil.test/steal')
  end
end
