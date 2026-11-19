require 'spec_helper'
require 'api_recipes/cli'
require 'pathname'
require 'tmpdir'

# A file of a 2.x project that describes apis. The gem no longer loads one:
# the commands read it to check it, to list its calls and to convert it.
describe ApiRecipes::CLI::Description do
  def fixture(name) = File.expand_path("../fixtures/#{name}", __dir__)

  it 'reads the apis of a YAML file, several from one file too' do
    expect(described_class.read(fixture('two_apis.yml')).keys).to eq(%i[svc billing])
    expect(described_class.read(Pathname.new(fixture('svc_override.yml')))[:svc][:host]).to eq('other.example.test')
  end

  it 'evaluates ERB only when asked, and otherwise refuses the file or gives its text to the block' do
    expect(described_class.read(fixture('svc.yml.erb'), erb: true)[:svc][:host]).to eq('api.example.test')
    expect { described_class.read(fixture('svc.yml.erb')) }.to raise_error(ApiRecipes::RecipeFileError, /svc\.yml\.erb: contains ERB/)
    seen = nil
    apis = described_class.read(fixture('svc.yml.erb')) do |text|
      seen = text
      "svc:\n  host: from.the.block\n"
    end
    expect(seen).to include('<%')
    expect(apis).to eq(svc: { host: 'from.the.block' })
  end

  it 'refuses a path that is not a String or a Pathname, or that has a null byte' do
    [nil, 42, :sym, "a\0b.yml"].each do |path|
      expect { described_class.read(path) }.to raise_error(ApiRecipes::ConfigurationError, /every path must be a String or a Pathname/)
    end
  end

  {
    'missing.yml' => /missing\.yml: file not found/,
    'empty.yml'   => /empty\.yml: file is empty/,
    'list.yml'    => /list\.yml: must contain a mapping/,
    'unsafe.yml'  => /unsafe\.yml: invalid YAML/
  }.each do |name, pattern|
    it "names the file when #{name} cannot be read" do
      expect { described_class.read(fixture(name)) }.to raise_error(ApiRecipes::RecipeFileError, pattern)
    end
  end

  describe 'files that are hard to read' do
    around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

    def write(name, content)
      File.binwrite(File.join(@dir, name), content)
      File.join(@dir, name)
    end

    it 'reads a file with non-ASCII UTF-8 text' do
      path = write('utf8.yml', "svc:\n  host: api.example.test\n  endpoints:\n    users: { path: 'caf\u00E9' }\n")
      expect(described_class.read(path)[:svc][:endpoints][:users][:path]).to eq("caf\u00E9")
    end

    it 'names a file that is not valid UTF-8' do
      path = write('latin.yml', "svc: { host: \"caf\xE9\" }\n")
      expect { described_class.read(path) }.to raise_error(ApiRecipes::RecipeFileError, /latin\.yml: file is not valid UTF-8/)
    end

    it 'names a directory given as a file' do
      expect { described_class.read(@dir) }.to raise_error(ApiRecipes::RecipeFileError, /cannot read file \(EISDIR\)/)
    end

    it 'refuses a file with ERB when ERB is not asked for, and runs nothing' do
      marker = File.join(@dir, 'marker')
      path = write('erb.yml', "svc: { host: <%= File.write(#{marker.inspect}, '1') %> }\n")
      expect { described_class.read(path) }.to raise_error(ApiRecipes::RecipeFileError, /erb\.yml: contains ERB/)
      expect(File.exist?(marker)).to be(false)
    end
  end

  describe 'a portable recipe given as such a file' do
    let(:body) { "<% raise 'evaluated' %>\nsvc:\n  host: evil.test\n" }

    def expect_refused(path)
      expect { described_class.read(path, erb: true) }
        .to raise_error(ApiRecipes::RecipeFileError, /is a portable recipe \(\.recipe\.yml\): it is read as data only/)
    end

    it 'is refused without evaluating its ERB, whatever the letter case of the name' do
      Dir.mktmpdir do |dir|
        %w[x.recipe.yml x.RECIPE.YML].each do |name|
          File.write(File.join(dir, name), body)
          expect_refused(File.join(dir, name))
        end
      end
    end

    it 'is refused through a link that points to it' do
      Dir.mktmpdir do |dir|
        target = File.join(dir, 'x.recipe.yml')
        link = File.join(dir, 'plain.yml')
        File.write(target, body)
        File.symlink(target, link)
        expect_refused(link)
      end
    end
  end
end
