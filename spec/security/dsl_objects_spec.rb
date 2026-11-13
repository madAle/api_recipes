require 'spec_helper'
require 'json'
require 'pp'

# What the objects of the DSL show, write and let Ruby do with them.
describe 'Objects of the DSL' do
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:options) { { headers: { 'X-Private' => 'SECRET-HEADER' }, params: { token: 'SECRET-PARAM' } } }

  before do
    configure_test_apis(
      svc: { host: 'api.example.test', auth: { type: 'query', name: 'key' },
             default_headers: { 'X-Default' => 'SECRET-DEFAULT' },
             endpoints: { users: { endpoints: { show: { path: '/:id' } } },
                          to_ary: nil, to_str: nil, encode_with: nil, singleton_method_added: nil, to_json: nil }.merge(
                            'inspect' => nil
                          ) }
    )
    stub_request(:any, /\.test/).to_return(status: 200, body: '{"ok":true}', headers: json)
    ApiRecipes.svc.authorization = 'Bearer SECRET-TOKEN'
  end

  def objects
    [ApiRecipes.svc, ApiRecipes.svc.users, ApiRecipes.svc.users.show(1, **options),
     ApiRecipes.svc.with(authorization: 'Bearer SECRET-WITH', default_headers: { 'X-W' => 'SECRET-WITH' }),
     ApiRecipes.svc.users.show(1).with(timeout: 5)]
  end

  it 'refuses every serialization of an Api and of an Endpoint' do
    objects.each do |object|
      expect { Marshal.dump(object) }.to raise_error(TypeError)
      expect { YAML.dump(object) }.to raise_error(TypeError)
      expect { JSON.generate(object) }.to raise_error(TypeError)
      expect { object.to_json }.to raise_error(TypeError)
      expect { object.as_json }.to raise_error(TypeError)
    end
  end

  it 'shows no option, header, credential or query whatever way they are printed' do
    shown = objects.flat_map do |object|
      [object.inspect, object.to_s, "#{object}", PP.pp(object, +''), object.definition.inspect, object.definition.to_s]
    end
    expect(shown.join("\n")).not_to match(/SECRET|key=|token/)
  end

  it 'keeps the credential sent in the query out of url, and adds it only when the request is sent' do
    expect(ApiRecipes.svc.users.url.to_s).to eq('https://api.example.test/users')
    expect(ApiRecipes.svc.users.show(1, params: { a: 1 }).url.to_s).to eq('https://api.example.test/users/1')
    stub_request(:get, %r{api\.example\.test/users}).to_return(status: 200, body: '{}', headers: json)
    ApiRecipes.svc.users.run
    expect(WebMock).to have_requested(:get, 'https://api.example.test/users').with(query: { 'key' => 'Bearer SECRET-TOKEN' })
  end

  it 'holds no credential in the definition, whatever way it is read' do
    definition = ApiRecipes.svc.definition
    shown = [definition.inspect, PP.pp(definition, +''), definition.to_h.inspect, definition.endpoints.inspect]
    expect(shown.join).not_to include('SECRET-TOKEN')
    expect(ApiRecipes.svc.users.show(1, **options).url.to_s).to eq('https://api.example.test/users/1')
  end

  it 'does not change how Ruby treats the parent of an endpoint named after an implicit conversion' do
    parent = ApiRecipes.svc
    expect([parent].flatten).to eq([parent])
    expect(Array(parent)).to eq([parent])
    first, second = parent
    expect([first, second]).to eq([parent, nil])
    expect { "text" + parent }.to raise_error(TypeError)
    expect { File.join('a', parent) }.to raise_error(TypeError)
    expect(parent.respond_to?(:to_ary)).to be(false)
    expect(parent.respond_to?(:to_str)).to be(false)
    expect(WebMock).not_to have_requested(:any, /.*/)
  end

  it 'still reaches an endpoint with such a name with [] and sends its request' do
    ApiRecipes.svc[:to_ary].run
    ApiRecipes.svc['to_str'].run
    ApiRecipes.svc[:encode_with].run
    ApiRecipes.svc[:singleton_method_added].run
    ApiRecipes.svc[:to_json].run
    %w[to_ary to_str encode_with singleton_method_added to_json].each do |name|
      expect(WebMock).to have_requested(:get, "https://api.example.test/#{name}").with(query: { 'key' => 'Bearer SECRET-TOKEN' })
    end
  end

  it 'does not let an endpoint named inspect hide the safe inspect' do
    expect(ApiRecipes.svc.inspect).to start_with('#<ApiRecipes::Api')
    expect(ApiRecipes.svc[:inspect].inspect).to start_with('#<ApiRecipes::Endpoint')
  end

  describe 'a response' do
    let(:response) { ApiRecipes.svc.users.show(7, **options).run }

    it 'omits the credential sent in the query from uri' do
      expect(response.uri.to_s).to eq('https://api.example.test/users/7?token=SECRET-PARAM')
      expect(response.uri.to_s).not_to include('SECRET-TOKEN')
      expect(response.uri.query).not_to include('key=')
    end

    it 'refuses serialization, because the http.rb response holds the request with the credential' do
      expect { YAML.dump(response) }.to raise_error(TypeError)
      expect { Marshal.dump(response) }.to raise_error(TypeError)
      expect { YAML.dump([response]) }.to raise_error(TypeError)
    end

    # Marshal.dump already fails on a Proc inside the http.rb response and an
    # ActiveSupport to_json goes through as_json, so the methods are called directly.
    it 'refuses marshal_dump and as_json on their own, and points to data' do
      expect { response.marshal_dump }.to raise_error(TypeError)
      expect { response.as_json }.to raise_error(TypeError, /response\.data/)
    end

    it 'does not expose the request and does not show it in inspect' do
      expect(response).not_to respond_to(:request)
      expect(response).not_to respond_to(:deconstruct_keys)
      expect(response.inspect).not_to match(/SECRET|key=/)
      expect(PP.pp(response, +'')).not_to match(/SECRET|key=/)
    end
  end

  describe 'an error about the response' do
    it 'carries no credential, query, header or body in its message' do
      stub_request(:any, /\.test/).to_return(status: 500, body: 'personal data: SECRET-BODY')
      expect { ApiRecipes.svc.users.show(7, **options).run }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected) { |error|
        expect(error.message).not_to match(/SECRET|key=|token=/)
        expect(error.response.body.to_s).to include('SECRET-BODY')
        expect(error.inspect).not_to match(/SECRET-TOKEN|key=/)
      }
    end
  end
end
