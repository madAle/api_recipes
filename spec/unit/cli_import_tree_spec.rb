require 'spec_helper'
require 'api_recipes/cli'

describe ApiRecipes::CLI::Import::Tree do
  let(:ok) { { 'responses' => { '200' => { 'description' => 'ok' } } } }

  def document(paths)
    ApiRecipes::CLI::Import::Document.parse(openapi('paths' => paths))
  end

  def build(paths, **options)
    described_class.build(document(paths), **options)
  end

  # { 'GET /a' => options } for the operations of a description given as
  # 'VERB /path' strings or as a Hash of paths.
  def operations(*list)
    list.each_with_object({}) do |entry, paths|
      verb, path = entry.split(' ', 2)
      (paths[path] ||= {})[verb.downcase] = ok
    end
  end

  def find(nodes, *names)
    node = nil
    names.each do |name|
      node = nodes.find { |candidate| candidate.name == name } or raise "no node #{names.join('.')}"
      nodes = node.children
    end
    node
  end

  it 'builds the tree of the design example' do
    result = described_class.build(ApiRecipes::CLI::Import::Document.load(fixture_openapi('github_small.yml')))
    expect(tree_as_hash(result.nodes)).to eq(
      'users' => { children: {
        'show' => { path: '/:username' }, 'repos' => { path: '/:username/repos' }
      } },
      'repos' => { route: false, children: {
        'issues' => { path: '/:owner/:repo/issues', children: {
          'create' => { path: '', verb: 'post', ok_code: 201 },
          'show' => { path: '/:issue_number' },
          'update' => { path: '/:issue_number', verb: 'patch' }
        } }
      } }
    )
    expect(result.warnings).to eq([])
    expect([result.operations, result.paths, result.skipped]).to eq([7, 5, 0])
  end

  it 'keeps every operation of the design example reachable exactly once' do
    doc = ApiRecipes::CLI::Import::Document.load(fixture_openapi('github_small.yml'))
    expect(imported_operations(described_class.build(doc).nodes)).to match_array(operations_of(doc))
  end

  {
    'the root path' => ['GET /', 'POST /', 'GET /status'],
    'a path made of parameters only' => ['GET /{id}', 'DELETE /{id}', 'GET /{id}/{other}'],
    'a parameter with a suffix' => ['GET /files/{name}.json', 'GET /files/{name}.{format}'],
    'a colon after a parameter' => ['POST /operations/{name}:cancel', 'GET /operations/{name}'],
    'a colon in a name' => ['GET /v1:batch', 'POST /v1:batch/{id}:run'],
    'a trailing slash beside the same path without it' => ['GET /users', 'GET /users/', 'POST /users/', 'GET /users/{id}'],
    'only a trailing slash' => ['GET /items/', 'GET /items/{id}/'],
    'parameters with different names in the same place' => ['GET /a/{x}', 'GET /a/{y}/b', 'GET /a/{x}/b'],
    'a segment named like an operation' => ['POST /issues', 'GET /issues/create', 'GET /issues/{id}', 'GET /issues/show'],
    'names of Ruby methods and of YAML values' => ['GET /send', 'GET /class', 'GET /with', 'GET /on', 'GET /no',
                                                   'GET /null', 'GET /404', 'GET /true', 'GET /definition/run'],
    'names that need to be rewritten' => ['GET /userProfiles/{user-id}/API-Keys', 'GET /a.b/c d', 'GET /é/{x}'],
    'a parameter name used twice' => ['GET /a/{id}/b/{id}', 'GET /c/{id}/{id}'],
    'every verb on a name and on a parameter' => %w[GET PUT POST DELETE OPTIONS HEAD PATCH TRACE].flat_map do |verb|
      ["#{verb} /things", "#{verb} /things/{id}"]
    end,
    'deep nesting' => ['GET /a/{a}/b/{b}/c/{c}/d', 'PUT /a/{a}/b/{b}/c/{c}/d/{d}', 'GET /a']
  }.each do |what, list|
    it "keeps every operation reachable exactly once with #{what}" do
      paths = operations(*list)
      result = build(paths)
      expect(imported_operations(result.nodes)).to match_array(operations_of(document(paths)))
      expect(result.operations).to eq(list.size)
    end
  end

  describe 'the names of operations' do
    let(:result) do
      build(operations(*%w[GET PUT POST DELETE OPTIONS HEAD PATCH TRACE].flat_map do |verb|
        ["#{verb} /things", "#{verb} /things/{id}"]
      end))
    end

    it 'follow the table of verbs' do
      things = find(result.nodes, 'things')
      expect(things.options).to eq({})
      expect(things.children.to_h { |node| [node.name, node.options.slice(:path, :verb)] }).to eq(
        'replace_all' => { path: '', verb: 'put' }, 'create' => { path: '', verb: 'post' },
        'delete_all' => { path: '', verb: 'delete' }, 'options' => { path: '', verb: 'options' },
        'head' => { path: '', verb: 'head' }, 'update_all' => { path: '', verb: 'patch' },
        'trace' => { path: '', verb: 'trace' },
        'show' => { path: '/:id' }, 'replace' => { path: '/:id', verb: 'put' },
        'post' => { path: '/:id', verb: 'post' }, 'delete' => { path: '/:id', verb: 'delete' },
        'options_one' => { path: '/:id', verb: 'options' }, 'head_one' => { path: '/:id', verb: 'head' },
        'update' => { path: '/:id', verb: 'patch' }, 'trace_one' => { path: '/:id', verb: 'trace' }
      )
    end
  end

  it 'puts the operations of a path without a name at the first level' do
    result = build(operations('GET /', 'POST /', 'GET /{id}', 'DELETE /{id}'))
    expect(tree_as_hash(result.nodes)).to eq(
      'root' => { path: '' }, 'create' => { path: '', verb: 'post' },
      'show' => { path: '/:id' }, 'delete' => { path: '/:id', verb: 'delete' }
    )
  end

  it 'makes a group of a node whose path has no GET' do
    result = build(operations('POST /jobs', 'GET /jobs/{id}/logs'))
    expect(tree_as_hash(result.nodes)).to eq(
      'jobs' => { route: false, children: {
        'create' => { path: '', verb: 'post' }, 'logs' => { path: '/:id/logs' }
      } }
    )
    expect(find(result.nodes, 'jobs').comment).to be_nil
  end

  it 'writes names in lower case with underscores, and keeps the real segment in path' do
    result = build(operations('GET /userProfiles/{user-id}/API-Keys', 'GET /a.b', 'GET /plain', 'GET /HTMLPages'))
    expect(tree_as_hash(result.nodes)).to eq(
      'user_profiles' => { path: '/userProfiles', route: false, children: {
        'api_keys' => { path: '/:user_id/API-Keys' }
      } },
      'a_b' => { path: '/a.b' }, 'plain' => {}, 'html_pages' => { path: '/HTMLPages' }
    )
  end

  it 'writes a colon of the fixed text with a backslash' do
    result = build(operations('POST /operations/{name}:cancel', 'GET /v1:batch'))
    expect(find(result.nodes, 'operations', 'post').options).to eq(path: '/:name\\:cancel', verb: 'post')
    expect(find(result.nodes, 'v1_batch').options).to eq(path: '/v1\\:batch')
  end

  it 'gives a number to the second parameter with the same name in one path' do
    result = build(operations('GET /c/{id}/{id}', 'GET /d/{a-b}/{a_b}/e'))
    expect(find(result.nodes, 'c', 'show').options).to eq(path: '/:id/:id_2')
    expect(find(result.nodes, 'd', 'e').options).to eq(path: '/:a_b/:a_b_2/e')
  end

  it 'gives a number to the second of two siblings with the same name, and says so' do
    result = build(operations('POST /issues', 'GET /issues/create', 'GET /a-b', 'GET /a_b', 'GET /a.b'))
    issues = find(result.nodes, 'issues')
    expect(issues.children.map { |node| [node.name, node.options] }).to eq(
      [['create_2', { path: '', verb: 'post' }], ['create', {}]]
    )
    expect(result.nodes.map(&:name)).to eq(%w[issues a_b a_b_2 a_b_3])
    expect(result.warnings).to include(match(/issues.*'create'.*'create_2'/), match(/'a_b'.*'a_b_2'/), match(/'a_b_3'/))
  end

  it 'still writes a name that is a method or is not a method name, and says how to reach it' do
    result = build(operations('GET /with', 'GET /users/run', 'GET /404', 'GET /fine'))
    expect(result.nodes.map(&:name)).to eq(%w[with users 404 fine])
    expect(result.warnings).to include(match(/'with'.*existing method: reach it with \['with'\]/),
                                       match(/'users\.run'.*reach it with \['run'\]/),
                                       match(/'404' is not the name of a method: reach it with \['404'\]/))
    expect(result.warnings.grep(/fine/)).to eq([])
  end

  describe 'ok_code' do
    def ok_code(responses)
      result = build({ '/things' => { 'post' => { 'responses' => responses } } })
      find(result.nodes, 'things', 'create').options[:ok_code]
    end

    it 'is the documented 2xx status, or the list when there are several' do
      expect(ok_code('201' => {}, '400' => {})).to eq(201)
      expect(ok_code('200' => {}, '202' => {}, '404' => {})).to eq([200, 202])
      expect(ok_code('204' => {}, '201' => {})).to eq([201, 204])
    end

    it 'is left out when 200 is the only one, when there is none and when it is generic' do
      expect(ok_code('200' => {})).to be_nil
      expect(ok_code('404' => {})).to be_nil
      expect(ok_code('2XX' => {}, 'default' => {})).to be_nil
      expect(ok_code({})).to be_nil
      expect(build({ '/things' => { 'post' => {} } }).operations).to eq(1)
    end

    it 'reads the statuses that YAML gave as numbers' do
      doc = ApiRecipes::CLI::Import::Document.parse(
        "openapi: 3.0.3\ninfo: {title: T, version: '1'}\npaths:\n  /things:\n    post:\n      responses:\n        201: {description: c}\n        202: {description: a}\n"
      )
      expect(find(described_class.build(doc).nodes, 'things', 'create').options[:ok_code]).to eq([201, 202])
    end
  end

  describe 'the comment of an operation' do
    it 'has the verb and the original path' do
      result = build(operations('GET /users/{username}', 'POST /users'))
      expect(find(result.nodes, 'users', 'show').comment).to eq('GET /users/{username}')
      expect(find(result.nodes, 'users', 'create').comment).to eq('POST /users')
    end

    it 'adds the operationId, deprecated and the query parameters, with a star on the required ones' do
      paths = {
        '/users' => {
          'parameters' => [{ 'name' => 'page', 'in' => 'query' }, { '$ref' => '#/components/parameters/per_page' },
                           { 'name' => 'X-Trace', 'in' => 'header' }],
          'get' => { 'operationId' => 'users/list', 'deprecated' => true,
                     'parameters' => [{ 'name' => 'q', 'in' => 'query', 'required' => true },
                                      { 'name' => 'page', 'in' => 'query', 'required' => true }] }
        }
      }
      text = openapi('paths' => paths, 'components' => { 'parameters' => {
                       'per_page' => { 'name' => 'per_page', 'in' => 'query' }
                     } })
      result = described_class.build(ApiRecipes::CLI::Import::Document.parse(text))
      expect(find(result.nodes, 'users').comment)
        .to eq('GET /users (users/list; deprecated; query: page*, per_page, q*)')
    end
  end

  describe 'the filters' do
    let(:paths) { operations('GET /users', 'GET /repos', 'POST /repos', 'GET /repos/{id}', 'GET /repos/{id}/issues', 'GET /orgs/{o}/repos') }

    it 'keep only the paths that match, with or without the first slash' do
      ['repos/*', '/repos/*'].each do |glob|
        result = build(paths, only: [glob])
        expect(imported_operations(result.nodes)).to match_array([['GET', '/repos/P1'], ['GET', '/repos/P1/issues']])
        expect([result.operations, result.skipped]).to eq([2, 4])
      end
    end

    it 'take several patterns, and a star that crosses slashes' do
      expect(build(paths, only: ['users', 'repos*']).operations).to eq(5)
      expect(build(paths, only: ['*repos']).operations).to eq(3)
      expect(build(paths, except: ['repos/*', 'users']).operations).to eq(3)
      expect(build(paths, only: ['repos*'], except: ['*issues']).operations).to eq(3)
    end

    it 'take every other character of a pattern as it is' do
      expect(build(paths, only: ['repos/{id}']).operations).to eq(1)
      expect(build(paths, only: ['repos/.id.']).operations).to eq(0)
      expect(build(paths, only: ['repo?']).operations).to eq(0)
    end
  end

  it 'leaves out what the path syntax of the gem cannot write, and says which' do
    result = build(operations('GET /a/{id}_meta', 'GET /b/{x}v2/c', 'GET /fine/{id}'))
    expect(imported_operations(result.nodes)).to eq([['GET', '/fine/P1']])
    expect(result.operations).to eq(1)
    expect(result.warnings).to include(match(%r{GET '/a/\{id\}_meta' cannot be written}),
                                       match(%r{GET '/b/\{x\}v2/c' cannot be written}))
  end

  it 'ignores what is not an operation, and says once that servers of paths are not used' do
    paths = { '/a' => { 'get' => ok, 'summary' => 'text', 'x-other' => {}, 'servers' => [{ 'url' => 'https://a.test' }] },
              '/b' => { 'get' => ok.merge('servers' => [{ 'url' => 'https://b.test' }]), 'post' => 'not a mapping' },
              'no-slash' => { 'get' => ok }, '/c' => 'not a mapping' }
    result = build(paths)
    expect(result.nodes.map(&:name)).to eq(%w[a b])
    expect(result.warnings.grep(/servers/).size).to eq(1)
    expect(result.warnings).to include(match(/'no-slash'/), match(%r{'/c'}))
  end

  it 'follows a $ref to a path item' do
    text = openapi('paths' => { '/users' => { '$ref' => '#/x-items/users' } },
                   'x-items' => { 'users' => { 'get' => ok } })
    result = described_class.build(ApiRecipes::CLI::Import::Document.parse(text))
    expect(result.nodes.map(&:name)).to eq(['users'])
  end

  it 'builds nothing, without failing, when there are no paths' do
    expect(build({}).nodes).to eq([])
    doc = ApiRecipes::CLI::Import::Document.parse(openapi.sub(/^paths:.*\z/m, ''))
    expect(described_class.build(doc).nodes).to eq([])
  end
end
