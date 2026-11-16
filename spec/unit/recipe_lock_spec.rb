require 'spec_helper'

RSpec.describe ApiRecipes::Internals::RecipeLock do
  around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

  let(:sha) { 'a' * 64 }

  def write(data)
    File.write(File.join(@dir, 'recipes.lock'), data.is_a?(String) ? data : YAML.dump(data))
  end

  def problems
    described_class.read(@dir)
    []
  rescue ApiRecipes::RecipeFileError => e
    e.errors.map { |problem| problem.delete_prefix("#{File.join(@dir, 'recipes.lock')}: ") }
  end

  def lock_with(entry)
    { 'format' => 1, 'recipes' => { 'shop' => { 'version' => '1.0.0', 'sha256' => sha }.merge(entry).compact } }
  end

  it 'is empty when the folder has no lock' do
    lock = described_class.read(@dir)
    expect(lock.exists?).to eq(false)
    expect(lock.entries).to eq({})
    expect(lock['shop']).to be_nil
  end

  it 'reads the entries' do
    write(lock_with('source' => 'https://example.test/recipes', 'commit' => 'b' * 40))
    lock = described_class.read(@dir)
    expect(lock.exists?).to eq(true)
    expect(lock.path).to eq(File.join(@dir, 'recipes.lock'))
    expect(lock['shop'].to_h).to eq(version: '1.0.0', source: 'https://example.test/recipes', commit: 'b' * 40, sha256: sha)
    expect(lock).to be_frozen
  end

  it 'reads a lock without recipes' do
    write("format: 1\n")
    expect(described_class.read(@dir).entries).to eq({})
    write("format: 1\nrecipes:\n")
    expect(described_class.read(@dir).entries).to eq({})
  end

  it 'accepts an entry without source and commit, and a commit of 64 digits' do
    write(lock_with({}))
    expect(described_class.read(@dir)['shop'].source).to be_nil
    write(lock_with('source' => 'https://example.test/r', 'commit' => 'c' * 64))
    expect(problems).to eq([])
  end

  it 'refuses a lock that is not the mapping it writes' do
    write("- 1\n")
    expect(problems).to eq(['must be a mapping with format and recipes'])
    write('')
    expect(problems).to eq(['must be a mapping with format and recipes'])
    write('format' => 1, 'recipes' => [], 'other' => 1)
    expect(problems).to eq(["unknown key 'other'", 'recipes must be a mapping'])
    write('format' => 2)
    expect(problems).to eq(['format 2 is not known to this version of api_recipes (it knows 1): update the gem'])
    write("format: 1\nformat: 1\n")
    expect(problems).to eq(["the key 'format' is given twice"])
  end

  it 'refuses an entry that is not what the command writes' do
    write('format' => 1, 'recipes' => { 'Bad name' => {} })
    expect(problems).to eq(["recipes: 'Bad name' is not the name of a recipe"])
    write('format' => 1, 'recipes' => { 'shop' => 'x' })
    expect(problems).to eq(['recipes.shop must be a mapping'])
    write(lock_with('version' => 1.2, 'sha256' => 'short', 'extra' => 1))
    expect(problems).to eq(["recipes.shop: unknown key 'extra'", 'recipes.shop.version must be the version of the recipe, as text',
                            'recipes.shop.sha256 must be a SHA-256 checksum'])
    write(lock_with('source' => "https://example.test/a b", 'commit' => 'zz'))
    expect(problems).to eq(['recipes.shop.source must be an address without spaces', 'recipes.shop.commit must be the id of a commit'])
    write(lock_with('source' => 'https://example.test/r'))
    expect(problems).to eq(['recipes.shop: source and commit go together'])
  end

  it 'refuses a lock that is a folder, one that is too large and one that cannot be read' do
    Dir.mkdir(File.join(@dir, 'recipes.lock'))
    expect(problems).to eq(['is not a file'])
    Dir.rmdir(File.join(@dir, 'recipes.lock'))
    write("# #{'x' * ApiRecipes::Internals::Recipe::MAX_BYTES}\n")
    expect(problems).to eq(['is larger than 1048576 bytes'])
    allow(File).to receive(:open).and_raise(Errno::EACCES)
    expect(problems).to eq(['cannot read file (EACCES)'])
  end

  describe '#problem_for' do
    it 'is nil for the checksum that was installed' do
      write(lock_with({}))
      expect(described_class.read(@dir).problem_for('shop', sha)).to be_nil
    end

    it 'says that the file was changed' do
      write(lock_with({}))
      expect(described_class.read(@dir).problem_for('shop', 'b' * 64))
        .to eq('was changed after it was installed: its checksum is not the one in recipes.lock. ' \
               'To accept the file as it is now, run')
    end

    it 'says that the file was never installed' do
      write(lock_with({}))
      expect(described_class.read(@dir).problem_for('other', sha))
        .to eq('is not in recipes.lock: a recipe is loaded only after it was installed. Install it with')
      File.delete(File.join(@dir, 'recipes.lock'))
      expect(described_class.read(@dir).problem_for('shop', sha))
        .to start_with('is not in recipes.lock (there is no recipes.lock in its folder)')
    end
  end
end
