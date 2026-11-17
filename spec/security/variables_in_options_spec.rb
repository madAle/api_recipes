require 'spec_helper'
require 'api_recipes/cli'
require 'tmpdir'

# The protocol, the port and the other options of a request can be written
# with {variables}. The value comes from the application, at run time, and a
# portable recipe can give it a default: neither can move a request or a
# credential somewhere else.
describe 'A variable in the protocol, in the port or in another option of a request' do
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:service) do
    { protocol: '{protocol}', host: 'svc.example.test', port: '{port}',
      variables: { protocol: { default: 'https' }, port: { default: 443 }, verb: { default: 'get' } },
      endpoints: { ping: { verb: '{verb}' } } }
  end

  before do
    stub_request(:any, /example\.test/).to_return(status: 200, body: '{}', headers: json)
    configure_test_apis(svc: service)
  end

  it 'cannot hold anything but a protocol, a port or a verb: no host, no user, no path, no line break' do
    hostile = [{ port: '80@evil.example.test' }, { port: '80/../admin' }, { port: "80\r\nHost: evil.example.test" },
               { port: '99999' }, { port: '-1' }, { protocol: 'https://evil.example.test/#' }, { protocol: 'file' },
               { protocol: "http\nX: evil.example.test" }, { verb: "GET /admin HTTP/1.1\r\nHost: evil.example.test" },
               { verb: 'get evil' }]
    hostile.each do |values|
      expect { ApiRecipes.svc.with(variables: values).ping.run }.to raise_error(ApiRecipes::InvalidVariable) { |error|
        expect(error.message).not_to include('evil')
      }
      expect { ApiRecipes.svc.with(variables: values).ping.url }.to raise_error(ApiRecipes::InvalidVariable) unless values.key?(:verb)
    end
    expect(WebMock).not_to have_requested(:any, /./)
  end

  it 'does not take a credential to the protocol or the port that a nearer level chooses' do
    global_values(svc: { authorization: 'Bearer APP' })
    expect { ApiRecipes.svc.with(variables: { protocol: 'http' }).ping.run }.to raise_error(ApiRecipes::CredentialOriginMismatch)
    expect { ApiRecipes.svc.with(variables: { port: 8443 }).ping.run }.to raise_error(ApiRecipes::CredentialOriginMismatch)
    client = Class.new do
      include ApiRecipes
      api :svc, variables: { port: 8080 }
    end
    expect { client.new.svc.ping.run }.to raise_error(ApiRecipes::CredentialOriginMismatch)
    expect(WebMock).not_to have_requested(:any, /./)
  end

  describe 'in a portable recipe' do
    def summary_of(protocol_default)
      Dir.mktmpdir do |dir|
        variables = "    protocol:#{protocol_default ? "\n      default: #{protocol_default}" : ' {}'}\n    verb:\n      default: delete\n"
        path = File.join(dir, 'shop.recipe.yml')
        File.write(path, "shop:\n  recipe:\n    name: shop\n    version: '1.0.0'\n  variables:\n#{variables}" \
                         "  protocol: '{protocol}'\n  host: shop.example.test\n  endpoints:\n    orders:\n      verb: '{verb}'\n")
        _, out, err = run_cli('install', path, '--to', File.join(dir, 'out'), '--yes')
        out + err
      end
    end

    it 'is shown to whoever installs it: http by default, or left to the application' do
      expect(summary_of('http')).to include('the protocol is http by default: a credential you assign travels without encryption',
                                            'with defaults: http://shop.example.test')
      expect(summary_of(nil)).to include('the protocol is a variable without a default: the application chooses it')
      expect(summary_of('https')).not_to include('warning')
    end

    it 'never hides a call that is not a GET: a verb given by a variable is listed with the others' do
      expect(summary_of('https')).to include('1, of which 1 is not GET', '{verb} (DELETE by default)  shop.orders')
    end
  end
end
