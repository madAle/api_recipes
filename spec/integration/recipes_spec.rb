require 'spec_helper'

RSpec.describe 'portable recipes in recipes_paths' do
  around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

  def problems
    yield
    []
  rescue ApiRecipes::ConfigurationError => e
    e.errors
  end

  it 'loads an installed recipe, which is then an api like any other' do
    path = write_recipe(@dir)
    configure_recipes(path)
    stub = stub_request(:get, 'https://shop.example.test/orders/7').with(headers: { 'Authorization' => 'Bearer t' })
    ApiRecipes.shop.authorization = 'Bearer t'
    ApiRecipes.shop.orders.show(7).run
    expect(stub).to have_been_requested
    expect(ApiRecipes.shop.definition.recipe).to eq(name: 'shop', version: '1.0.0', summary: 'A test api')
    expect(ApiRecipes.configuration.recipes_paths).to eq([path])
  end

  it 'takes the values of its variables from the configuration' do
    text = recipe_text('shop', 'host' => '{tenant}.example.test', 'variables' => { 'tenant' => nil })
    configure_recipes(write_recipe(@dir, 'shop', text), variables: { shop: { tenant: 'acme' } })
    expect(ApiRecipes.shop.orders.show(7).url.to_s).to eq('https://acme.example.test/orders/7')
  end

  it 'loads several recipes and the other sources together' do
    paths = [write_recipe(@dir), write_recipe(@dir, 'bank', recipe_text('bank'))]
    configure_recipes(*paths, apis_configs: { svc: { host: 'svc.test', endpoints: { ping: nil } } })
    expect(ApiRecipes.apis).to eq(%i[svc shop bank])
  end

  it 'lets a class add its own options to an installed recipe' do
    configure_recipes(write_recipe(@dir))
    klass = Class.new do
      include ApiRecipes
      api :shop, verify_with: :checked
      def checked(_response) = false
    end
    stub_request(:get, 'https://shop.example.test/orders/7')
    expect { klass.new.shop.orders.show(7).run }.to raise_error(ApiRecipes::ResponseCodeNotAsExpected)
  end

  it 'accepts a Pathname and a path relative to the working directory' do
    path = write_recipe(@dir)
    configure_recipes(Pathname.new(path))
    expect(ApiRecipes.apis).to eq([:shop])
    Dir.chdir(@dir) { configure_recipes('shop.recipe.yml') }
    expect(ApiRecipes.apis).to eq([:shop])
  end

  it 'requires an Array' do
    expect { ApiRecipes.configure { |config| config.recipes_paths = 'x' } }
      .to raise_error(ArgumentError, 'recipes_paths must be an Array')
  end

  it 'does not load a file that is not in the lock of its folder' do
    path = write_recipe(@dir, lock: false)
    expect(problems { configure_recipes(path) })
      .to eq(["#{path}: is not in recipes.lock (there is no recipes.lock in its folder): a recipe is loaded only after " \
              "it was installed. Install it with `api_recipes install #{path}`"])
    add_to_lock(@dir, 'other', 'x')
    expect(problems { configure_recipes(path) })
      .to eq(["#{path}: is not in recipes.lock: a recipe is loaded only after it was installed. " \
              "Install it with `api_recipes install #{path}`"])
    expect(ApiRecipes.apis).to eq([])
  end

  it 'does not load, and does not even parse, a file changed after it was installed' do
    path = write_recipe(@dir)
    File.write(path, "shop: [not a recipe\n")
    allow(ApiRecipes::Internals::PlainYaml).to receive(:load).and_call_original
    expect(ApiRecipes::Internals::PlainYaml).not_to receive(:load).with(/not a recipe/, anything)
    expect(problems { configure_recipes(path) })
      .to eq(["#{path}: was changed after it was installed: its checksum is not the one in recipes.lock. " \
              "To accept the file as it is now, run `api_recipes install #{path}`"])
  end

  it 'reads the lock of each folder once' do
    other = File.join(@dir, 'other')
    Dir.mkdir(other)
    paths = [write_recipe(@dir), write_recipe(@dir, 'bank', recipe_text('bank')), write_recipe(other, 'post', recipe_text('post'))]
    expect(ApiRecipes::Internals::RecipeLock).to receive(:read).twice.and_call_original
    configure_recipes(*paths)
    expect(ApiRecipes.apis).to eq(%i[shop bank post])
  end

  it 'reports a lock that cannot be used, once for each recipe that needs it' do
    path = write_recipe(@dir)
    File.write(File.join(@dir, 'recipes.lock'), "format: 9\n")
    expect(problems { configure_recipes(path) })
      .to eq(["#{File.join(@dir, 'recipes.lock')}: format 9 is not known to this version of api_recipes (it knows 1): update the gem"])
  end

  it 'refuses a recipe whose api another source defines, whatever the order of the assignments' do
    path = write_recipe(@dir)
    expected = ["#{path}: the api 'shop' is already defined by apis_configs or apis_files_paths: " \
                'a recipe never takes the place of an api']
    found = problems do
      ApiRecipes.configure do |config|
        config.recipes_paths = [path]
        config.apis_configs = { shop: { host: 'mine.test' } }
      end
    end
    expect(found).to eq(expected)
    plain = File.join(@dir, 'plain.yml')
    File.write(plain, "shop:\n  host: mine.test\n")
    expect(problems { configure_recipes(path, apis_files_paths: [plain]) }).to eq(expected)
    expect(ApiRecipes.apis).to eq([])
  end

  it 'refuses two recipe files for the same api' do
    other = File.join(@dir, 'other')
    Dir.mkdir(other)
    paths = [write_recipe(@dir), write_recipe(other)]
    expect(problems { configure_recipes(*paths) }).to eq(["#{paths.last}: the api 'shop' is already given by another recipe file"])
  end

  it 'reports the problems of every file together, and keeps the configuration it had' do
    configure_test_apis
    good = write_recipe(@dir)
    bad = write_recipe(@dir, 'bank', recipe_text('bank', 'host' => nil))
    missing = File.join(@dir, 'none.recipe.yml')
    found = problems { configure_recipes(good, bad, missing) }
    expect(found).to eq(["#{bad}: host is required", "#{missing}: file not found"])
    expect(ApiRecipes.apis).to eq(%i[svc versioned])
  end

  it 'reports what the compiler finds in a recipe, with the other problems of the configuration' do
    path = write_recipe(@dir, 'shop', recipe_text('shop', 'timeout' => -1))
    expect(problems { configure_recipes(path) }).to eq(['shop.timeout: must be a positive number'])
  end

  it 'never evaluates a recipe with ERB' do
    path = write_recipe(@dir, 'shop', "<% raise 'evaluated' %>\n#{recipe_text}")
    expect(problems { configure_recipes(path) }.first).to include('contains <%')
  end

  it 'shows how many recipes the configuration has' do
    path = write_recipe(@dir)
    configure_recipes(path)
    expect(ApiRecipes.configuration.inspect).to include('recipes_paths: 1')
  end

  it 'works on a copy of the list of paths' do
    path = write_recipe(@dir)
    paths = [path]
    configure_recipes(*paths)
    ApiRecipes.configure { |config| config.recipes_paths << 'x.recipe.yml' } rescue nil
    expect(ApiRecipes.configuration.recipes_paths).to eq([path])
  end

  it 'forgets the recipes at reset!' do
    configure_recipes(write_recipe(@dir))
    ApiRecipes.reset!
    expect(ApiRecipes.apis).to eq([])
    expect(ApiRecipes.configuration.recipes_paths).to eq([])
  end
end
