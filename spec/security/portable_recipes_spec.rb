require 'spec_helper'
require 'api_recipes/cli'
require 'timeout'

# What a hostile portable recipe, or a hostile repository of recipes, can do
# to `api_recipes install`, `update` and `check`, and to the application that
# loads the recipe with recipes_paths. The recipe is written by someone else.
describe 'Portable recipes' do
  around do |example|
    with_recipe_repository do |repository|
      @repository = repository
      Dir.mktmpdir do |dir|
        @root = File.realpath(dir)
        @dir = File.join(@root, 'config', 'api_recipes')
        example.run
      end
    end
  end

  let(:destination) { File.join(@dir, 'shop.recipe.yml') }
  let(:marker) { File.join(@root, 'MARKER') }

  def install(*arguments, name: 'shop', input: '')
    run_cli('install', name, '--from', @repository.address, '--to', @dir, *arguments, input: input)
  end

  # Publishes text as the recipe shop and tries to install it.
  def install_text(text, *arguments, **options)
    @repository.publish('shop', text)
    install(*arguments, **options)
  end

  # Writes text as an installed recipe, lock included, without the command.
  def installed(text, name = 'shop')
    FileUtils.mkdir_p(@dir)
    write_recipe(@dir, name, text)
  end

  def configure_problems(*paths, **others)
    configure_recipes(*paths, **others)
    []
  rescue ApiRecipes::ConfigurationError => e
    e.errors
  end

  describe 'code inside the recipe' do
    let(:erb) { "<% File.write(#{marker.inspect}, 'run') %>\n#{recipe_text}" }

    it 'is never run by configure: a file of recipes_paths does not go through ERB' do
      path = installed(erb)
      expect(configure_problems(path).first).to include('contains <%')
      expect(File.exist?(marker)).to eq(false)
      expect(ApiRecipes.apis).to eq([])
    end

    it 'is never run by install, update, check and routes, with or without --erb' do
      expect(install_text(erb, '--yes').first).to eq(1)
      path = installed(erb)
      expect(run_cli('check', path).first).to eq(1)
      expect(run_cli('check', '--dir', @dir).first).to eq(1)
      expect(run_cli('routes', '--erb', path).first).to eq(1)
      expect(run_cli('install', path, '--to', @dir, '--yes').first).to eq(1)
      expect(File.exist?(marker)).to eq(false)
    end

    it 'cannot wait in the file for the day it is given to apis_files_paths: text that ERB would run is refused' do
      text = recipe_text('shop', 'x-note' => "<%= File.write(#{marker.inspect}, 'run') %>")
      code, _out, err = install_text(text, '--yes')
      expect(code).to eq(1)
      expect(err).to include('contains <%')
      expect(File.exist?(destination)).to eq(false)
    end

    it 'cannot be a Ruby object: the recipe is plain YAML, without tags' do
      text = recipe_text.sub("shop:\n", "shop: !ruby/object:OpenStruct\n")
      expect(install_text(text, '--yes')[2]).to include('uses a tag')
      expect(configure_problems(installed(text))).to eq(["#{destination}: uses a tag"])
    end

    it 'cannot describe a huge structure with aliases: anchors and aliases are refused while the text is parsed' do
      bomb = "a: &a [x, x, x, x, x, x, x, x, x]\n" +
             ('b'..'m').each_cons(2).map { |one, two| "#{two}: &#{two} [*#{one}, *#{one}, *#{one}, *#{one}, *#{one}, *#{one}, *#{one}, *#{one}, *#{one}]\n" }
                       .join.sub('b: &b [*a', 'b: &b [*a')
      text = "shop:\n  x-bomb:\n    #{bomb.gsub("\n", "\n    ").strip}\n#{recipe_text.sub("---\nshop:\n", '')}"
      path = installed(text)
      found = Timeout.timeout(5) { configure_problems(path) }
      expect(found).to eq(["#{path}: uses an anchor or an alias"])
    end

    it 'cannot be larger than 1 MiB: the text is not parsed' do
      path = installed("#{recipe_text}# #{'x' * 1_048_576}\n")
      expect(Psych::Parser).not_to receive(:new)
      expect(configure_problems(path)).to eq(["#{path}: is larger than 1048576 bytes"])
    end

    it 'cannot cost much more than its size: names, values, paths and the number of endpoints have a limit' do
      children = (1..4000).to_h { |number| ["c#{number}", nil] }
      long_path = recipe_text('shop', 'endpoints' => { 'top' => { 'path' => "/#{'p' * 80_000}", 'endpoints' => children } })
      deep = (1..40).reduce({ 'leaf' => { 'endpoints' => children } }) do |inner, number|
        { "level#{number}" => { 'path' => "/#{'s' * 1900}", 'endpoints' => inner } }
      end
      many = (1..20_000).to_h { |number| ["e#{number}", nil] }
      resources = (1..9_000).to_h { |number| ["e#{number}", { 'resource' => true }] }
      texts = [long_path, recipe_text('shop', 'endpoints' => deep), recipe_text('shop', 'endpoints' => many),
               recipe_text('shop', 'endpoints' => resources)]
      reasons = ['a name or a value of a recipe has at most 2000 characters',
                 'the path of an endpoint, with the paths above it, has at most 4000 characters',
                 'has 20000 endpoints: a recipe has at most 10000',
                 'has 54000 endpoints: a recipe has at most 10000']
      texts.zip(reasons).each do |text, reason|
        path = installed(text)
        found = Timeout.timeout(10) { configure_problems(path) }
        expect(found.size).to eq(1)
        expect(found.first).to end_with(reason)
        expect(Timeout.timeout(10) { run_cli('check', path).first }).to eq(1)
      end
    end

    it 'cannot cost much more than its size with headers and parameters that every endpoint below would keep' do
      params = (1..400).to_h { |number| ["p#{number}", number] }
      children = (1..300).to_h { |number| ["c#{number}", { 'default_params' => { 'own' => number } }] }
      path = installed(recipe_text('shop', 'endpoints' => { 'top' => { 'default_params' => params, 'endpoints' => children } }))
      found = Timeout.timeout(10) { configure_problems(path) }
      expect(found.size).to eq(1)
      expect(found.first).to end_with('its endpoints hold 120700 headers and parameters, counting for each endpoint those of ' \
                                      'the endpoints above it: a recipe has at most 100000')
      expect(run_cli('check', path).first).to eq(1)

      # Within the limit the cost follows the size: an endpoint that adds
      # nothing shares what it takes, and names are compared through an index.
      shared = (1..4000).to_h { |number| ["c#{number}", nil] }
      many = (1..4000).to_h { |number| ["p#{number}", number] }
      headers = ->(prefix) { (1..10_000).to_h { |number| ["#{prefix}-#{number}", 'v'] } }
      [recipe_text('shop', 'endpoints' => { 'top' => { 'default_params' => many, 'endpoints' => shared } }),
       recipe_text('shop', 'endpoints' => { 'top' => { 'default_headers' => headers.call('X-A'), 'endpoints' => {
         'one' => { 'default_headers' => headers.call('X-B') }
       } } })].each do |text|
        path = installed(text)
        expect(Timeout.timeout(5) { configure_problems(path) }).to eq([])
      end
    end
  end

  describe 'a variable of the recipe' do
    # Observed: nothing in the gem gives the environment to a recipe.
    it 'takes its value from the code of the application, never from the environment' do
      ENV['SHOP_SECRET'] = 'from-the-environment'
      text = recipe_text('shop', 'default_headers' => { 'X-Leak' => '{leak}' },
                                 'variables' => { 'leak' => { 'default' => '$SHOP_SECRET ${SHOP_SECRET} %SHOP_SECRET%' } })
      configure_recipes(installed(text))
      stub = stub_request(:get, 'https://shop.example.test/orders/1')
             .with(headers: { 'X-Leak' => '$SHOP_SECRET ${SHOP_SECRET} %SHOP_SECRET%' })
      ApiRecipes.shop.orders.show(1).run
      expect(stub).to have_been_requested
    ensure
      ENV.delete('SHOP_SECRET')
    end
  end

  describe 'verify_with in the recipe' do
    it 'is refused, on the api and on an endpoint: a recipe cannot make the gem call a method of the application' do
      on_api = recipe_text('shop', 'verify_with' => 'exit!')
      on_endpoint = recipe_text('shop', 'endpoints' => { 'show' => { 'verify_with' => 'exit!' } })
      [on_api, on_endpoint].each do |text|
        code, _out, err = install_text(text, '--yes')
        expect(code).to eq(1)
        expect(err).to include('verify_with is not allowed in a recipe')
        expect(configure_problems(installed(text)).first).to include('verify_with is not allowed in a recipe')
      end
      expect(ApiRecipes.apis).to eq([])
    end
  end

  describe 'the credential of the application' do
    it 'cannot be replaced by a parameter of the recipe: default_params that name the parameter of the credential are refused' do
      text = recipe_text('shop', 'auth' => { 'type' => 'query', 'name' => 'key' },
                                 'endpoints' => { 'orders' => { 'default_params' => { 'key' => 'theirs' } } })
      code, _out, err = install_text(text, '--yes')
      expect(code).to eq(1)
      expect(err).to include('shop.endpoints.orders.default_params.key: is the parameter of the credential')
      expect(File.exist?(destination)).to eq(false)
      expect(configure_problems(installed(text)).first).to include('is the parameter of the credential')
    end
  end

  describe 'a recipe with the name of an api the application already has' do
    it 'is refused, and never receives the credential of that api' do
      configure_test_apis(svc: { host: 'api.example.test', endpoints: { users: nil } })
      global_values(svc: { authorization: 'Bearer secret' })
      thief = installed(recipe_text('svc', 'host' => 'evil.example.test', 'endpoints' => { 'users' => nil }), 'svc')
      found = begin
        ApiRecipes.configure do |config|
          config.apis_configs = { svc: { host: 'api.example.test', endpoints: { users: nil } } }
          config.recipes_paths = [thief]
        end
        []
      rescue ApiRecipes::ConfigurationError => e
        e.errors
      end
      expect(found).to eq(["#{thief}: the api 'svc' is already defined by apis_configs: " \
                           'a recipe never takes the place of an api'])
      expect(ApiRecipes.svc.users.url.to_s).to eq('https://api.example.test/users')
    end

    it 'is refused also when the other api comes from another recipe' do
      other = File.join(@root, 'other')
      Dir.mkdir(other)
      first = installed(recipe_text)
      second = write_recipe(other, 'shop', recipe_text('shop', 'host' => 'evil.example.test'))
      expect(configure_problems(first, second)).to eq(["#{second}: the api 'shop' is already given by another recipe file"])
    end
  end

  describe 'where the requests and the credential go' do
    it 'is shown by install before anything is written: protocol, host as written and with the defaults, kind of auth' do
      text = recipe_text('shop', 'protocol' => 'https', 'host' => '{account}.example.test', 'port' => 8443, 'base_url' => 'v2',
                                 'auth' => { 'type' => 'header', 'name' => 'X-Token' },
                                 'variables' => { 'account' => { 'default' => 'attacker' } })
      code, out, err = install_text(text, input: "\n")
      expect([code, err]).to eq([1, "nothing was written\n"])
      expect(out).to include("  address:       https://{account}.example.test:8443/v2\n",
                             "  with defaults: https://attacker.example.test:8443/v2\n",
                             "  credential:    in the header X-Token\n")
      expect(File.exist?(@dir)).to eq(false)
    end

    it 'cannot be moved by the default of a variable: a variable is the whole host or stands before fixed text' do
      ['api.example.{tld}', '{name}example.test', 'api.{zone}'].each do |host|
        text = recipe_text('shop', 'host' => host, 'variables' => { 'tld' => { 'default' => 'test.evil.example' },
                                                                    'name' => { 'default' => 'evil-' },
                                                                    'zone' => { 'default' => 'evil.example' } }.slice(host[/\{(\w+)\}/, 1]))
        code, _out, err = install_text(text, '--yes')
        expect(code).to eq(1), host
        expect(err).to include('here a variable would decide where the host ends'), host
        expect(configure_problems(installed(text)).first).to include('here a variable would decide where the host ends')
      end
    end
  end

  describe 'what install shows' do
    it 'cannot be changed by control or format characters: a recipe holds visible text only' do
      [
        recipe_text('shop', recipe: { 'summary' => "safe\e[2K\rshop 9.9.9" }),
        recipe_text('shop', recipe: { 'summary' => "line one\n  address:       https://safe.example.test" }),
        recipe_text('shop', 'endpoints' => { "show\u202Ecancel" => { 'verb' => 'delete' } }),
        recipe_text('shop', 'variables' => { 'tenant' => { 'description' => "hidden\u200B" } })
      ].each do |text|
        code, out, err = install_text(text, '--yes')
        expect([code, out]).to eq([1, reading]), text
        expect(err).to include('contains a character that is not printed'), text
        expect(err).not_to match(/[\e\r\u202E\u200B]/)
        expect(err.lines.size).to eq(1)
      end
      expect(File.exist?(@dir)).to eq(false)
    end

    it 'cannot show a host that looks like another: letters of another alphabet are refused' do
      text = recipe_text('shop', 'host' => "ex\u0430mple.test")
      expect(YAML.safe_load(text)['shop']['host']).not_to be_ascii_only
      code, _out, err = install_text(text, '--yes')
      expect(code).to eq(1)
      expect(err).to include('shop.host: must be a plain host name')
    end

    it 'cannot differ from what is loaded: a key given twice, or a key that is not text, is refused' do
      twice = recipe_text.sub("  host: shop.example.test\n", "  host: shop.example.test\n  host: evil.example.test\n")
      expect(twice.scan('host:').size).to eq(2)
      merged = recipe_text.sub("  host: shop.example.test\n", "  host: shop.example.test\n  <<: { host: evil.example.test }\n")
      keyed = recipe_text.sub("  host: shop.example.test\n", "  host: shop.example.test\n  ? [host]\n  : evil.example.test\n")
      { twice => "the key 'host' is given twice", merged => 'uses the merge key <<', keyed => 'has a key that is not plain text' }
        .each do |text, reason|
        code, _out, err = install_text(text, '--yes')
        expect([code, err]).to eq([1, "shop in #{@repository.address}: #{reason}\n"])
        expect(configure_problems(installed(text))).to eq(["#{destination}: #{reason}"])
      end
    end

    it 'is about the api that is installed: the name of the api, recipe.name and the name of the file are the same' do
      code, _out, err = install_text(recipe_text('github'), '--yes')
      expect([code, err]).to eq([1, "shop in #{@repository.address}: the file must be called github.recipe.yml, after its api\n"])
      code, _out, err = install_text(recipe_text('shop', recipe: { 'name' => 'github' }), '--yes')
      expect([code, err]).to eq([1, "shop in #{@repository.address}: recipe.name must be 'shop', the name of the api\n"])
      path = File.join(FileUtils.mkdir_p(@dir).first, 'github.recipe.yml')
      File.write(path, recipe_text('shop'))
      add_to_lock(@dir, 'github', recipe_text('shop'))
      expect(configure_problems(path)).to eq(["#{path}: the file must be called shop.recipe.yml, after its api"])
    end

    it 'says when the credential travels in the address, in install and in check' do
      text = recipe_text('shop', 'auth' => { 'type' => 'query', 'name' => 'api_key' })
      warning = 'warning: the credential travels in the address, as the query parameter api_key'
      expect(install_text(text, '--yes')[1]).to include("  #{warning}")
      expect(run_cli('check', destination)[2]).to include(warning)
      expect(run_cli('check', '--dir', @dir)[2]).to include(warning)
    end

    it 'says when the credential travels without encryption, in install and in check' do
      text = recipe_text('shop', 'protocol' => 'http')
      warning = 'warning: the protocol is http: a credential you assign travels without encryption'
      expect(install_text(text, '--yes')[1]).to include("  #{warning}")
      expect(run_cli('check', destination)[2]).to include(warning)
    end

    it 'says so also when the recipe declares that the api takes no credential: one that the application assigns is sent' do
      text = recipe_text('shop', 'protocol' => 'http', 'auth' => { 'type' => 'none' })
      _code, out, = install_text(text, '--yes')
      expect(out).to include("  credential:    none declared: a credential you assign still goes in the Authorization header\n",
                             "  warning: the protocol is http: a credential you assign travels without encryption\n")
      configure_recipes(destination)
      global_values(shop: { authorization: 'Bearer secret' })
      sent = stub_request(:get, 'http://shop.example.test/orders/1').with(headers: { 'Authorization' => 'Bearer secret' })
      ApiRecipes.shop.orders.show(1).run
      expect(sent).to have_been_requested
    end

    it 'lists every variable the recipe asks a value for, also those it uses without declaring them' do
      text = recipe_text('shop', 'host' => '{tenant}.example.test', 'default_headers' => { 'X-Key' => '{key}' },
                                 'variables' => { 'zone' => { 'default' => 'eu' } }, 'base_url' => '{zone}')
      _code, out, = install_text(text, '--yes')
      expect(out).to include("  variables:     zone: default eu\n                 tenant: to be set\n                 key: to be set\n")
    end

    it 'shows the headers sent with every request, and update shows the ones that change' do
      expect(install_text(recipe_text, '--yes').first).to eq(0)
      @repository.publish('shop', recipe_text('shop', 'default_headers' => { 'X-HTTP-Method-Override' => 'DELETE' },
                                                      recipe: { 'version' => '1.0.1' }))
      code, out, = run_cli('update', 'shop', '--dir', @dir, input: "n\n")
      expect(code).to eq(1)
      expect(out).to include("  headers:       X-HTTP-Method-Override: DELETE\n",
                             "    new header: X-HTTP-Method-Override: DELETE\n")
    end

    it 'cannot be given rows of its own by a long text: several spaces are shown as one, and each variable has its line' do
      fake = "A test api#{' ' * 64}address:       https://safe.example.test"
      variables = (1..12).to_h { |number| ["v#{number}", { 'description' => 'd' * 100, 'default' => 'x' }] }
              .merge('tenant' => { 'default' => 'attacker' })
      text = recipe_text('shop', 'host' => '{tenant}.example.test', 'variables' => variables, recipe: { 'summary' => fake })
      _code, out, = install_text(text)
      expect(out).to include("  summary:       A test api address: https://safe.example.test\n",
                             "                 tenant: default attacker\n")
      expect(out).not_to match(/ {3}address:/)
    end

    it 'cannot differ from what a person reads in the file: a line break that is not a new line is refused, in a comment too' do
      separator = [0x2028].pack('U')
      hidden = recipe_text.sub("  host: shop.example.test\n", "  # the host is shop.example.test#{separator}  host: evil.example.test\n")
      expect(hidden.lines.grep(/host/).size).to eq(1)
      expect(YAML.safe_load(hidden)['shop']['host']).to eq('evil.example.test')
      with_verb = recipe_text.sub("        show:\n", "        show: # read only#{separator}          verb: delete\n")
      expect(YAML.safe_load(with_verb)['shop']['endpoints']['orders']['endpoints']['show']['verb']).to eq('delete')
      [hidden, with_verb, "#{recipe_text}# right#{[0x202E].pack('U')}to left\n"].each do |text|
        code, out, err = install_text(text, '--yes')
        expect([code, out]).to eq([1, reading])
        expect(err).to match(/\Ashop in .*: line \d+: contains a character that is not printed/)
        path = installed(text)
        expect(run_cli('check', path).first).to eq(1)
        expect(configure_problems(path).first).to include('contains a character that is not printed')
      end
    end

    it 'shows the parameters sent with every request and what an endpoint adds, and update shows what changes' do
      expect(install_text(recipe_text, '--yes').first).to eq(0)
      endpoints = { 'orders' => { 'default_headers' => { 'X-HTTP-Method-Override' => 'DELETE' }, 'endpoints' => {
        'show' => { 'path' => '/:id', 'default_params' => { '_method' => 'delete' } }
      } } }
      @repository.publish('shop', recipe_text('shop', 'default_params' => { 'debug' => 1 }, 'endpoints' => endpoints,
                                                      recipe: { 'version' => '1.0.1' }))
      code, out, = run_cli('update', 'shop', '--dir', @dir, input: "n\n")
      expect(code).to eq(1)
      expect(out).to include("  headers:       X-HTTP-Method-Override: DELETE (shop.orders and the endpoints it contains)\n",
                             "  params:        debug: 1\n                 _method: delete (shop.orders.show)\n",
                             "    new header: X-HTTP-Method-Override: DELETE (shop.orders and the endpoints it contains)\n",
                             "    new parameter: debug: 1\n    new parameter: _method: delete (shop.orders.show)\n")
    end

    it 'never hides the end of a value: a cut is marked, and update compares and shows the whole values that change' do
      long = 'a' * 150
      text = lambda do |tail, version|
        recipe_text('shop', 'variables' => { 'account' => nil }, 'default_params' => { 'q' => "#{long}#{tail}" },
                            recipe: { 'version' => version })
      end
      code, out, = install_text(text.call('', '1.0.0'), '--yes')
      expect(code).to eq(0)
      expect(out).to include("  params:        q: #{'a' * 100}... (150 characters)\n")
      @repository.publish('shop', text.call('&leak={account}', '1.0.1'))
      _code, out, = run_cli('update', 'shop', '--dir', @dir, input: "n\n")
      expect(out).to include("  params:        q: #{'a' * 100}... (165 characters)\n",
                             "    parameter q: #{long} -> #{long}&leak={account}\n")
      expect(out).not_to include('no change')
    end

    it 'lists the calls that resource adds and that are not GET' do
      _code, out, = install_text(recipe_text('shop', 'endpoints' => { 'orders' => { 'resource' => true } }))
      expect(out).to include("  calls:         6, of which 4 are not GET:\n" \
                             "    POST    shop.orders.create       /orders\n" \
                             "    PATCH   shop.orders.update(id)   /orders/:id\n" \
                             "    PUT     shop.orders.replace(id)  /orders/:id\n" \
                             "    DELETE  shop.orders.delete(id)   /orders/:id\n")
    end

    it 'lists every call that is not a GET, whatever its name' do
      endpoints = { 'show' => { 'path' => '/items/:id', 'verb' => 'delete' }, 'list' => nil,
                    'preview' => { 'verb' => 'post', 'path' => '/payments' } }
      _code, out, = install_text(recipe_text('shop', 'endpoints' => endpoints))
      expect(out).to include("  calls:         3, of which 2 are not GET:\n" \
                             "    DELETE  shop.show(id)  /items/:id\n" \
                             "    POST    shop.preview   /payments\n")
    end
  end

  describe 'an update' do
    it 'shows what changes in the host, the auth and the verbs, and replaces nothing before the answer' do
      expect(install_text(recipe_text, '--yes').first).to eq(0)
      hostile = recipe_text('shop', 'host' => 'collector.example.test', 'auth' => { 'type' => 'query', 'name' => 'token' },
                                    'endpoints' => { 'orders' => { 'endpoints' => { 'show' => { 'path' => '/:id', 'verb' => 'delete' },
                                                                                    'create' => { 'path' => '', 'verb' => 'post' } } } },
                                    recipe: { 'version' => '1.0.1' })
      @repository.publish('shop', hostile)
      code, out, = run_cli('update', 'shop', '--dir', @dir, input: "n\n")
      expect(code).to eq(1)
      expect(out).to include("    address: https://shop.example.test -> https://collector.example.test\n",
                             "    credential: in the Authorization header -> in the query string, as the parameter token\n",
                             "    shop.orders.show(id): GET -> DELETE\n")
      expect(File.read(destination)).to eq(recipe_text)
      expect(configure_problems(destination)).to eq([])
    end

    it 'says which address it reads before git connects to it: the address comes from the lock' do
      expect(install_text(recipe_text, '--yes').first).to eq(0)
      lock = File.join(@dir, 'recipes.lock')
      File.write(lock, File.read(lock).sub(@repository.address, 'ssh://collector.example.test/r'))
      stub_const('ApiRecipes::CLI::Recipes::Git::PROTOCOLS', %w[https ssh].freeze)
      out = StringIO.new
      said_before = nil
      failed = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3) do
        said_before ||= out.string.dup
        ['', "fatal: stopped here\n".b, failed]
      end
      code = ApiRecipes::CLI::Recipes.new(out: out, err: StringIO.new, input: StringIO.new).update('shop', directory: @dir, yes: true)
      expect(code).to eq(2)
      expect(said_before).to eq("reading shop from ssh://collector.example.test/r\n")
      expect(File.read(destination)).to eq(recipe_text)
    end
  end

  describe 'a recipe installed from a repository and changed afterwards' do
    def from_a_cookbook
      FileUtils.mkdir_p(@dir)
      write_recipe(@dir, 'shop', recipe_text, repository: true)
    end

    it 'stops configure, and the configuration stays the one it was' do
      configure_test_apis
      path = from_a_cookbook
      File.write(path, recipe_text('shop', 'host' => 'evil.example.test'))
      expect(configure_problems(path).first).to include('was changed after it was installed from its repository')
      expect(ApiRecipes.apis).to eq(%i[svc versioned])
    end

    it 'is reported by check, which exits with 1' do
      path = from_a_cookbook
      File.write(path, recipe_text('shop', 'host' => 'evil.example.test'))
      code, _out, err = run_cli('check', '--dir', @dir)
      expect(code).to eq(1)
      expect(err).to include('was changed after it was installed from its repository')
    end

    it 'is not what a recipe of the project is: one that the lock ties to no repository is loaded as it is written' do
      path = installed(recipe_text)
      File.write(path, recipe_text('shop', 'host' => 'mine.example.test'))
      expect(configure_problems(path)).to eq([])
      expect(ApiRecipes.shop.definition.host).to eq('mine.example.test')
      File.delete(File.join(@dir, 'recipes.lock'))
      expect(configure_problems(path)).to eq([])
      expect(run_cli('check', '--dir', @dir).first).to eq(0)
    end
  end

  describe 'the name, the version and the address given to install' do
    it 'cannot make it write outside the folder: the name of a recipe has no dots and no slashes' do
      escaping = recipe_text('../../outside')
      @repository.publish('shop', escaping)
      code, _out, err = install('--yes')
      expect(code).to eq(1)
      expect(err).to include("the api name '../../outside' must be made of lowercase letters")
      code, _out, err = install('--yes', name: '../../outside')
      expect([code, err]).to eq([2, "--from and --version go with the name of a recipe, not with a file\n"])
      expect(Dir.glob(File.join(@root, '**', '*outside*'))).to eq([])
    end

    it 'cannot pass an option to git: a version is made of digits, letters and dots' do
      @repository.publish('shop', recipe_text)
      expect(Open3).not_to receive(:capture3)
      ["--upload-pack=touch #{marker}", '1.0.0 --upload-pack=x', '-1', "1\n--exec=x"].each do |version|
        expect(install('--version', version, '--yes').first).to eq(2), version
      end
      expect(File.exist?(marker)).to eq(false)
    end

    it 'cannot pass an option to git after a new line: the whole name is checked, not its first line' do
      expect(install_text(recipe_text, '--yes').first).to eq(0)
      expect(Open3).not_to receive(:capture3)
      code, out, err = run_cli('update', "shop\n--upload-pack=touch #{marker}", '--dir', @dir, '--yes')
      expect([code, out]).to eq([2, ''])
      expect(err).to end_with("is not the name of a recipe\n")
      expect { ApiRecipes::CLI::Recipes::Git.new('https://example.test/r').fetch("shop\n--upload-pack=x") }.to raise_error(ArgumentError)
      expect { ApiRecipes::CLI::Recipes::Git.new('https://example.test/r').fetch('shop', "1\n--upload-pack=x") }.to raise_error(ArgumentError)
    end

    it 'cannot be anything else than an https or ssh address: no other protocol, no option, no command' do
      stub_const('ApiRecipes::CLI::Recipes::Git::PROTOCOLS', %w[https ssh].freeze)
      expect(Open3).not_to receive(:capture3)
      [@repository.address, @repository.directory, 'http://example.test/r', 'git://example.test/r',
       "ext::sh -c touch% #{marker}", "--upload-pack=touch #{marker}",
       "https://example.test/$(touch #{marker})", "https://example.test/r;touch #{marker}", "https://example.test/r\n--x"].each do |address|
        code, out, err = run_cli('install', 'shop', '--from', address, '--to', @dir, '--yes')
        expect([code, out]).to eq([2, '']), address
        expect(err).to start_with('--from must '), address
      end
      expect(File.exist?(marker)).to eq(false)
      expect(File.exist?(@dir)).to eq(false)
    end

    it 'never reaches a shell: git is run with its arguments one by one' do
      @repository.publish('shop', recipe_text)
      commands = []
      allow(Open3).to receive(:capture3).and_wrap_original do |original, *arguments, **options|
        commands << arguments
        original.call(*arguments, **options)
      end
      expect(install('--yes').first).to eq(0)
      expect(commands).not_to be_empty
      expect(commands).to all(satisfy { |arguments| arguments[0].is_a?(Hash) && arguments[1] == 'git' && arguments.size > 2 })
    end

    it 'cannot make ssh run a command or take an option: the user, the host and the path never start with a hyphen' do
      stub_const('ApiRecipes::CLI::Recipes::Git::PROTOCOLS', %w[https ssh].freeze)
      expect(Open3).not_to receive(:capture3)
      ["ssh://-oProxyCommand=touch${IFS}#{marker}/r", "ssh://git@-oProxyCommand=touch${IFS}#{marker}/r",
       "-oProxyCommand=touch${IFS}#{marker}@example.test:r", "git@-oProxyCommand=touch${IFS}#{marker}:r",
       "ssh://-oProxyCommand=touch #{marker}/r", 'ssh://-F/tmp/config@example.test/r', "git@example.test:--upload-pack=touch${IFS}#{marker}",
       'git@example.test:-x', 'ssh://git:secret@example.test/r', "git@example.test:r\n--x", 'ssh://-v/r', 'ssh://-F/r',
       "ssh://git@example.test/r\n--x", '-l@example.test:r', 'ssh://-l@example.test/r', "--upload-pack=x\ngit@example.test:r",
       'ssh://git@example.test$(id)/r', 'git@example.test;id:r', 'u;id@example.test:r', 'ssh://u$(id)@example.test/r',
       'ssh://git@example.test`id`/r', 'git@example.test&x:r', "ssh://example.test/r'x", 'ssh://example.test/r;x',
       'ssh://example.test/r$x', 'ssh://example.test/r\\x', 'git@example.test://x'].each do |address|
        code, out, err = run_cli('install', 'shop', '--from', address, '--to', @dir, '--yes')
        expect([code, out]).to eq([2, '']), address
        expect(err).to start_with('--from must '), address
      end
      expect(File.exist?(marker)).to eq(false)
    end
  end

  describe 'a hostile repository' do
    it 'cannot make install read a link, a folder or a submodule in place of the file' do
      secret = File.join(@root, 'secret.yml')
      File.write(secret, recipe_text)
      FileUtils.mkdir_p(File.join(@repository.directory, 'recipes'))
      File.symlink(secret, File.join(@repository.directory, 'recipes/shop.recipe.yml'))
      @repository.commit('recipes/bank.recipe.yml/x.yml', recipe_text('bank'))
      @repository.git('update-index', '--add', '--cacheinfo', "160000,#{@repository.head},recipes/post.recipe.yml")
      @repository.git('commit', '--quiet', '--message', 'submodule')
      %w[shop bank post].each do |name|
        code, out, err = install('--yes', name: name)
        expect([code, out]).to eq([1, reading(name)]), name
        expect(err).to include('is not a regular file (it is a link, a folder or a submodule): it was not read'), name
      end
      expect(File.exist?(@dir)).to eq(false)
    end

    it 'never gets a working copy: nothing of the repository is written on disk outside a temporary folder that is removed' do
      @repository.commit('recipes/hook.sh', "#!/bin/sh\ntouch #{marker}\n")
      @repository.publish('shop', recipe_text)
      folders = []
      allow(Dir).to receive(:mktmpdir).and_wrap_original do |original, *arguments, &given|
        original.call(*arguments) do |folder|
          folders << folder
          given.call(folder)
        end
      end
      expect(install('--yes').first).to eq(0)
      expect(Dir.children(@dir).sort).to eq(%w[recipes.lock shop.recipe.yml])
      expect(folders.size).to eq(1)
      expect(File.exist?(folders.first)).to eq(false)
      expect(File.exist?(marker)).to eq(false)
    end

    it 'is reached with https and ssh only: git itself refuses any other protocol, even if the check of the address is skipped' do
      @repository.publish('shop', recipe_text)
      stub_const('ApiRecipes::CLI::Recipes::Git::PROTOCOLS', %w[https ssh].freeze)
      allow(ApiRecipes::CLI::Recipes::Git).to receive(:address_problem).and_return(nil)
      code, out, err = install('--yes')
      expect([code, out]).to eq([2, reading])
      expect(err).to match(/\Agit could not read file:.*not allowed/)
    end

    it 'cannot write on the terminal through the messages of git: they are shown as one line of visible text' do
      failed = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3).and_return(['', "remote: fine\nremote: \e[2J\e[Hshop 1.0.0 is installed\r\n".b, failed])
      code, out, err = run_cli('install', 'shop', '--from', 'https://example.test/r', '--to', @dir, '--yes')
      expect([code, out]).to eq([2, reading('shop', 'https://example.test/r')])
      expect(err).to eq("git failed (init): remote: ?[2J?[Hshop 1.0.0 is installed\n")
    end

    it 'cannot send a recipe larger than 1 MiB: the file is not read' do
      code, _out, err = install_text("#{recipe_text}# #{'x' * 1_048_576}\n", '--yes')
      expect(code).to eq(1)
      expect(err).to include('is larger than 1048576 bytes: it was not read')
    end
  end

  describe 'an address with a user name or a password' do
    it 'is refused by install, so that it never reaches recipes.lock, which is versioned' do
      stub_const('ApiRecipes::CLI::Recipes::Git::PROTOCOLS', %w[https ssh].freeze)
      expect(Open3).not_to receive(:capture3)
      %w[https://alice:s3cret@example.test/r https://token@example.test/r].each do |address|
        code, _out, err = run_cli('install', 'shop', '--from', address, '--to', @dir, '--yes')
        expect([code, err]).to eq([2, "--from must not contain a user name or a password: git takes them from its own configuration\n"])
      end
      code, _out, err = run_cli('install', 'shop', '--from', 'ssh://alice:s3cret@example.test/r', '--to', @dir, '--yes')
      expect([code, err]).to eq([2, "--from must not contain a password: ssh takes what it needs from its keys and its agent\n"])
      expect(File.exist?(@dir)).to eq(false)
    end

    it 'is refused by update when someone wrote it in the lock by hand' do
      expect(install_text(recipe_text, '--yes').first).to eq(0)
      lock = File.join(@dir, 'recipes.lock')
      File.write(lock, File.read(lock).sub(@repository.address, 'https://alice:s3cret@example.test/r'))
      stub_const('ApiRecipes::CLI::Recipes::Git::PROTOCOLS', %w[https ssh].freeze)
      expect(Open3).not_to receive(:capture3)
      code, _out, err = run_cli('update', 'shop', '--dir', @dir, '--yes')
      expect(code).to eq(2)
      expect(err).to include('must not contain a user name or a password')
      File.write(lock, File.read(lock).sub('https://alice:s3cret@example.test/r', 'ssh://alice:s3cret@example.test/r'))
      code, _out, err = run_cli('update', 'shop', '--dir', @dir, '--yes')
      expect(code).to eq(2)
      expect(err).to include('must not contain a password')
    end
  end

  describe 'the files install writes' do
    it 'are never written through a link: a link in the place of the recipe or of the lock stops the command' do
      @repository.publish('shop', recipe_text)
      FileUtils.mkdir_p(@dir)
      victim = File.join(@root, 'victim.rb')
      File.write(victim, 'untouched')
      %w[shop.recipe.yml recipes.lock].each do |name|
        File.symlink(victim, File.join(@dir, name))
        expect(install('--yes').first).to eq(2)
        File.delete(File.join(@dir, name))
      end
      expect(File.read(victim)).to eq('untouched')
    end

    it 'are the recipe and the lock only, with the names the command chooses' do
      @repository.publish('shop', recipe_text)
      expect(install('--yes').first).to eq(0)
      expect(Dir.glob(File.join(@root, '**', '*'), File::FNM_DOTMATCH).select { |path| File.file?(path) }.sort)
        .to eq([File.join(@dir, 'recipes.lock'), destination])
    end
  end

  describe 'the lock' do
    it 'is read as plain data with the rules of a recipe, and a lock that is not what the command writes stops configure' do
      path = installed(recipe_text)
      lock = File.join(@dir, 'recipes.lock')
      sha = Digest::SHA256.hexdigest(recipe_text)
      ["format: 1\nrecipes: &r\n  shop: { version: '1.0.0', sha256: #{sha} }\n",
       "format: 1\nrecipes:\n  shop: { version: '1.0.0', sha256: #{'0' * 64} }\n  shop: { version: '1.0.0', sha256: #{sha} }\n",
       "format: 1\nrecipes:\n  shop: !ruby/object:Object { version: '1.0.0', sha256: #{sha} }\n"].each do |text|
        File.write(lock, text)
        found = configure_problems(path)
        expect(found.size).to eq(1)
        expect(found.first).to start_with("#{lock}: ")
      end
      expect(ApiRecipes.apis).to eq([])
    end
  end
end
