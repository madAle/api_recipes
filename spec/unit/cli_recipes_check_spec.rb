require 'spec_helper'
require 'api_recipes/cli'

RSpec.describe 'api_recipes check' do
  around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

  describe 'with files' do
    it 'accepts a valid recipe and says what it is, without looking at the lock' do
      path = write_recipe(@dir, lock: false)
      code, out, err = run_cli('check', path)
      expect([code, out, err]).to eq([0, "#{path}: shop 1.0.0, 3 calls\n", ''])
    end

    it 'counts one call as one' do
      path = write_recipe(@dir, 'shop', recipe_text('shop', 'endpoints' => { 'list' => nil }), lock: false)
      expect(run_cli('check', path)[1]).to eq("#{path}: shop 1.0.0, 1 call\n")
    end

    it 'prints the warnings and still exits with 0' do
      text = recipe_text('shop', 'protocol' => 'http', 'auth' => { 'type' => 'query', 'name' => 'key' })
      path = write_recipe(@dir, 'shop', text, lock: false)
      code, out, err = run_cli('check', path)
      expect(code).to eq(0)
      expect(out).to eq("#{path}: shop 1.0.0, 3 calls\n")
      expect(err.lines.map(&:chomp)).to eq([
        "#{path}: warning: the credential travels in the address, as the query parameter key: " \
        'addresses are written in logs and kept by proxies',
        "#{path}: warning: the protocol is http: a credential you assign travels without encryption"
      ])
    end

    it 'reports every problem of a recipe that is not valid and exits with 1' do
      path = write_recipe(@dir, 'shop', recipe_text('shop', 'host' => nil, 'verify_with' => 'ok?'), lock: false)
      code, out, err = run_cli('check', path)
      expect(code).to eq(1)
      expect(out).to eq('')
      expect(err.lines.size).to eq(2)
      expect(err.lines).to all(start_with("#{path}: "))
    end

    it 'reports what the compiler finds' do
      path = write_recipe(@dir, 'shop', recipe_text('shop', 'timeout' => 0), lock: false)
      code, _out, err = run_cli('check', path)
      expect(code).to eq(1)
      expect(err).to eq("#{path}: shop.timeout: must be a positive number\n")
    end

    it 'refuses a file that is not called after its api' do
      path = File.join(@dir, 'shop.yml')
      File.write(path, recipe_text)
      code, _out, err = run_cli('check', path)
      expect(code).to eq(1)
      expect(err).to include('is not called NAME.recipe.yml')
    end

    it 'checks several files and exits with the worst code' do
      good = write_recipe(@dir, lock: false)
      bad = write_recipe(@dir, 'bank', "bank: {}\n", lock: false)
      missing = File.join(@dir, 'none.recipe.yml')
      code, out, err = run_cli('check', good, bad)
      expect(code).to eq(1)
      expect(out).to eq("#{good}: shop 1.0.0, 3 calls\n")
      expect(err).to include("#{bad}: the key recipe is required")
      code, _out, err = run_cli('check', good, bad, missing, @dir)
      expect(code).to eq(2)
      expect(err).to include("#{missing}: no such file", "#{@dir}: is not a file")
    end

    it 'says when a file cannot be read' do
      path = write_recipe(@dir, lock: false)
      allow(File).to receive(:readable?).and_call_original
      allow(File).to receive(:readable?).with(path).and_return(false)
      expect(run_cli('check', path)).to eq([2, '', "#{path}: cannot be read\n"])
    end
  end

  describe 'without files' do
    it 'accepts the recipes that match the lock of the folder' do
      shop = write_recipe(@dir)
      bank = write_recipe(@dir, 'bank', recipe_text('bank'))
      File.write(File.join(@dir, 'notes.yml'), 'x')
      code, out, err = run_cli('check', '--dir', @dir)
      expect([code, out, err]).to eq([0, "#{bank}: bank 1.0.0, 3 calls\n#{shop}: shop 1.0.0, 3 calls\n", ''])
    end

    it 'looks in config/api_recipes when no folder is given' do
      Dir.chdir(@dir) do
        FileUtils.mkdir_p('config/api_recipes')
        write_recipe('config/api_recipes')
        expect(run_cli('check')).to eq([0, "config/api_recipes/shop.recipe.yml: shop 1.0.0, 3 calls\n", ''])
      end
    end

    it 'says when the folder has no recipes' do
      expect(run_cli('check', '--dir', @dir)).to eq([0, "no recipes in #{@dir}\n", ''])
    end

    it 'exits with 2 when the folder does not exist' do
      missing = File.join(@dir, 'none')
      expect(run_cli('check', '--dir', missing)).to eq([2, '', "#{missing}: no such folder\n"])
    end

    it 'reports a recipe that is not in the lock' do
      path = write_recipe(@dir, lock: false)
      code, out, err = run_cli('check', '--dir', @dir)
      expect(code).to eq(1)
      expect(out).to eq('')
      expect(err).to eq("#{path}: is not in recipes.lock (there is no recipes.lock in its folder): a recipe is loaded only " \
                        "after it was installed. Install it with `api_recipes install #{path}`\n")
    end

    it 'reports a recipe changed after it was installed, without parsing it' do
      path = write_recipe(@dir)
      File.write(path, "shop: [broken\n")
      code, _out, err = run_cli('check', '--dir', @dir)
      expect(code).to eq(1)
      expect(err).to eq("#{path}: was changed after it was installed: its checksum is not the one in recipes.lock. " \
                        "To accept the file as it is now, run `api_recipes install #{path}`\n")
    end

    it 'reports an entry of the lock whose file is missing' do
      write_recipe(@dir)
      add_to_lock(@dir, 'bank', 'x')
      code, out, err = run_cli('check', '--dir', @dir)
      expect(code).to eq(1)
      expect(out).to include('shop 1.0.0')
      expect(err).to eq("#{File.join(@dir, 'recipes.lock')}: bank is in the lock, but #{File.join(@dir, 'bank.recipe.yml')} is missing\n")
    end

    it 'reports a version in the lock that is not the one of the file' do
      write_recipe(@dir, version: '9.9.9')
      code, _out, err = run_cli('check', '--dir', @dir)
      expect(code).to eq(1)
      expect(err).to eq("#{File.join(@dir, 'recipes.lock')}: shop is version 9.9.9 in the lock, but the file says 1.0.0\n")
    end

    it 'reports an installed recipe that is not valid' do
      path = write_recipe(@dir, 'shop', recipe_text('shop', 'host' => nil))
      code, _out, err = run_cli('check', '--dir', @dir)
      expect(code).to eq(1)
      expect(err).to eq("#{path}: host is required\n")
    end

    it 'reports a lock that cannot be used' do
      write_recipe(@dir)
      File.write(File.join(@dir, 'recipes.lock'), "format: 9\n")
      code, _out, err = run_cli('check', '--dir', @dir)
      expect(code).to eq(1)
      expect(err).to include('recipes.lock: format 9 is not known')
    end

    it 'exits with 2 when the folder cannot be listed' do
      allow(Dir).to receive(:children).and_raise(Errno::EACCES)
      expect(run_cli('check', '--dir', @dir)).to eq([2, '', "#{@dir}: cannot be read (EACCES)\n"])
    end
  end

  it 'exits with 2 for an option it does not know' do
    code, _out, err = run_cli('check', '--nope')
    expect(code).to eq(2)
    expect(err).to include('invalid option: --nope')
  end

  it 'exits with 2 when the lock or an installed recipe is there and cannot be read' do
    path = write_recipe(@dir)
    lock = File.join(@dir, 'recipes.lock')
    [lock, path].each do |unreadable|
      allow(File).to receive(:readable?).and_call_original
      allow(File).to receive(:readable?).with(unreadable).and_return(false)
      expect(run_cli('check', '--dir', @dir)).to eq([2, '', "#{unreadable}: cannot be read\n"])
      RSpec::Mocks.space.proxy_for(File).reset
    end
  end

  it 'answers an argument that is not valid text with a message, for every command' do
    %w[check install update routes upgrade import].each do |command|
      out = StringIO.new
      err = StringIO.new
      code = ApiRecipes::CLI.run([command, "bad\xFF".dup.force_encoding(Encoding::UTF_8)], out: out, err: err)
      expect([code, out.string, err.string]).to eq([2, '', "the arguments must be valid text in the encoding of the terminal\n"])
    end
  end
end
