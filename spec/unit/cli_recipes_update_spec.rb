require 'spec_helper'
require 'api_recipes/cli'

RSpec.describe 'api_recipes update' do
  around do |example|
    with_recipe_repository do |repository|
      @repository = repository
      Dir.mktmpdir do |dir|
        @dir = File.join(File.realpath(dir), 'recipes')
        example.run
      end
    end
  end

  let(:destination) { File.join(@dir, 'shop.recipe.yml') }

  def installed(text = recipe_text, tag: '1.0.0')
    @repository.publish('shop', text, tag: tag)
    expect(run_cli('install', 'shop', '--from', @repository.address, '--to', @dir, '--yes').first).to eq(0)
  end

  def update(*arguments, input: '')
    run_cli('update', 'shop', '--dir', @dir, *arguments, input: input)
  end

  it 'shows what changes in the address, the credential and the verbs, asks, then replaces the file and the lock' do
    installed
    newer = recipe_text('shop', 'host' => '{tenant}.example.test', 'variables' => { 'tenant' => { 'default' => 'acme' } },
                                'auth' => { 'type' => 'header', 'name' => 'X-Token' },
                                'endpoints' => { 'orders' => { 'endpoints' => {
                                  'show' => { 'path' => '/:id', 'verb' => 'delete' }, 'cancel' => { 'verb' => 'post' }, 'list' => nil
                                } } },
                                recipe: { 'version' => '2.0.0' })
    commit = @repository.publish('shop', newer, tag: '2.0.0')
    code, out, err = update(input: "y\n")
    expect([code, err]).to eq([0, ''])
    expect(out).to include(<<~TEXT)
        changes from shop 1.0.0:
          address: https://shop.example.test -> https://{tenant}.example.test
          with defaults: https://shop.example.test -> https://acme.example.test
          credential: in the Authorization header -> in the header X-Token
          shop.orders.show(id): GET -> DELETE
          new call that is not a GET: POST shop.orders.cancel
          calls: 2 added, 1 removed
      Update shop 2.0.0 in #{@dir}? [y/N] shop 2.0.0 is installed in #{destination}
    TEXT
    expect(File.read(destination)).to eq(newer)
    expect(read_lock(@dir)['recipes']['shop']).to eq('version' => '2.0.0', 'source' => @repository.address, 'commit' => commit,
                                                     'sha256' => Digest::SHA256.hexdigest(newer))
  end

  it 'leaves the file and the lock as they were when the answer is no' do
    installed
    lock = File.read(File.join(@dir, 'recipes.lock'))
    @repository.publish('shop', recipe_text('shop', recipe: { 'version' => '2.0.0' }))
    expect(update(input: "n\n").first).to eq(1)
    expect(File.read(destination)).to eq(recipe_text)
    expect(File.read(File.join(@dir, 'recipes.lock'))).to eq(lock)
  end

  it 'says so when nothing changed in the address, the credential and the verbs' do
    installed
    @repository.publish('shop', recipe_text('shop', 'timeout' => 9, recipe: { 'version' => '1.0.1' }))
    _code, out, = update('--yes')
    expect(out).to include("  changes from shop 1.0.0:\n    no change in the address, the credential, the headers or the verbs\n")
  end

  it 'does nothing when the repository has the same recipe' do
    installed
    expect(update).to eq([0, "shop 1.0.0 is already installed in #{@dir}: nothing to do\n", ''])
  end

  it 'takes the version asked for' do
    installed
    @repository.publish('shop', recipe_text('shop', recipe: { 'version' => '2.0.0' }), tag: '2.0.0')
    @repository.publish('shop', recipe_text('shop', recipe: { 'version' => '3.0.0' }), tag: '3.0.0')
    code, out, = update('--version', '2.0.0', '--yes')
    expect(code).to eq(0)
    expect(out).to include('shop 2.0.0 is installed')
  end

  it 'says that changes made by hand will be lost' do
    installed
    File.write(destination, recipe_text('shop', 'timeout' => 10))
    @repository.publish('shop', recipe_text('shop', recipe: { 'version' => '2.0.0' }))
    _code, out, = update
    expect(out).to include("  #{destination} was changed after it was installed: those changes will be lost\n")
  end

  it 'installs again a recipe whose file is missing' do
    installed
    File.delete(destination)
    expect(update('--yes').first).to eq(0)
    expect(File.read(destination)).to eq(recipe_text)
  end

  it 'looks in config/api_recipes when no folder is given' do
    @repository.publish('shop', recipe_text)
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        expect(run_cli('install', 'shop', '--from', @repository.address, '--yes').first).to eq(0)
        expect(run_cli('update', 'shop')).to eq([0, "shop 1.0.0 is already installed in config/api_recipes: nothing to do\n", ''])
      end
    end
  end

  it 'refuses a recipe that is not installed, and one installed from a file' do
    expect(update).to eq([1, '', "shop is not installed in #{@dir}\n"])
    FileUtils.mkdir_p(@dir)
    path = write_recipe(File.dirname(@dir), lock: false)
    expect(run_cli('install', path, '--to', @dir, '--yes').first).to eq(0)
    expect(update).to eq([1, '', "shop was installed from a file: install the new file with `api_recipes install FILE`\n"])
  end

  it 'takes the whole argument as the name: a name followed by a new line and something else is not a name' do
    installed
    expect(Open3).not_to receive(:capture3)
    expect(run_cli('update', "shop\n--upload-pack=x", '--dir', @dir)).to eq([2, '', "shop?--upload-pack=x is not the name of a recipe\n"])
  end

  it 'exits with 2 when the lock is there and cannot be read' do
    installed
    lock = File.join(@dir, 'recipes.lock')
    allow(File).to receive(:readable?).and_call_original
    allow(File).to receive(:readable?).with(lock).and_return(false)
    expect(update).to eq([2, '', "#{lock}: cannot be read\n"])
  end

  it 'refuses a name that is not the name of a recipe' do
    expect(run_cli('update', '../shop', '--dir', @dir)).to eq([2, '', "../shop is not the name of a recipe\n"])
    code, _out, err = run_cli('update', "sh\u202Eop", '--dir', @dir)
    expect([code, err]).to eq([2, "sh?op is not the name of a recipe\n"])
  end

  it 'refuses a source of the lock that is not an https address without a user, before running git' do
    installed
    lock = File.join(@dir, 'recipes.lock')
    File.write(lock, File.read(lock).sub(@repository.address, 'https://me:secret@example.test/r'))
    expect(Open3).not_to receive(:capture3)
    expect(update('--yes')).to eq([2, '', "#{lock}: the source of shop must not contain a user name or a password: " \
                                          "git takes them from its own configuration\n"])
  end

  it 'refuses the new recipe when it is not valid, and keeps the installed one' do
    installed
    @repository.publish('shop', recipe_text('shop', 'verify_with' => 'ok?', recipe: { 'version' => '2.0.0' }))
    code, _out, err = update('--yes')
    expect(code).to eq(1)
    expect(err).to include('verify_with is not allowed in a recipe')
    expect(File.read(destination)).to eq(recipe_text)
  end

  it 'needs one name, and knows its options' do
    expect(run_cli('update')).to eq([2, '', "update needs the name of one recipe\n"])
    code, _out, err = run_cli('update', 'shop', '--from', 'https://example.test/r')
    expect([code, err]).to eq([2, "invalid option: --from\n"])
  end
end
