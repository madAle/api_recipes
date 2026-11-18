require 'spec_helper'
require 'api_recipes/cli'
require 'timeout'
require 'json'

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

    it 'that is the first of a very long chain is refused, instead of being followed for minutes' do
      parameters = (1..3000).to_h { |n| ["p#{n}", { '$ref' => "#/components/parameters/p#{n + 1}" }] }
      parameters['p3001'] = { 'name' => 'q', 'in' => 'query' }
      operations = (1..300).to_h { |n| ["/a#{n}", { 'get' => { 'parameters' => [{ '$ref' => '#/components/parameters/p1' }] } }] }
      text = JSON.generate(YAML.safe_load(openapi('paths' => operations, 'components' => { 'parameters' => parameters })))
      code, out, err = Timeout.timeout(10) { import(text) }
      expect([code, out]).to eq([1, ''])
      expect(err).to match(/more than 64 \$ref in a chain/)
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
      expect(YAML.safe_load(out)).to eq('svc' => { 'recipe' => { 'name' => 'svc', 'version' => '1.0.0', 'format' => 1 }, 'host' => 'api.example.test', 'endpoints' => { 'users' => nil } })
      expect(out.lines.size).to eq(9)
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
        configure_test_apis(ApiRecipes::CLI::Description.read(recipe, erb: true))
        expect(ApiRecipes.svc.users.url.to_s).to eq('https://api.example.test/users')
        expect(File.exist?(marker)).to be(false)
      ensure
        ENV.delete('MARKER')
      end
    end

    it 'with the line separators of Unicode never adds a key to the recipe' do
      ["\u2028", "\u2029", "\u0085", "\v", "\f"].each do |separator|
        hostile = "T#{separator}evil: {host: evil.test, endpoints: {users: {}}} #"
        text = openapi('info' => { 'title' => hostile, 'version' => hostile },
                       'paths' => { '/users' => { 'get' => { 'operationId' => "x#{separator}evil:", 'parameters' => [
                         { 'name' => "q#{separator}evil: 1", 'in' => 'query' }
                       ] } } })
        code, out, = import(text, '--name', 'svc')
        expect(code).to eq(0)
        expect(YAML.safe_load(out)).to eq('svc' => { 'recipe' => { 'name' => 'svc', 'version' => '1.0.0', 'format' => 1 }, 'host' => 'api.example.test', 'endpoints' => { 'users' => nil } })
        expect(out).not_to match(/[\u2028\u2029\u0085\v\f]/)
      end
    end

    it 'that hides or reverses text is removed from the comments' do
      text = openapi('paths' => { '/users' => { 'get' => { 'operationId' => "list\u202Eevil\u200B\uFEFF" } } })
      _, out, = import(text)
      expect(out).not_to match(/[\u202E\u200B\uFEFF]/)
      expect(out).to include('# GET /users (list evil')
    end

    it 'is checked again after writing: a recipe that does not read back as intended is not written' do
      allow(ApiRecipes::CLI::Import).to receive(:one_line) { |value, *| value.to_s }
      text = openapi('paths' => { '/users' => { 'get' => { 'operationId' => "x\nevil: {host: evil.test}" } } })
      code, out, err = import(text, '--name', 'svc')
      expect([code, out]).to eq([1, ''])
      expect(err).to match(/internal error: the recipe does not read back/)
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
      ["\n", "\u2028", "\u2029", "\u0085"].each do |separator|
        code, out, err = import(openapi('servers' => [{ 'url' => "https://api.example.test/v1#{separator}host: evil.test" }]))
        expect([code, out]).to eq([1, ''])
        expect(err).to match(/control character/)
        code, out, err = import(openapi('paths' => { "/a#{separator}b: c" => { 'get' => {} } }))
        expect([code, out]).to eq([1, ''])
        expect(err).to match(/control character/)
      end
    end

    it 'that is binary data, or a name too long for YAML, is refused with a message' do
      binary = "openapi: 3.0.3\ninfo: {title: !!binary Y2Fmw6k=, version: '1'}\npaths: {/café: {get: {operationId: !!binary Y2Fmw6k=}}}\n"
      code, out, err = import(binary)
      expect([code, out]).to eq([1, ''])
      expect(err).to eq("the description contains binary data (!!binary): only text is read\n")
      code, out, err = import(openapi('paths' => { "/#{'a' * 1100}" => { 'get' => {} } }), '--name', 'svc')
      expect([code, out]).to eq([1, ''])
      expect(err).to match(/svc\.endpoints: the name of an endpoint is longer than 1000 characters/)
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

  it 'never turns a mapping or a list of the description into text, wherever it is' do
    list = Class.new(Array) { %i[to_s inspect join flatten].each { |name| define_method(name) { |*| raise 'printed' } } }
    mapping = Class.new(Hash) { %i[to_s inspect].each { |name| define_method(name) { |*| raise 'printed' } } }
    [-> { list.new([1]) }, -> { mapping.new.merge!('a' => 1) }].each do |make|
      root = {
        'openapi' => '3.0.3', 'info' => { 'title' => make.call, 'version' => make.call },
        'servers' => [{ 'url' => 'https://{v}.example.test', 'variables' => { 'v' => { 'default' => make.call, 'description' => make.call } } }],
        'security' => [{ 'k' => make.call }, { 'h' => [] }, { 'a' => [] }, make.call],
        'components' => { 'securitySchemes' => {
          'k' => { 'type' => make.call }, 'h' => { 'type' => 'http', 'scheme' => make.call },
          'a' => { 'type' => 'apiKey', 'in' => make.call, 'name' => make.call }, 'n' => { 'type' => 'apiKey', 'in' => 'header', 'name' => make.call }
        } },
        'paths' => { '/users' => {
          'parameters' => make.call, 'servers' => make.call,
          'get' => { 'operationId' => make.call, 'deprecated' => make.call, 'security' => make.call, 'responses' => make.call,
                     'parameters' => [{ 'name' => make.call, 'in' => 'query' }, { 'name' => 'q', 'in' => make.call, 'required' => make.call }, make.call] },
          'put' => 'text', 'x-other' => make.call
        } }
      }
      allow(ApiRecipes::CLI::Import::Document).to receive(:load).and_return(ApiRecipes::CLI::Import::Document.new(root))
      result = ApiRecipes::CLI::Import.new('unused', name: 'svc').call
      expect(YAML.safe_load(result.text)).to eq(
        'svc' => { 'recipe' => { 'name' => 'svc', 'version' => '1.0.0', 'format' => 1 }, 'host' => '{v}.example.test', 'endpoints' => { 'users' => nil } }
      )
      expect(result.warnings.join.length).to be < 2000
    end
  end

  it 'reads a description that says a lot with YAML aliases, within the limit' do
    levels = (1..9).map { |n| "x#{n}: &x#{n} [*x#{n - 1}, *x#{n - 1}, *x#{n - 1}, *x#{n - 1}]" }
    text = "x0: &x0 [lol]\n#{levels.join("\n")}\nopenapi: 3.0.3\ninfo: {title: *x9, version: *x9}\nservers: [{url: https://api.example.test}]\n" \
           "components: {securitySchemes: {h: {type: http, scheme: *x9}}}\n" \
           "paths:\n  /users:\n    get: {operationId: *x9, responses: *x9}\n"
    code, out, err = Timeout.timeout(10) { import(text, '--name', 'svc') }
    expect(code).to eq(0)
    expect(YAML.safe_load(out)).to eq('svc' => { 'recipe' => { 'name' => 'svc', 'version' => '1.0.0', 'format' => 1 }, 'host' => 'api.example.test', 'endpoints' => { 'users' => nil } })
    expect(err.length).to be < 2000
  end

  it 'refuses a description whose aliases describe more than ten million values' do
    levels = (1..40).map { |n| "x#{n}: &x#{n} [*x#{n - 1}, *x#{n - 1}, *x#{n - 1}, *x#{n - 1}]" }
    text = "x0: &x0 [lol]\n#{levels.join("\n")}\nopenapi: 3.0.3\ninfo: {title: T, version: '1'}\npaths: {}\n"
    code, out, err = Timeout.timeout(10) { import(text) }
    expect([code, out]).to eq([1, ''])
    expect(err).to match(/aliases.*ten million/)
  end

  it 'never prints megabytes of warnings' do
    paths = (1..3000).to_h { |n| ["/{a}b#{n}", { 'get' => {}, 'post' => {}, 'put' => {} }] }.merge('/ok' => { 'get' => {} })
    code, _, err = import(openapi('paths' => paths))
    expect(code).to eq(0)
    expect(err.lines.size).to be <= 102
    expect(err).to match(/2900 more warnings were not shown/)
  end

  it 'answers a defect of its own with a message, never with a stack trace' do
    allow(ApiRecipes::CLI::Import::Tree).to receive(:build).and_raise(NoMethodError, 'undefined method SECRET')
    code, out, err = import(openapi)
    expect([code, out]).to eq([1, ''])
    expect(err).to eq("import failed (NoMethodError): this is a defect of api_recipes, not of the description\n")
  end

  it 'refuses a key that is an alias of a huge structure, instead of computing its hash for ever' do
    levels = (1..9).map { |n| "x#{n}: &x#{n} [*x#{n - 1}, *x#{n - 1}, *x#{n - 1}, *x#{n - 1}]" }
    text = "x0: &x0 [lol]\n#{levels.join("\n")}\nopenapi: 3.0.3\ninfo: {title: T, version: '1'}\npaths:\n  /users:\n    get: {responses: {*x9 : {}}}\n"
    code, out, err = Timeout.timeout(10) { import(text) }
    expect([code, out]).to eq([1, ''])
    expect(err).to match(/keys must be plain text/)
  end

  # `import --calls` and `convert --calls` write in a comment how each endpoint
  # is called. The comment is made from the recipe just written and checked.
  describe 'the calls written beside the endpoints' do
    let(:node) { Struct.new(:name, :path_params, :endpoints) { def route? = true } }

    it 'hold only names of endpoints and of parameters: anything else is not written' do
      hostile = [node.new("a\nhost: evil.test", [], {}), node.new('b', ["<%= system('x') %>"], {}), node.new('c # d', [], {}),
                 node.new("e\u202E", [], {}), node.new('fine', ['id'], {})]
      definition = Struct.new(:endpoints).new(hostile.to_h { |one| [one.name, one] })
      expect(ApiRecipes::CLI::Calls.of(definition)).to eq(['fine'] => '.fine(id)')
    end

    it 'are written on one line each, without ERB, by the writer of import' do
      leaf = ApiRecipes::CLI::Import::Tree::Node.new('a', {}, 'GET /a', [])
      text = ApiRecipes::CLI::Import::Writer.new(name: 'svc', options: { host: 'h.test' }, nodes: [leaf],
                                                 calls: { %w[a] => ".a\nhost: evil.test <%= raise 'x' %>" }).to_yaml
      expect(text).not_to match(/<%|%>/)
      expect(YAML.safe_load(text)).to eq('svc' => { 'host' => 'h.test', 'endpoints' => { 'a' => nil } })
    end

    it 'leave the recipe as it is without them, also from a hostile description' do
      text = openapi('paths' => { '/users/{id}' => { 'get' => { 'operationId' => "x\nhost: evil.test <%= 1 %>" } },
                                  '/a b/{c-d}/{e.f}' => { 'get' => { 'summary' => "<%= 2 %>\n# .evil" } } })
      code, plain, = import(text, '--name', 'svc')
      expect([code, import(text, '--name', 'svc', '--calls').first]).to eq([0, 0])
      with_calls = import(text, '--name', 'svc', '--calls')[1]
      expect(YAML.safe_load(with_calls)).to eq(YAML.safe_load(plain))
      expect(with_calls.lines - plain.lines).to all(match(/\A +# \.[\w.?!(), ]+\n\z/))
      expect((with_calls.lines - plain.lines).map(&:strip)).to eq(['# .users.show(id)', '# .a_b.show(c_d, e_f)'])
    end
  end
end
