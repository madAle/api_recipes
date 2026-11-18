require 'spec_helper'
require 'api_recipes/cli'

RSpec.describe 'api_recipes install' do
  around do |example|
    with_recipe_repository do |repository|
      @repository = repository
      Dir.mktmpdir do |dir|
        @dir = File.join(File.realpath(dir), 'config', 'api_recipes')
        example.run
      end
    end
  end

  let(:destination) { File.join(@dir, 'shop.recipe.yml') }

  def install(*arguments, input: '')
    run_cli('install', *arguments, '--to', @dir, input: input)
  end

  def from_repository(*arguments, **options)
    install('shop', '--from', @repository.address, *arguments, **options)
  end

  describe 'from a repository' do
    it 'shows the recipe, asks, then writes the file and the lock' do
      commit = @repository.publish('shop', recipe_text)
      code, out, err = from_repository(input: "y\n")
      expect([code, err]).to eq([0, ''])
      expect(out).to eq(<<~TEXT)
        reading shop from #{@repository.address}
        shop 1.0.0
          summary:       A test api
          from:          #{@repository.address}, commit #{commit[0, 12]}
          address:       https://shop.example.test
          credential:    in the Authorization header
          calls:         3, of which 1 is not GET:
            POST  shop.orders.create  /orders
        Install shop 1.0.0 in #{@dir}? [y/N] shop 1.0.0 is installed in #{destination}
      TEXT
      expect(File.read(destination)).to eq(recipe_text)
      expect(read_lock(@dir)).to eq('format' => 1, 'recipes' => { 'shop' => {
                                      'version' => '1.0.0', 'source' => @repository.address, 'commit' => commit,
                                      'sha256' => Digest::SHA256.hexdigest(recipe_text)
                                    } })
      expect(File.read(File.join(@dir, 'recipes.lock'))).to start_with('# Written by api_recipes. Do not edit')
      expect(Dir.children(@dir).sort).to eq(%w[recipes.lock shop.recipe.yml])
    end

    it 'installs a recipe that configure then loads' do
      @repository.publish('shop', recipe_text)
      expect(from_repository('--yes').first).to eq(0)
      configure_recipes(destination)
      expect(ApiRecipes.shop.orders.show(1).url.to_s).to eq('https://shop.example.test/orders/1')
      expect(run_cli('check', '--dir', @dir).first).to eq(0)
    end

    it 'takes yes as an answer, in any letter case' do
      @repository.publish('shop', recipe_text)
      expect(from_repository(input: " YES \n").first).to eq(0)
    end

    it 'writes nothing when the answer is not yes' do
      @repository.publish('shop', recipe_text)
      ["n\n", "\n", '', "maybe\n", "yes please\n"].each do |answer|
        code, out, err = from_repository(input: answer)
        expect([code, err]).to eq([1, "nothing was written\n"]), answer.inspect
        expect(out).to end_with("Install shop 1.0.0 in #{@dir}? [y/N] ")
      end
      expect(File.exist?(@dir)).to eq(false)
    end

    it 'does not ask with --yes' do
      @repository.publish('shop', recipe_text)
      code, out, = from_repository('--yes')
      expect(code).to eq(0)
      expect(out).not_to include('[y/N]')
    end

    it 'shows the warnings before asking' do
      @repository.publish('shop', recipe_text('shop', 'protocol' => 'http', 'auth' => { 'type' => 'query', 'name' => 'key' }))
      _code, out, = from_repository
      expect(out).to include("  warning: the credential travels in the address, as the query parameter key",
                             "  warning: the protocol is http: a credential you assign travels without encryption\nInstall shop")
    end

    it 'installs the version asked for, at the commit of its tag' do
      old = recipe_text
      commit = @repository.publish('shop', old, tag: '1.0.0')
      @repository.publish('shop', recipe_text('shop', recipe: { 'version' => '2.0.0' }), tag: '2.0.0')
      code, out, = from_repository('--version', '1.0.0', '--yes')
      expect(code).to eq(0)
      expect(out).to include('shop 1.0.0 is installed')
      expect(File.read(destination)).to eq(old)
      expect(read_lock(@dir)['recipes']['shop']).to include('version' => '1.0.0', 'commit' => commit)
    end

    it 'refuses a tag whose file says another version' do
      @repository.publish('shop', recipe_text, tag: '3.0.0')
      code, _out, err = from_repository('--version', '3.0.0', '--yes')
      expect(code).to eq(1)
      expect(err).to eq("the tag shop-3.0.0 of #{@repository.address} holds version 1.0.0: nothing was written\n")
      expect(File.exist?(@dir)).to eq(false)
    end

    it 'says when the version or the recipe is not in the repository' do
      @repository.publish('shop', recipe_text)
      code, _out, err = from_repository('--version', '9.9.9', '--yes')
      expect([code, err]).to eq([1, "version 9.9.9 of shop is not in #{@repository.address}: there is no tag shop-9.9.9\n"])
      code, _out, err = install('bank', '--from', @repository.address, '--yes')
      expect([code, err]).to eq([1, "bank is not in #{@repository.address}: there is no recipes/bank.recipe.yml\n"])
    end

    it 'refuses a recipe that is not valid, with every problem, and writes nothing' do
      @repository.publish('shop', recipe_text('shop', 'verify_with' => 'ok?', 'timeout' => 0, 'host' => 'api.example.{tld}',
                                              'variables' => { 'tld' => { 'default' => 'test' } }))
      code, out, err = from_repository('--yes')
      expect(code).to eq(1)
      expect(out).to eq(reading)
      expect(err.lines.size).to eq(2)
      expect(err.lines).to all(start_with("shop in #{@repository.address}: "))
      expect(File.exist?(@dir)).to eq(false)
    end

    it 'refuses a file of the repository that holds another api' do
      @repository.publish('shop', recipe_text('bank'))
      code, _out, err = from_repository('--yes')
      expect(code).to eq(1)
      expect(err).to eq("shop in #{@repository.address}: the file must be called bank.recipe.yml, after its api\n")
    end

    it 'exits with 2 when git cannot read the repository' do
      code, _out, err = install('shop', '--from', "#{@repository.address}/none", '--yes')
      expect(code).to eq(2)
      expect(err).to start_with('git could not read file:')
    end

    it 'takes the cookbook when no repository is given' do
      found = ApiRecipes::CLI::Recipes::Git::Found.new(text: recipe_text, commit: 'a' * 40)
      git = instance_double(ApiRecipes::CLI::Recipes::Git, fetch: found)
      expect(ApiRecipes::CLI::Recipes::Git).to receive(:new).with('https://github.com/madAle/api_recipes-cookbook', ask: false).and_return(git)
      code, out, = install('shop', '--yes')
      expect(code).to eq(0)
      expect(out).to start_with("reading shop from https://github.com/madAle/api_recipes-cookbook\n")
      expect(out).to include("  from:          https://github.com/madAle/api_recipes-cookbook, commit #{'a' * 12}")
      expect(git).to have_received(:fetch).with('shop', nil)
    end

    it 'refuses an address that is not https without a user, or ssh without a password, before running git' do
      expect(Open3).not_to receive(:capture3)
      %w[http://example.test/r example.test:r/r ssh://me:secret@example.test/r git@-example.test:r
         https://me:secret@example.test/r /tmp/r].each do |address|
        stub_const('ApiRecipes::CLI::Recipes::Git::PROTOCOLS', %w[https ssh].freeze)
        code, out, err = install('shop', '--from', address, '--yes')
        expect([code, out]).to eq([2, '']), address
        expect(err).to start_with('--from must '), address
      end
    end

    it 'lets git ask for the credentials of the repository only when its input is a terminal' do
      found = ApiRecipes::CLI::Recipes::Git::Found.new(text: recipe_text, commit: 'a' * 40)
      git = instance_double(ApiRecipes::CLI::Recipes::Git, fetch: found)
      { true => true, false => false }.each do |terminal, ask|
        input = instance_double(IO, tty?: terminal, gets: "n\n")
        expect(ApiRecipes::CLI::Recipes::Git).to receive(:new).with('https://example.test/r', ask: ask).and_return(git)
        ApiRecipes::CLI::Recipes.new(out: StringIO.new, err: StringIO.new, input: input)
                                .install('shop', from: 'https://example.test/r', directory: @dir)
      end
      expect(ApiRecipes::CLI::Recipes::Git).to receive(:new).with('https://example.test/r', ask: false).and_return(git)
      ApiRecipes::CLI::Recipes.new(out: StringIO.new, err: StringIO.new).install('shop', from: 'https://example.test/r', directory: @dir)
    end

    it 'refuses a version that is not made of digits, letters and dots, before running git' do
      expect(Open3).not_to receive(:capture3)
      ['1.0 --x', '../1', "1\n2", 'a' * 33].each do |version|
        code, _out, err = from_repository('--version', version, '--yes')
        expect([code, err]).to eq([2, "--version must be made of digits, letters and dots\n"]), version.inspect
      end
    end

    it 'does nothing when the same recipe is already installed' do
      @repository.publish('shop', recipe_text)
      from_repository('--yes')
      before = File.mtime(destination)
      code, out, err = from_repository
      expect([code, out, err]).to eq([0, "#{reading}shop 1.0.0 is already installed in #{@dir}: nothing to do\n", ''])
      expect(File.mtime(destination)).to eq(before)
    end

    it 'shows what changes when it replaces an installed recipe' do
      @repository.publish('shop', recipe_text)
      from_repository('--yes')
      @repository.publish('shop', recipe_text('shop', 'host' => 'other.example.test', recipe: { 'version' => '1.1.0' }))
      code, out, = from_repository(input: "y\n")
      expect(code).to eq(0)
      expect(out).to include("  changes from shop 1.0.0:\n    address: https://shop.example.test -> https://other.example.test\n")
      expect(read_lock(@dir)['recipes']['shop']['version']).to eq('1.1.0')
    end

    it 'keeps the other entries of the lock' do
      @repository.publish('shop', recipe_text)
      @repository.publish('bank', recipe_text('bank'))
      from_repository('--yes')
      expect(install('bank', '--from', @repository.address, '--yes').first).to eq(0)
      expect(read_lock(@dir)['recipes'].keys).to eq(%w[bank shop])
      expect(run_cli('check', '--dir', @dir).first).to eq(0)
    end

    it 'installs in config/api_recipes when no folder is given' do
      @repository.publish('shop', recipe_text)
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          expect(run_cli('install', 'shop', '--from', @repository.address, '--yes').first).to eq(0)
          expect(File.exist?('config/api_recipes/shop.recipe.yml')).to eq(true)
          expect(run_cli('install', 'shop', '--from', @repository.address, '--dir', 'other', '--yes').first).to eq(0)
          expect(File.exist?('other/recipes.lock')).to eq(true)
        end
      end
    end
  end

  describe 'from a file' do
    def source(text = recipe_text, name = 'shop')
      folder = File.join(File.dirname(@dir), 'incoming')
      FileUtils.mkdir_p(folder)
      write_recipe(folder, name, text, lock: false)
    end

    it 'copies the file and writes an entry without source and commit' do
      path = source
      code, out, err = install(path, input: "y\n")
      expect([code, err]).to eq([0, ''])
      expect(out).to include("  from:          the file #{path}", "shop 1.0.0 is installed in #{destination}")
      expect(File.read(destination)).to eq(recipe_text)
      expect(read_lock(@dir)).to eq('format' => 1, 'recipes' => { 'shop' => { 'version' => '1.0.0',
                                                                             'sha256' => Digest::SHA256.hexdigest(recipe_text) } })
    end

    it 'accepts an installed file as it is now, without touching it' do
      @repository.publish('shop', recipe_text)
      from_repository('--yes')
      edited = recipe_text('shop', 'timeout' => 10)
      File.write(destination, edited)
      expect { configure_recipes(destination) }.to raise_error(ApiRecipes::ConfigurationError, /was changed after it was installed/)
      before = File.stat(destination).ino
      code, out, = install(destination, input: "y\n")
      expect(code).to eq(0)
      expect(out).not_to include('changes from')
      expect(File.stat(destination).ino).to eq(before)
      expect(read_lock(@dir)['recipes']['shop']).to eq('version' => '1.0.0', 'sha256' => Digest::SHA256.hexdigest(edited))
      configure_recipes(destination)
      expect(ApiRecipes.shop.definition.timeout).to eq(10)
    end

    it 'says that the changes made by hand to the installed file will be lost' do
      @repository.publish('shop', recipe_text)
      from_repository('--yes')
      File.write(destination, recipe_text('shop', 'timeout' => 10))
      _code, out, = from_repository
      expect(out).to include("  #{destination} was changed after it was installed: those changes will be lost\n",
                             "    no change in the address, the credential, the headers, the parameters or the verbs\n")
    end

    it 'says that a recipe written in the project, which the lock does not name, will be replaced' do
      FileUtils.mkdir_p(@dir)
      File.write(destination, recipe_text('shop', 'timeout' => 10))
      _code, out, = install(source)
      expect(out).to include("  #{destination} is a recipe that recipes.lock does not name: what it holds now will be lost\n")
    end

    it 'says when it replaces a file that is not a valid recipe' do
      FileUtils.mkdir_p(@dir)
      File.write(destination, "shop: [broken\n")
      _code, out, = install(source)
      expect(out).to include("  it replaces a file that is not a valid recipe\n")
    end

    it 'takes neither --from nor --version' do
      path = source
      expect(install(path, '--version', '1.0.0')).to eq([2, '', "--from and --version go with the name of a recipe, not with a file\n"])
      expect(install(path, '--from', @repository.address).first).to eq(2)
    end

    it 'exits with 2 for a file that is not there and for a folder, with 1 for a file that is not a valid recipe' do
      expect(install('./none.recipe.yml', '--yes')).to eq([2, '', "./none.recipe.yml: no such file\n"])
      expect(install(@repository.directory, '--yes')).to eq([2, '', "#{@repository.directory}: is not a file\n"])
      code, _out, err = install(source(recipe_text('shop', 'host' => nil)), '--yes')
      expect(code).to eq(1)
      expect(err).to end_with("shop.recipe.yml: host is required\n")
    end

    it 'says when the file cannot be read' do
      path = source
      allow(File).to receive(:readable?).and_call_original
      allow(File).to receive(:readable?).with(path).and_return(false)
      expect(install(path, '--yes')).to eq([2, '', "#{path}: cannot be read\n"])
    end
  end

  describe 'writing' do
    before { @repository.publish('shop', recipe_text) }

    it 'does not write through a link, for the recipe and for the lock' do
      FileUtils.mkdir_p(@dir)
      target = File.join(File.dirname(@dir), 'target')
      File.write(target, 'untouched')
      %w[shop.recipe.yml recipes.lock].each do |name|
        link = File.join(@dir, name)
        File.symlink(target, link)
        code, out, err = from_repository('--yes')
        expect([code, out, err]).to eq([2, reading, "#{link} is a link: api_recipes does not write through links\n"])
        File.delete(link)
      end
      expect(File.read(target)).to eq('untouched')
      expect(Dir.children(@dir)).to eq([])
    end

    it 'does not write through a link that points nowhere' do
      FileUtils.mkdir_p(@dir)
      File.symlink(File.join(@dir, 'nowhere'), destination)
      expect(from_repository('--yes').first).to eq(2)
      expect(File.exist?(File.join(@dir, 'nowhere'))).to eq(false)
    end

    it 'refuses a destination that is not a folder, and an installed recipe that is a folder' do
      FileUtils.mkdir_p(File.dirname(@dir))
      File.write(@dir, 'a file')
      expect(from_repository('--yes')).to eq([2, reading, "#{@dir} is not a folder\n"])
      File.delete(@dir)
      FileUtils.mkdir_p(destination)
      expect(from_repository('--yes')).to eq([2, reading, "#{destination} is not a file\n"])
    end

    it 'stops at a lock it cannot use' do
      FileUtils.mkdir_p(@dir)
      File.write(File.join(@dir, 'recipes.lock'), "format: 9\n")
      code, out, err = from_repository('--yes')
      expect([code, out]).to eq([1, reading])
      expect(err).to include('recipes.lock: format 9 is not known')
      expect(File.exist?(destination)).to eq(false)
    end

    it 'exits with 2 when the folder cannot be written, and leaves no temporary file' do
      allow(File).to receive(:open).and_call_original
      allow(File).to receive(:open).with(/\.tmp\z/, any_args).and_raise(Errno::EACCES)
      code, _out, err = from_repository('--yes')
      expect([code, err]).to eq([2, "could not write (EACCES): check the folder and its recipes.lock\n"])
      expect(Dir.children(@dir)).to eq([])
    end

    it 'never deletes a file it did not create, even one with the name of its temporary file' do
      FileUtils.mkdir_p(@dir)
      mine = "#{destination}.#{Process.pid}.tmp"
      File.write(mine, 'mine')
      code, _out, err = from_repository('--yes')
      expect([code, err]).to eq([2, "could not write (EEXIST): check the folder and its recipes.lock\n"])
      expect(File.read(mine)).to eq('mine')
    end

    it 'writes the bytes of the recipe as they are, also when its lines end with a carriage return and a new line' do
      text = recipe_text.gsub("\n", "\r\n")
      @repository.git('config', 'core.autocrlf', 'false')
      @repository.publish('shop', text)
      expect(from_repository('--yes').first).to eq(0)
      expect(File.binread(destination)).to eq(text.b)
      expect(run_cli('check', '--dir', @dir).first).to eq(0)
    end

    it 'exits with 2 when the lock or the installed recipe is there and cannot be read' do
      expect(from_repository('--yes').first).to eq(0)
      [File.join(@dir, 'recipes.lock'), destination].each do |unreadable|
        allow(File).to receive(:readable?).and_call_original
        allow(File).to receive(:readable?).with(unreadable).and_return(false)
        expect(from_repository('--yes')).to eq([2, reading, "#{unreadable}: cannot be read\n"])
        RSpec::Mocks.space.proxy_for(File).reset
      end
    end

    it 'leaves the lock as it was when the recipe cannot be put in its place' do
      allow(File).to receive(:rename).and_raise(Errno::EXDEV)
      expect(from_repository('--yes').first).to eq(2)
      expect(Dir.children(@dir)).to eq([])
    end
  end

  describe 'the lock it writes' do
    it 'is read back before it is written' do
      entry = ApiRecipes::Internals::RecipeLock::Entry.new(version: '1.0.0', source: "https://example.test/it's", commit: 'a' * 40,
                                                           sha256: 'b' * 64)
      text = ApiRecipes::CLI::Recipes::LockFile.text('shop' => entry)
      expect(text).to include("    source: 'https://example.test/it''s'\n")
      expect(YAML.safe_load(text)['recipes']['shop']['source']).to eq("https://example.test/it's")
      broken = ApiRecipes::Internals::RecipeLock::Entry.new(version: '1.0.0', source: nil, commit: nil, sha256: "b\n")
      expect { ApiRecipes::CLI::Recipes::LockFile.text('shop' => broken) }
        .to raise_error(ApiRecipes::Error, 'internal error: recipes.lock does not read back as it was written')
    end

    it 'keeps a version that looks like a number as text' do
      @repository.publish('shop', recipe_text('shop', recipe: { 'version' => '2' }))
      expect(from_repository('--yes').first).to eq(0)
      expect(read_lock(@dir)['recipes']['shop']['version']).to eq('2')
      expect(run_cli('check', '--dir', @dir).first).to eq(0)
    end
  end

  it 'needs one name or one file, and knows its options' do
    expect(run_cli('install')).to eq([2, '', "install needs the name of one recipe, or one file\n"])
    expect(run_cli('install', 'a', 'b').first).to eq(2)
    code, _out, err = run_cli('install', 'shop', '--nope')
    expect([code, err]).to eq([2, "invalid option: --nope\n"])
  end
end
