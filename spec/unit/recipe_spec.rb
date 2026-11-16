require 'spec_helper'

RSpec.describe ApiRecipes::Internals::Recipe do
  def parse(text, **options)
    described_class.parse(text, 'the recipe', **options)
  end

  def problems(text, **options)
    parse(text, **options)
    []
  rescue ApiRecipes::RecipeFileError => e
    e.errors.map { |problem| problem.delete_prefix('the recipe: ') }
  end

  describe '.parse' do
    it 'gives the name, the version, the checksum, the options and the compiled api' do
      text = recipe_text
      recipe = parse(text)
      expect(recipe.name).to eq('shop')
      expect(recipe.version).to eq('1.0.0')
      expect(recipe.sha256).to eq(Digest::SHA256.hexdigest(text))
      expect(recipe.text).to equal(text)
      expect(recipe.apis.keys).to eq([:shop])
      expect(recipe.apis[:shop][:host]).to eq('shop.example.test')
      expect(recipe.definition.routes.map(&:call)).to eq(['shop.orders', 'shop.orders.show(id)', 'shop.orders.create'])
      expect(recipe.definition.recipe).to eq(name: 'shop', version: '1.0.0', summary: 'A test api')
      expect(recipe).to be_frozen
    end

    it 'leaves the api uncompiled with compile: false' do
      text = recipe_text('shop', 'timeout' => -1)
      expect(parse(text, compile: false).definition).to be_nil
      expect(problems(text)).to eq(['shop.timeout: must be a positive number'])
    end

    it 'accepts the name of the file when it is the name of the api' do
      expect(parse(recipe_text, file_name: 'shop.recipe.yml').name).to eq('shop')
      expect(problems(recipe_text, file_name: 'other.recipe.yml'))
        .to eq(['the file must be called shop.recipe.yml, after its api'])
    end

    it 'refuses a text that is empty, or that is not one api' do
      expect(problems('')).to eq(['file is empty'])
      expect(problems("- a\n")).to eq(['must contain one api: a mapping from its name to its options'])
      expect(problems(YAML.dump(recipe_data.merge(recipe_data('other')))))
        .to eq(['must contain one api, but it has 2: shop, other'])
      expect(problems("shop: 1\n")).to eq(["the api 'shop' must be a mapping of options"])
    end

    it 'refuses what the plain YAML reader refuses' do
      expect(problems("shop: &a { host: h.test }\n")).to eq(['uses an anchor or an alias'])
      expect(problems("shop:\n  host: a.test\n  host: b.test\n")).to eq(["the key 'host' is given twice"])
    end

    it 'refuses a text larger than 1 MiB' do
      expect(problems("# #{'x' * described_class::MAX_BYTES}\n#{recipe_text}")).to eq(['is larger than 1048576 bytes'])
    end

    it 'refuses text that ERB would run, without running it' do
      text = recipe_text('shop', 'x-note' => "<% raise 'evaluated' %>")
      expect(problems(text).first).to start_with('contains <%: a recipe is never evaluated with ERB')
    end

    it 'refuses a name that is not made of lowercase letters, digits, - and _' do
      %w[Shop shop.io -shop sh/op shöp].push('a' * 65, '').each do |name|
        expect(problems(recipe_text(name)).first).to start_with('the api name '), name
      end
      %w[shop my-shop my_shop 2fa _x].push('a' * 64).each do |name|
        expect(problems(recipe_text(name))).to eq([]), name
      end
    end

    it 'requires the key recipe, with the name of the api and a version' do
      expect(problems(recipe_text('shop', 'recipe' => nil))).to eq(['the key recipe is required, with name and version'])
      expect(problems(recipe_text('shop', 'recipe' => 'x'))).to eq(['the key recipe is required, with name and version'])
      expect(problems(recipe_text('shop', recipe: { 'name' => 'other' })))
        .to eq(["recipe.name must be 'shop', the name of the api"])
      expect(problems(recipe_text('shop', recipe: { 'name' => nil })))
        .to eq(["recipe.name must be 'shop', the name of the api"])
      expect(problems(recipe_text('shop', recipe: { 'version' => nil }))).to eq(['recipe.version is required'])
    end

    it 'takes a version made of digits, letters and dots, written as text' do
      %w[1 1.2.0 2026.10 1.0.0.beta1 v2].each do |version|
        expect(problems(recipe_text('shop', recipe: { 'version' => version }))).to eq([]), version
      end
      ['1..2', '.1', '1.', '1-2', '1 2', '1/2', '', '1' * 33, "1\n"].each do |version|
        expect(problems(recipe_text('shop', recipe: { 'version' => version })))
          .to eq(['recipe.version must be made of digits, letters and dots, at most 32 characters']), version.inspect
      end
      expect(problems(recipe_text('shop', recipe: { 'version' => 1.2 })))
        .to eq(['recipe.version must be text: write it between quotes'])
    end

    it 'takes format 1, or none, and refuses any other' do
      expect(problems(recipe_text('shop', recipe: { 'format' => 1 }))).to eq([])
      expect(problems(recipe_text('shop', recipe: { 'format' => 2 })))
        .to eq(['recipe.format 2 is not known to this version of api_recipes (it knows 1): update the gem'])
      expect(problems(recipe_text('shop', recipe: { 'format' => '1' })).size).to eq(1)
    end

    it 'checks the summary, the homepage and the other keys of recipe' do
      expect(problems(recipe_text('shop', recipe: { 'summary' => "two\nlines" })))
        .to eq(['recipe.summary must be one line of text, at most 200 characters'])
      expect(problems(recipe_text('shop', recipe: { 'summary' => 'x' * 201 })).size).to eq(1)
      expect(problems(recipe_text('shop', recipe: { 'summary' => 3 })).size).to eq(1)
      expect(problems(recipe_text('shop', recipe: { 'homepage' => 'https://example.test/docs' }))).to eq([])
      ['javascript:alert(1)', 'https://example.test/a b', 'ftp://example.test', 7].each do |homepage|
        expect(problems(recipe_text('shop', recipe: { 'homepage' => homepage })))
          .to eq(['recipe.homepage must be an http or https address, without spaces']), homepage.inspect
      end
      expect(problems(recipe_text('shop', recipe: { 'licence' => 'MIT', 'x-team' => 'core' })))
        .to eq(["recipe: unknown key 'licence'"])
    end

    it 'refuses verify_with on the api and on every endpoint, and says where' do
      text = recipe_text('shop', 'verify_with' => 'ok?', 'endpoints' => {
                           'orders' => { 'verify_with' => 'ok?', 'endpoints' => { 'show' => { 'verify_with' => 'ok?' } } },
                           'plain' => nil
                         })
      found = problems(text)
      expect(found.size).to eq(3)
      expect(found).to all(include('verify_with is not allowed in a recipe: add it in your code, with `api :shop, verify_with: ...`'))
      expect(found.map { |problem| problem[/\A\S+/] })
        .to eq(%w[verify_with endpoints.orders.verify_with endpoints.orders.endpoints.show.verify_with])
    end

    it 'requires a host' do
      expect(problems(recipe_text('shop', 'host' => nil))).to eq(['host is required'])
    end

    it 'lets a variable be the whole host, or stand before fixed text that starts with a dot' do
      variables = { 'shop' => nil, 'region' => { 'default' => 'eu' }, 'tld' => { 'default' => 'com' } }
      %w[{shop} {shop}.example.test s3.{region}.example.test {shop}.{region}.example.test {shop}-{region}.example.test].each do |host|
        expect(problems(recipe_text('shop', 'host' => host, 'variables' => variables))).to eq([]), host
      end
      %w[api.example.{tld} {shop}example.test {shop}-example.test {shop}.{tld} {shop}{tld} {shop}. api.{region}].each do |host|
        expect(problems(recipe_text('shop', 'host' => host, 'variables' => variables)).first)
          .to start_with('host: a variable must be the whole host or stand before fixed text that starts with a dot'), host
      end
    end

    it 'reports the problems of the format together' do
      text = recipe_text('shop', 'host' => nil, 'verify_with' => 'ok?', recipe: { 'version' => nil })
      expect(problems(text).size).to eq(3)
    end

    it 'reports what the compiler finds, with the name of the recipe' do
      expect { parse(recipe_text('shop', 'protocol' => 'gopher')) }
        .to raise_error(ApiRecipes::RecipeFileError, /the recipe: shop\.protocol: 'gopher' is not one of http, https/)
      expect(problems(recipe_text('shop', 'host' => 'exämple.test')).first).to start_with('shop.host: must be a plain host name')
    end
  end

  describe '.read' do
    around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

    it 'reads a file called after its api' do
      path = write_recipe(@dir, lock: false)
      expect(described_class.read(path).name).to eq('shop')
      expect(described_class.read(Pathname.new(path)).name).to eq('shop')
    end

    it 'names the file in the error' do
      path = write_recipe(@dir, 'shop', recipe_text('other'), lock: false)
      expect { described_class.read(path) }
        .to raise_error(ApiRecipes::RecipeFileError, /#{Regexp.escape(path)}: the file must be called other\.recipe\.yml/)
    end

    it 'refuses a path that is not text, a file with another kind of name, a missing file and a folder' do
      expect { described_class.read(3) }.to raise_error(ApiRecipes::ConfigurationError, /recipes_paths: every path must be/)
      expect { described_class.read("a\0.recipe.yml") }.to raise_error(ApiRecipes::ConfigurationError, /without null bytes/)
      plain = File.join(@dir, 'shop.yml')
      File.write(plain, recipe_text)
      expect { described_class.read(plain) }.to raise_error(ApiRecipes::RecipeFileError, /is not called NAME\.recipe\.yml/)
      expect { described_class.read(File.join(@dir, 'none.recipe.yml')) }.to raise_error(ApiRecipes::RecipeFileError, /file not found/)
      Dir.mkdir(File.join(@dir, 'dir.recipe.yml'))
      expect { described_class.read(File.join(@dir, 'dir.recipe.yml')) }.to raise_error(ApiRecipes::RecipeFileError, /is not a file/)
    end

    it 'never reads more than the limit' do
      path = File.join(@dir, 'big.recipe.yml')
      File.write(path, 'x' * (described_class::MAX_BYTES + 10))
      expect { described_class.read(path) }.to raise_error(ApiRecipes::RecipeFileError, /is larger than 1048576 bytes/)
    end

    it 'reports a file that cannot be read' do
      path = write_recipe(@dir, lock: false)
      allow(File).to receive(:open).and_call_original
      allow(File).to receive(:open).with(path, 'rb').and_raise(Errno::EACCES)
      expect { described_class.read(path) }.to raise_error(ApiRecipes::RecipeFileError, /cannot read file \(EACCES\)/)
    end
  end
end
