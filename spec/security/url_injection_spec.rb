require 'spec_helper'

describe 'Values that try to change where a request goes' do
  let(:json) { { 'Content-Type' => 'application/json' } }

  before do
    configure_test_apis(svc: { host: '{tenant}.example.test', base_url: 'v1/{account}',
                               variables: { tenant: { default: 'main' }, account: { default: 'a1' } },
                               endpoints: { users: { endpoints: { show: { path: '/:id' }, file: { path: '/files/*path' } } } } })
    stub_request(:any, /.*/).to_return(status: 200, body: '{}', headers: json)
  end

  def requested_hosts
    WebMock::RequestRegistry.instance.requested_signatures.hash.keys.map { |signature| signature.uri.host }.uniq
  end

  ['../admin', '..', '.', 'a/../../admin', '?x=1', '#frag', "a\nb", 'a\\..\\b', '%2e%2e', '//evil.test', '@evil.test'].each do |value|
    it "keeps the path parameter #{value.inspect} inside its segment" do
      begin
        ApiRecipes.svc.users.show(value).run
      rescue ApiRecipes::InvalidPathParameter
        next
      end
      expect(requested_hosts).to eq(['main.example.test'])
      expect(WebMock).to have_requested(:get, %r{\Ahttps://main\.example\.test(:443)?/v1/a1/users/[^/?#]+\z})
    end
  end

  ['../../secret', 'a//b', '/etc/passwd', 'a/../b'].each do |value|
    it "rejects the splat value #{value.inspect}" do
      expect { ApiRecipes.svc.users.file(value).run }.to raise_error(ApiRecipes::InvalidPathParameter)
      expect(WebMock).not_to have_requested(:any, /.*/)
    end
  end

  ['evil.test/', 'evil.test#', 'x@evil.test', 'evil.test:444', "evil.test\n", 'evil.test\\'].each do |value|
    it "rejects the host variable #{value.inspect}" do
      expect { ApiRecipes.svc.with(variables: { tenant: value }).users.run }.to raise_error(ApiRecipes::InvalidVariable)
      expect(WebMock).not_to have_requested(:any, /.*/)
    end
  end

  it 'keeps a base_url variable inside its segment' do
    ApiRecipes.svc.with(variables: { account: 'a/../../x' }).users.run
    expect(requested_hosts).to eq(['main.example.test'])
    expect(ApiRecipes.svc.with(variables: { account: 'a/../../x' }).users.url.path).to eq('/v1/a%2F..%2F..%2Fx/users')
  end

  ['h.test/x', 'u@h.test', "h.test\r\nHost: evil.test", 'h.test evil.test'].each do |host|
    it "rejects the host #{host.inspect} in with and in api" do
      expect { ApiRecipes.svc.with(host: host) }.to raise_error(ApiRecipes::ConfigurationError)
      declaration = lambda do
        Class.new do
          include ApiRecipes
          api :svc, host: host
        end
      end
      expect(&declaration).to raise_error(ApiRecipes::ConfigurationError)
    end
  end

  it 'refuses a header value that would add a header' do
    expect { ApiRecipes.svc.with(default_headers: { 'X-A' => "1\r\nX-B: 2" }) }.to raise_error(ApiRecipes::ConfigurationError)
  end

  it 'refuses, and does not neutralize, the values that name no segment or the current or parent one' do
    ['.', '..', '', nil].each do |value|
      expect { ApiRecipes.svc.users.show(value).run }.to raise_error(ApiRecipes::InvalidPathParameter)
    end
    expect(WebMock).not_to have_requested(:any, /.*/)
  end

  it 'sends a slash of a path parameter as %2F and keeps the segment count' do
    ApiRecipes.svc.users.show('a/b').run
    expect(WebMock).to have_requested(:get, 'https://main.example.test/v1/a1/users/a%2Fb')
  end

  ['./x', 'x/.', 'a/./b', 'a/', '', nil, 'a/..'].each do |value|
    it "rejects the splat value #{value.inspect} that has an empty, current or parent piece" do
      expect { ApiRecipes.svc.users.file(value).run }.to raise_error(ApiRecipes::InvalidPathParameter)
      expect(WebMock).not_to have_requested(:any, /.*/)
    end
  end

  it 'encodes each piece of a splat value' do
    ApiRecipes.svc.users.file('a b/c?d/e#f').run
    expect(WebMock).to have_requested(:get, 'https://main.example.test/v1/a1/users/files/a%20b/c%3Fd/e%23f')
  end

  it 'refuses a protocol or a port that is not one in with and in api' do
    [{ protocol: 'ftp' }, { protocol: 'https://evil.test/' }, { port: 0 }, { port: 70_000 }, { port: '443/x' }].each do |options|
      expect { ApiRecipes.svc.with(options) }.to raise_error(ApiRecipes::ConfigurationError)
      expect { Class.new { include ApiRecipes; api :svc, options } }.to raise_error(ApiRecipes::ConfigurationError)
    end
  end

  it 'refuses a variable that adds a header through default_headers' do
    ApiRecipes.reset!
    configure_test_apis(svc: { host: 'h.test', variables: { tenant: { default: 'a' } },
                               default_headers: { 'X-Tenant' => '{tenant}' }, endpoints: { users: nil } })
    ["a\r\nX-B: 2", "a\nb", "a\0b"].each do |value|
      expect { ApiRecipes.svc.with(variables: { tenant: value }).users.run }.to raise_error(ApiRecipes::InvalidVariable)
    end
    ApiRecipes.svc.with(variables: { tenant: 'fine' }).users.run
    expect(WebMock).to have_requested(:get, 'https://h.test/users').with(headers: { 'X-Tenant' => 'fine' }).once
  end

  # The gem checks the form of a host, not whom it belongs to: the application
  # must not give a user's value to with(host:) or to a variable that is the
  # whole host.
  it 'does not decide whose a well-formed host is' do
    ApiRecipes.reset!
    configure_test_apis(svc: { host: '{host}', variables: { host: {} }, endpoints: { users: nil } })
    ApiRecipes.svc.with(variables: { host: 'chosen-by-the-caller.test' }).users.run
    ApiRecipes.svc.with(host: 'also-chosen.test').users.run
    expect(requested_hosts).to contain_exactly('chosen-by-the-caller.test', 'also-chosen.test')
  end
end
