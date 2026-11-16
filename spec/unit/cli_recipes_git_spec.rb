require 'spec_helper'
require 'api_recipes/cli'

RSpec.describe ApiRecipes::CLI::Recipes::Git do
  describe '.address_problem' do
    it 'accepts an https address' do
      %w[https://github.com/acme/api-recipes https://git.example.test:8443/team/recipes.git https://example.test
         https://example.test/~me/a_b+c].each do |address|
        expect(described_class.address_problem(address)).to be_nil, address
      end
    end

    it 'refuses every other way to reach a repository' do
      %w[http://example.test/r git://example.test/r ssh://example.test/r file:///tmp/r ext::sh /tmp/r ./r
         HTTPS://example.test/r https:/example.test -https://example.test].push('', 'example.test/r', 'https://').each do |address|
        expect(described_class.address_problem(address)).to match(/must start with https:\/\/|must name a host/), address
      end
    end

    it 'refuses a user name or a password, which would end up in the lock' do
      %w[https://me@example.test/r https://me:secret@example.test/r https://:token@example.test/r git@example.test:r].each do |address|
        problem = described_class.address_problem(address)
        expect(problem).not_to be_nil, address
      end
      expect(described_class.address_problem('https://me:secret@example.test/r'))
        .to eq('must not contain a user name or a password: git takes them from its own configuration')
    end

    it 'refuses a query, a fragment, a space, a control character, an option of git and what is not text' do
      ['https://example.test/r?x=1', 'https://example.test/r#x', 'https://example.test/a b', "https://example.test/r\n--upload-pack=x",
       'https://example.test/r --upload-pack=x', 'https://example.test/%2e%2e', "https://example.test/r\u202E"].each do |address|
        expect(described_class.address_problem(address)).to eq('must start with https://'), address.inspect
      end
      expect(described_class.address_problem(nil)).to eq('must be text')
      expect(described_class.address_problem("https://example.test/#{'a' * 2000}")).to eq('must be at most 2000 characters')
    end

    it 'refuses to be built with an address it would not use' do
      expect { described_class.new('ssh://example.test/r') }
        .to raise_error(described_class::Failure, 'the address of the repository must start with https://')
    end
  end

  describe '#fetch' do
    around { |example| with_recipe_repository { |repository| @repository = repository; example.run } }

    def fetch(...) = described_class.new(@repository.address).fetch(...)

    it 'reads the recipe at the head of the repository, with its commit' do
      commit = @repository.publish('shop', recipe_text)
      found = fetch('shop')
      expect(found.text).to eq(recipe_text)
      expect(found.text.encoding).to eq(Encoding::UTF_8)
      expect(found.commit).to eq(commit)
    end

    it 'reads the recipe at the tag of a version, also when the head has moved on' do
      old = recipe_text
      commit = @repository.publish('shop', old, tag: '1.0.0')
      @repository.publish('shop', recipe_text('shop', recipe: { 'version' => '2.0.0' }), tag: '2.0.0')
      found = fetch('shop', '1.0.0')
      expect(found.text).to eq(old)
      expect(found.commit).to eq(commit)
    end

    it 'reads the commit behind an annotated tag' do
      commit = @repository.publish('shop', recipe_text)
      @repository.git('tag', '--annotate', '--message', 'release', 'shop-1.0.0')
      @repository.publish('shop', recipe_text('shop', recipe: { 'version' => '2.0.0' }))
      expect(fetch('shop', '1.0.0').commit).to eq(commit)
    end

    it 'says when the version is not there' do
      @repository.publish('shop', recipe_text, tag: '1.0.0')
      expect { fetch('shop', '9.9.9') }
        .to raise_error(described_class::NotFound, "version 9.9.9 of shop is not in #{@repository.address}: there is no tag shop-9.9.9")
    end

    it 'says when the recipe is not there' do
      @repository.publish('shop', recipe_text)
      expect { fetch('bank') }
        .to raise_error(described_class::NotFound, "bank is not in #{@repository.address}: there is no recipes/bank.recipe.yml")
    end

    it 'does not read a link, a folder or a submodule that has the name of the recipe' do
      @repository.commit('target.yml', recipe_text)
      FileUtils.mkdir_p(File.join(@repository.directory, 'recipes'))
      File.symlink('../target.yml', File.join(@repository.directory, 'recipes/shop.recipe.yml'))
      @repository.commit('recipes/bank.recipe.yml/inner.yml', recipe_text('bank'))
      @repository.git('update-index', '--add', '--cacheinfo', "160000,#{@repository.head},recipes/post.recipe.yml")
      @repository.git('commit', '--quiet', '--message', 'submodule')
      %w[shop bank post].each do |name|
        expect { fetch(name) }.to raise_error(described_class::NotFound, /recipes\/#{name}\.recipe\.yml in .* is not a regular file/)
      end
    end

    it 'does not follow a recipes folder that is a link' do
      @repository.commit('real/shop.recipe.yml', recipe_text)
      File.symlink('real', File.join(@repository.directory, 'recipes'))
      @repository.commit_all
      expect { fetch('shop') }.to raise_error(described_class::NotFound, /there is no recipes\/shop\.recipe\.yml/)
    end

    it 'does not read a file larger than a recipe can be' do
      @repository.publish('shop', "# #{'x' * ApiRecipes::Internals::Recipe::MAX_BYTES}\n")
      expect(Open3).to receive(:capture3).and_wrap_original do |original, *arguments, **options|
        expect(arguments).not_to include('blob')
        original.call(*arguments, **options)
      end.at_least(:once)
      expect { fetch('shop') }.to raise_error(described_class::NotFound, /is larger than 1048576 bytes: it was not read/)
    end

    it 'reads an executable file as the regular file it is' do
      @repository.publish('shop', recipe_text)
      @repository.git('update-index', '--chmod=+x', 'recipes/shop.recipe.yml')
      @repository.git('commit', '--quiet', '--message', 'mode')
      expect(fetch('shop').text).to eq(recipe_text)
    end

    it 'says when git cannot read the repository' do
      missing = described_class.new("file://#{@repository.directory}/none")
      expect { missing.fetch('shop') }.to raise_error(described_class::Failure, /\Agit could not read file:.*none: /)
    end

    it 'takes only the name and the version of a recipe' do
      expect { fetch('../shop') }.to raise_error(ArgumentError)
      expect { fetch('shop', '1.0 --upload-pack=x') }.to raise_error(ArgumentError)
      expect { fetch('--upload-pack=x') }.to raise_error(ArgumentError)
    end

    it 'runs git without a shell, with the address after --' do
      @repository.publish('shop', recipe_text)
      calls = []
      allow(Open3).to receive(:capture3).and_wrap_original do |original, *arguments, **options|
        calls << arguments
        original.call(*arguments, **options)
      end
      fetch('shop')
      expect(calls.size).to be >= 5
      expect(calls.map { |arguments| arguments[1] }).to all(eq('git'))
      expect(calls.map(&:first)).to all(include('GIT_TERMINAL_PROMPT' => '0', 'GIT_ALLOW_PROTOCOL' => 'https:file', 'GIT_DIR' => nil))
      fetching = calls.find { |arguments| arguments.include?('fetch') }
      expect(fetching.last(3)).to eq(['--', @repository.address, 'HEAD'])
      expect(fetching).to include('protocol.allow=never', 'http.followRedirects=false', 'transfer.fsckObjects=true',
                                  '--no-recurse-submodules', '--no-tags', '--depth')
      expect(calls.find { |arguments| arguments.include?('init') }).to include('--bare', '--template=')
      expect(calls.find { |arguments| arguments.include?('ls-tree') }.last(2)).to eq(['--', 'recipes/shop.recipe.yml'])
    end

    it 'uses its own empty repository, whatever GIT_DIR says, and leaves nothing behind' do
      @repository.publish('shop', recipe_text)
      folders = []
      allow(Dir).to receive(:mktmpdir).and_wrap_original do |original, *arguments, &block|
        original.call(*arguments) do |directory|
          folders << directory
          block.call(directory)
        end
      end
      saved = ENV['GIT_DIR']
      ENV['GIT_DIR'] = File.join(@repository.directory, 'nowhere')
      begin
        expect(fetch('shop').text).to eq(recipe_text)
      ensure
        ENV['GIT_DIR'] = saved
      end
      expect(folders.size).to eq(1)
      expect(File.exist?(folders.first)).to eq(false)
      expect(File.exist?(File.join(@repository.directory, 'nowhere'))).to eq(false)
    end
  end

  describe 'the protocols git may use' do
    it 'are only https: a file address is refused by git itself, even if the check of the address is skipped' do
      Dir.mktmpdir do |directory|
        repository = RecipeRepository.new(File.realpath(directory))
        repository.publish('shop', recipe_text)
        allow(described_class).to receive(:address_problem).and_return(nil)
        expect { described_class.new(repository.address).fetch('shop') }
          .to raise_error(described_class::Failure, /git could not read file:.*not allowed \(git may use only https here: check url\.\*\.insteadOf in your git configuration\)\z/)
      end
    end
  end

  describe 'what git says' do
    let(:failed) { instance_double(Process::Status, success?: false) }

    it 'is shown as one line, without control and format characters: the line where git says fatal or error' do
      hidden = [0x202E].pack('U')
      said = "remote: noise\nfatal: bad\e[31m#{hidden}text\nhint: try again\n\n"
      allow(Open3).to receive(:capture3).and_return(['', said.b, failed])
      expect { described_class.new('https://example.test/r').fetch('shop') }
        .to raise_error(described_class::Failure, 'git failed (init): fatal: bad?[31m?text')
    end

    it 'is its last line when no line says fatal or error' do
      allow(Open3).to receive(:capture3).and_return(['', "remote: first\nremote: last\n".b, failed])
      expect { described_class.new('https://example.test/r').fetch('shop') }
        .to raise_error(described_class::Failure, 'git failed (init): remote: last')
    end

    it 'is not needed to fail' do
      allow(Open3).to receive(:capture3).and_return(['', '', failed])
      expect { described_class.new('https://example.test/r').fetch('shop') }
        .to raise_error(described_class::Failure, 'git failed (init): it gave no reason')
    end

    it 'comes with what to do when the repository asks for credentials that git does not have, or refuses them' do
      done = instance_double(Process::Status, success?: true)
      ["fatal: could not read Username for 'https://example.test': terminal prompts disabled\n",
       "fatal: Authentication failed for 'https://example.test/r/'\n"].each do |said|
        allow(Open3).to receive(:capture3) do |_environment, _git, *arguments|
          arguments.include?('fetch') ? ['', said.b, failed] : ['', '', done]
        end
        expect { described_class.new('https://example.test/r').fetch('shop') }
          .to raise_error(described_class::Failure, "git could not read https://example.test/r: #{said.strip} " \
                                                    '(a private repository needs credentials that git already has for ' \
                                                    'its host, such as a credential helper: the command never asks for them)')
      end
    end

    it 'must name a commit' do
      done = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).and_return(['not a commit', '', done])
      expect { described_class.new('https://example.test/r').fetch('shop') }
        .to raise_error(described_class::Failure, 'git did not say which commit of https://example.test/r it read')
    end
  end

  it 'says when git is not installed' do
    allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)
    expect { described_class.new('https://example.test/r').fetch('shop') }
      .to raise_error(described_class::Failure, 'git was not found: install git, or install the recipe from a file')
  end
end
