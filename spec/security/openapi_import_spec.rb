require 'spec_helper'
require 'api_recipes/cli'
require 'timeout'

# What a hostile OpenAPI description can do to `api_recipes import` and to the
# recipe it writes. The description comes from someone else; the recipe is
# then loaded as a local file, where ERB is evaluated.
describe 'Importing an OpenAPI description' do
  def import(text, *arguments)
    with_description(text) { |path, dir| return run_cli('import', path, *arguments) + [dir] }
  end

  describe 'a $ref' do
    it 'never makes the importer open another file or use the network' do
      ['./secret.yml#/paths/~1users', 'secret.yml', '/etc/passwd', 'https://evil.test/openapi.yml#/x',
       'file:///etc/passwd'].each do |ref|
        with_description(openapi('paths' => { '/users' => { '$ref' => ref } })) do |path, dir|
          File.write(File.join(dir, 'secret.yml'), "paths:\n  /users:\n    get: {operationId: STOLEN}\n")
          expect(File).to receive(:read).with(path, any_args).once.and_call_original
          expect(File).not_to receive(:open)
          code, out, err = run_cli('import', path)
          expect([code, out]).to eq([1, ''])
          expect(err).to match(/points to another file: bundle the description into one file first/)
          RSpec::Mocks.space.proxy_for(File).reset
        end
      end
      expect(WebMock).not_to have_requested(:any, /.*/)
    end

    it 'that goes round in a circle is an error, not an endless loop' do
      text = openapi('paths' => { '/users' => { 'get' => { 'parameters' => [{ '$ref' => '#/components/parameters/a' }] } } },
                     'components' => { 'parameters' => { 'a' => { '$ref' => '#/components/parameters/b' },
                                                         'b' => { '$ref' => '#/components/parameters/a' } } })
      code, out, err = Timeout.timeout(10) { import(text) }
      expect([code, out]).to eq([1, ''])
      expect(err).to match(/circular \$ref/)
    end
  end

  describe 'free text of the description' do
    let(:hostile) { "x\nhost: evil.test\nendpoints:\n  evil: {path: /steal}\r\n# " }

    it 'with line breaks never adds a key to the recipe' do
      text = openapi('info' => { 'title' => hostile, 'version' => hostile },
                     'paths' => { '/users' => { 'get' => { 'operationId' => hostile, 'parameters' => [
                       { 'name' => hostile, 'in' => 'query' }
                     ] } } })
      code, out, = import(text, '--name', 'svc')
      expect(code).to eq(0)
      expect(YAML.safe_load(out)).to eq('svc' => { 'host' => 'api.example.test', 'endpoints' => { 'users' => nil } })
      expect(out.lines.size).to eq(5)
    end

    it 'with ERB is removed from the comments, and loading the recipe as a file runs nothing' do
      erb = "<%= File.write(ENV.fetch('MARKER'), 'evaluated') %><% raise 'evaluated' %>"
      text = openapi('info' => { 'title' => "Shop #{erb}", 'version' => erb },
                     'paths' => { '/users' => { 'get' => { 'operationId' => "list#{erb}", 'parameters' => [
                       { 'name' => "q#{erb}", 'in' => 'query' }
                     ] } } })
      Dir.mktmpdir do |dir|
        marker = File.join(dir, 'marker')
        recipe = File.join(dir, 'svc.yml')
        ENV['MARKER'] = marker
        code, = import(text, '--name', 'svc', '--output', recipe)
        expect(code).to eq(0)
        expect(File.read(recipe)).not_to match(/<%|%>/)
        ApiRecipes.configure do |config|
          config.logger = Logger.new(IO::NULL)
          config.apis_files_paths = [recipe]
        end
        expect(ApiRecipes.svc.users.url.to_s).to eq('https://api.example.test/users')
        expect(File.exist?(marker)).to be(false)
      ensure
        ENV.delete('MARKER')
      end
    end

    it 'with ERB split so that removing a part leaves another is still removed' do
      text = openapi('info' => { 'title' => "a <<%%= 1 %%>> b <<%% c", 'version' => '1' })
      _, out, = import(text)
      expect(out).not_to match(/<%|%>/)
    end
  end

  describe 'a value of the recipe' do
    {
      'the address of the server' => { 'servers' => [{ 'url' => 'https://<%= 1 %>.example.test' }] },
      'the base path of the server' => { 'servers' => [{ 'url' => 'https://api.example.test/<%= 1 %>' }] },
      'the default of a variable' => { 'servers' => [{ 'url' => 'https://{shop}.example.test',
                                                        'variables' => { 'shop' => { 'default' => '<%= 1 %>' } } }] },
      'a segment of a path' => { 'paths' => { '/users/<%= 1 %>/x' => { 'get' => {} } } },
      'the name of an apiKey' => { 'components' => { 'securitySchemes' => { 'k' => {
        'type' => 'apiKey', 'in' => 'header', 'name' => '<%= 1 %>'
      } } }, 'security' => [{ 'k' => [] }] }
    }.each do |what, overrides|
      it "with ERB in #{what} is refused, and the message says where" do
        code, out, err = import(openapi(overrides), '--name', 'svc')
        expect([code, out]).to eq([1, ''])
        expect(err).to match(/svc\.[a-z_.]+.*contains <%/)
      end
    end

    it 'with a line break is refused' do
      code, out, err = import(openapi('servers' => [{ 'url' => "https://api.example.test/v1\nhost: evil.test" }]))
      expect([code, out]).to eq([1, ''])
      expect(err).to match(/control character/)
    end

    it 'is never built by the importer from a description of ERB in a parameter name' do
      _, out, = import(openapi('paths' => { '/users/{<%= 1 %>}' => { 'get' => {} } }), '--name', 'svc')
      expect(out).not_to include('<%')
      expect(YAML.safe_load(out).dig('svc', 'endpoints', 'users', 'endpoints', 'show', 'path')).to match(%r{\A/:\w+\z})
    end
  end

  it 'writes endpoint names made only of letters, digits and underscores' do
    paths = ['/a b', '/a.b/c', '/é', '/<x>', '/a"b', "/a'b", '/A-B', '/x:y', '/{p}/q-r', '/%41'].to_h do |path|
      [path, { 'get' => {} }]
    end
    code, out, = import(openapi('paths' => paths), '--name', 'svc')
    expect(code).to eq(0)
    names = lambda do |endpoints|
      endpoints.to_a.flat_map { |name, options| [name] + names.call((options || {})['endpoints']) }
    end
    expect(names.call(YAML.safe_load(out).dig('svc', 'endpoints'))).to all(match(/\A[a-z0-9_]+\z/))
  end

  it 'refuses a description with a Ruby object' do
    code, out, err = import("openapi: 3.0.3\ninfo: !ruby/object:OpenStruct {title: T}\npaths: {}\n")
    expect([code, out]).to eq([1, ''])
    expect(err).to match(/not plain data/)
  end

  it 'reads a description made huge with YAML aliases without expanding or printing it' do
    levels = (1..40).map { |n| "x#{n}: &x#{n} [*x#{n - 1}, *x#{n - 1}, *x#{n - 1}, *x#{n - 1}]" }
    bomb = "x0: &x0 [lol]\n#{levels.join("\n")}\n"
    text = "#{bomb}openapi: 3.0.3\ninfo: {title: *x40, version: *x40}\nservers: [{url: https://api.example.test, variables: {v: {default: *x40, description: *x40}}}]\n" \
           "security: *x40\ncomponents: {securitySchemes: {k: {type: *x40}}}\n" \
           "paths:\n  /users:\n    parameters: *x40\n    get: {operationId: *x40, deprecated: *x40, security: *x40, responses: *x40, parameters: [{name: *x40, in: query}]}\n"
    code, out, err = Timeout.timeout(10) { import(text, '--name', 'svc') }
    expect(code).to eq(0)
    expect(YAML.safe_load(out)).to eq('svc' => { 'host' => 'api.example.test', 'endpoints' => { 'users' => nil } })
    expect(err.length).to be < 2000
  end

  it 'refuses a key that is an alias of a huge structure, instead of computing its hash for ever' do
    levels = (1..40).map { |n| "x#{n}: &x#{n} [*x#{n - 1}, *x#{n - 1}, *x#{n - 1}, *x#{n - 1}]" }
    text = "x0: &x0 [lol]\n#{levels.join("\n")}\nopenapi: 3.0.3\ninfo: {title: T, version: '1'}\npaths:\n  /users:\n    get: {responses: {*x40 : {}}}\n"
    code, out, err = Timeout.timeout(10) { import(text) }
    expect([code, out]).to eq([1, ''])
    expect(err).to match(/keys must be plain text/)
  end
end
