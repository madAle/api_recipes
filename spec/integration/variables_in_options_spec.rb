require 'spec_helper'

# A {variable} in the options that are read when a request is sent: protocol,
# port, timeout, on_bad_code, mime_type, verb and ok_code. Its value is looked
# for as the one of any variable, and checked for the option it ends up in.
describe 'Variables in the options of a request' do
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:service) do
    { protocol: '{protocol}', host: '{host}', port: '{port}', timeout: '{timeout}', on_bad_code: '{on_bad_code}',
      variables: { protocol: { default: 'https' }, host: { default: 'svc.example.test' }, port: { default: 443 },
                   timeout: { default: 4 }, on_bad_code: { default: 'raise' }, verb: { default: 'post' },
                   created: { default: 201 }, mime: { default: 'application/json' } },
      endpoints: { ping: nil,
                   things: { endpoints: { create: { path: '', verb: '{verb}', ok_code: '{created}', mime_type: '{mime}' } } } } }
  end

  before do
    stub_request(:any, /example\.test/).to_return(status: 200, body: '{}', headers: json)
    configure_test_apis(svc: service)
  end

  def problems
    yield
    []
  rescue ApiRecipes::ConfigurationError => e
    e.errors
  end

  describe 'protocol and port' do
    it 'take the default of their variables, and leave out the port of the protocol' do
      expect(ApiRecipes.svc.ping.url.to_s).to eq('https://svc.example.test/ping')
    end

    it 'take the value of the chain' do
      api = ApiRecipes.svc.with(variables: { protocol: 'http', host: 'local.example.test', port: 3000 })
      expect(api.ping.url.to_s).to eq('http://local.example.test:3000/ping')
      api.ping.run
      expect(WebMock).to have_requested(:get, 'http://local.example.test:3000/ping')
    end

    it 'take the value given when the application starts' do
      global_values(svc: { variables: { protocol: 'http', port: '8080' } })
      expect(ApiRecipes.svc.ping.url.to_s).to eq('http://svc.example.test:8080/ping')
    end

    it 'take the value of a class and of an object, the nearest first' do
      klass = Class.new do
        include ApiRecipes
        api :svc, variables: { protocol: 'http', port: 81 }
      end
      expect(klass.svc.ping.url.to_s).to eq('http://svc.example.test:81/ping')
      object = klass.new
      object.svc.variables = { port: 82 }
      expect(object.svc.ping.url.to_s).to eq('http://svc.example.test:82/ping')
      expect(klass.svc.with(variables: { port: 80 }).ping.url.to_s).to eq('http://svc.example.test/ping')
    end

    it 'raise MissingVariable when no level gives a value' do
      configure_test_apis(svc: { host: 'h.example.test', port: '{port}', variables: { port: {} }, endpoints: { ping: nil } })
      expect { ApiRecipes.svc.ping.url }.to raise_error(ApiRecipes::MissingVariable, /port/)
      expect { ApiRecipes.svc.ping.run }.to raise_error(ApiRecipes::MissingVariable, /port/)
    end

    it 'refuse a value that is not a protocol or a port, and never show it' do
      { { protocol: 'ftp' } => /protocol.*http or https/, { port: '80@evil.example.test' } => /port.*integer from 1 to 65535/,
        { port: 0 } => /port/, { port: 70_000 } => /port/, { protocol: 'https://evil.example.test/#' } => /protocol/ }.each do |values, message|
        expect { ApiRecipes.svc.with(variables: values).ping.url }.to raise_error(ApiRecipes::InvalidVariable, message) { |error|
          expect(error.message).not_to include('evil')
        }
      end
      expect(WebMock).not_to have_requested(:any, /./)
    end
  end

  describe 'timeout, on_bad_code, mime_type, verb and ok_code' do
    it 'are resolved when the request is built' do
      context = ApiRecipes.svc.with(variables: { timeout: '2.5' }).instance_variable_get(:@context)
      create = context.definition.endpoints[:things].endpoints[:create]
      expect(context.setting(:timeout, create)).to eq(2.5)
      expect(context.setting(:on_bad_code)).to eq('raise')
      expect(context.setting(:ok_code, create)).to eq(201)
      expect(context.setting(:mime_type, create)).to eq('application/json')
    end

    it 'send the request with the verb of the variable' do
      stub_request(:any, 'https://svc.example.test/things').to_return(status: 201, body: '{}', headers: json)
      ApiRecipes.svc.things.create.run
      ApiRecipes.svc.with(variables: { verb: 'put' }).things.create.run
      expect(WebMock).to have_requested(:post, 'https://svc.example.test/things')
      expect(WebMock).to have_requested(:put, 'https://svc.example.test/things')
    end

    it 'decide what a bad status does' do
      stub_request(:get, 'https://svc.example.test/ping').to_return(status: 500, body: '{}', headers: json)
      expect { ApiRecipes.svc.ping.run }.to raise_error(ApiRecipes::Error)
      expect(ApiRecipes.svc.with(variables: { on_bad_code: 'ignore' }).ping.run.code).to eq(500)
    end

    it 'decide the status that is a success' do
      stub_request(:post, 'https://svc.example.test/things').to_return(status: 201, body: '{}', headers: json)
      expect(ApiRecipes.svc.things.create.run.code).to eq(201)
      expect { ApiRecipes.svc.with(variables: { created: 200 }).things.create.run }.to raise_error(ApiRecipes::Error)
    end

    it 'refuse a value that does not fit the option' do
      { { timeout: 0 } => /timeout.*positive number/, { timeout: 'soon' } => /timeout/, { on_bad_code: 'explode' } => /raise or ignore/ }.each do |values, message|
        expect { ApiRecipes.svc.with(variables: values).ping.run }.to raise_error(ApiRecipes::InvalidVariable, message)
      end
      { { verb: 'yell' } => /verb/, { created: 'ok' } => /status/, { mime: "a\nb" } => /control/ }.each do |values, message|
        expect { ApiRecipes.svc.with(variables: values).things.create.run }.to raise_error(ApiRecipes::InvalidVariable, message)
      end
      expect(WebMock).not_to have_requested(:any, /./)
    end
  end

  describe 'the configuration' do
    it 'refuses a variable that the api does not declare' do
      found = problems { configure_test_apis(svc: { host: 'h.test', protocol: '{proto}', port: '{p}', timeout: '{t}', endpoints: { ping: { verb: '{v}' } } }) }
      expect(found).to contain_exactly("svc.protocol: unknown variable 'proto'", "svc.port: unknown variable 'p'",
                                       "svc.timeout: unknown variable 't'", "svc.endpoints.ping.verb: unknown variable 'v'")
    end

    it 'still refuses a value that is neither valid nor a variable' do
      found = problems { configure_test_apis(svc: { host: 'h.test', protocol: 'ftp', port: 'x{', timeout: 'soon' }) }
      expect(found).to contain_exactly("svc.protocol: 'ftp' is not one of http, https", 'svc.port: must be an integer from 1 to 65535',
                                       'svc.timeout: must be a positive number')
    end

    it 'checks the default of a variable for every option that uses it' do
      found = problems do
        configure_test_apis(svc: { host: 'h.test', protocol: '{proto}', port: '{p}',
                                   variables: { proto: { default: 'ftp' }, p: { default: 'x' } }, endpoints: { ping: nil } })
      end
      expect(found).to contain_exactly("svc.variables.proto.default: is used as the protocol, which must be http or https",
                                       'svc.variables.p.default: is used as the port, which must be an integer from 1 to 65535')
    end

    it 'takes the same options in with' do
      api = ApiRecipes.svc.with(protocol: '{protocol}', port: '{port}', variables: { protocol: 'http', port: 9 })
      expect(api.ping.url.to_s).to eq('http://svc.example.test:9/ping')
    end

    it 'keeps what is written in the definition, and shows it in the routes and in inspect' do
      definition = ApiRecipes.svc.definition
      expect([definition.protocol, definition.port, definition.timeout]).to eq(['{protocol}', '{port}', '{timeout}'])
      expect(definition.routes.map { |route| [route.call, route.verb.to_s, route.url] })
        .to include(['svc.things.create', '{verb}', '{protocol}://{host}:{port}/things'])
      expect(ApiRecipes.svc.things.create.inspect).to eq('#<ApiRecipes::Endpoint svc.things.create POST https://svc.example.test/things>')
    end
  end

  describe 'a credential' do
    before { global_values(svc: { authorization: 'Bearer APP' }) }

    it 'goes where the level that gave it sends it' do
      ApiRecipes.svc.ping.run
      expect(WebMock).to have_requested(:get, 'https://svc.example.test/ping').with(headers: { 'Authorization' => 'Bearer APP' })
    end

    it 'does not follow a nearer level that changes the protocol or the port' do
      expect { ApiRecipes.svc.with(variables: { protocol: 'http' }).ping.run }.to raise_error(ApiRecipes::CredentialOriginMismatch)
      expect { ApiRecipes.svc.with(variables: { port: 8443 }).ping.run }.to raise_error(ApiRecipes::CredentialOriginMismatch)
      expect(WebMock).not_to have_requested(:any, /./)
    end

    it 'is sent when that level gives its own' do
      ApiRecipes.svc.with(variables: { protocol: 'http', port: 8080 }, authorization: 'Bearer MINE').ping.run
      expect(WebMock).to have_requested(:get, 'http://svc.example.test:8080/ping').with(headers: { 'Authorization' => 'Bearer MINE' })
    end
  end
end
