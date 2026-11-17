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

    it 'accepts an ssh address, written as ssh:// or as user@host:path' do
      %w[ssh://git@example.test/team/recipes.git ssh://example.test/r ssh://git@example.test:2222/r
         git@github.com:acme/api-recipes.git deploy_1@git.example.test:~me/r git@example.test:/srv/git/r.git].each do |address|
        expect(described_class.address_problem(address)).to be_nil, address
      end
    end

    it 'refuses every other way to reach a repository' do
      %w[http://example.test/r git://example.test/r file:///tmp/r ext::sh /tmp/r ./r SSH://example.test/r
         HTTPS://example.test/r https:/example.test -https://example.test C:/r example.test:r ssh://example.test
         git+ssh://example.test/r].push('', 'example.test/r', 'https://', 'ssh://').each do |address|
        expect(described_class.address_problem(address)).to match(/\Amust start with https:\/\/ or ssh:\/\/|must name a host/), address
      end
    end

    it 'refuses a user name or a password in an https address, which would end up in the lock' do
      %w[https://me@example.test/r https://me:secret@example.test/r https://:token@example.test/r].each do |address|
        expect(described_class.address_problem(address))
          .to eq('must not contain a user name or a password: git takes them from its own configuration'), address
      end
    end

    it 'refuses a password in an ssh address, and keeps its user' do
      %w[ssh://me:secret@example.test/r ssh://:secret@example.test/r ssh://me:@example.test/r].each do |address|
        expect(described_class.address_problem(address))
          .to eq('must not contain a password: ssh takes what it needs from its keys and its agent'), address
      end
      expect(described_class.address_problem('me:secret@example.test:r')).to eq(described_class::ACCEPTED)
    end

    # ssh reads a host or a user that starts with a hyphen as one of its
    # options, and -oProxyCommand runs a command.
    it 'refuses an ssh address with a user, a host or a path that ssh or git would read as an option' do
      ['ssh://-v/r', "ssh://git@example.test/r\n--x", "git@example.test:p\n", "ssh://example.test/r\n", "x\ngit@example.test:r",
       "x\nssh://example.test/r", 'ssh://git@example.test$(id)/r', 'git@example.test;id:r', 'u;id@example.test:r',
       'ssh://u$(id)@example.test/r', 'ssh://git@example.test`id`/r', 'git@example.test&x:r', "ssh://example.test/r'x",
       'ssh://example.test/r;x', 'ssh://example.test/r:x', 'ssh://example.test/r$x', 'ssh://example.test/r\\x', 'git@example.test:r;x',
       'git@example.test://x', 'git@https://example.test/r', 'u@file://x', 'ssh://-l@example.test:22/r', '-l@example.test:r', 'ssh://-oProxyCommand=x/r', 'ssh://git@-oProxyCommand=x/r', 'ssh://-l@example.test/r', '-oProxyCommand=x@example.test:r',
       'git@-oProxyCommand=x:r', 'git@example.test:-x', 'git@example.test:--upload-pack=x', 'git@example.test:',
       'ssh://git@example.test/%2Dx', 'ssh://a@b@example.test/r', 'git@example.test:r@x', 'git@example.test:r --x',
       "git@example.test:r\n--x", 'ssh://git@example.test/r?x', 'ssh://git@example.test:port/r', 'ssh://git@/r',
       "git@example.test:r\u202E", 'ssh://git@example.test/a b', 'ssh://[::1]/r'].each do |address|
        expect(described_class.address_problem(address)).to eq(described_class::ACCEPTED), address.inspect
      end
    end

    it 'refuses a query, a fragment, a space, a control character, an option of git and what is not text' do
      ['https://example.test/r?x=1', 'https://example.test/r#x', 'https://example.test/a b', "https://example.test/r\n--upload-pack=x",
       'https://example.test/r --upload-pack=x', 'https://example.test/%2e%2e', "https://example.test/r\u202E"].each do |address|
        expect(described_class.address_problem(address)).to eq(described_class::ACCEPTED), address.inspect
      end
      expect(described_class.address_problem(nil)).to eq('must be text')
      expect(described_class.address_problem("https://example.test/#{'a' * 2000}")).to eq('must be at most 2000 characters')
    end

    it 'refuses an ssh address when ssh is not among the protocols' do
      stub_const("#{described_class}::PROTOCOLS", %w[https].freeze)
      %w[git@example.test:team/r ssh://git@example.test/r ssh://example.test/r].each do |address|
        expect(described_class.address_problem(address)).not_to be_nil, address
      end
    end

    it 'says of every address that is not https that it must be one of the accepted forms' do
      %w[SSH://me@example.test/r http://me@example.test/r git://me:secret@example.test/r].each do |address|
        expect(described_class.address_problem(address)).to eq(described_class::ACCEPTED), address
      end
    end

    it 'refuses to be built with an address it would not use' do
      expect { described_class.new('git://example.test/r') }
        .to raise_error(described_class::Failure,
                        'the address of the repository must start with https:// or ssh://, or be written as user@host:path')
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
    it 'are only https and ssh: a file address is refused by git itself, even if the check of the address is skipped' do
      Dir.mktmpdir do |directory|
        repository = RecipeRepository.new(File.realpath(directory))
        repository.publish('shop', recipe_text)
        allow(described_class).to receive(:address_problem).and_return(nil)
        expect { described_class.new(repository.address).fetch('shop') }
          .to raise_error(described_class::Failure, /git could not read file:.*not allowed \(git may use only https and ssh here: check url\.\*\.insteadOf in your git configuration\)\z/)
      end
    end

    it 'gives an ssh address to git as it is written, after --, with ssh among the protocols' do
      done = instance_double(Process::Status, success?: true)
      failed = instance_double(Process::Status, success?: false)
      %w[git@example.test:team/recipes.git ssh://git@example.test:2222/team/recipes.git].each do |address|
        calls = []
        allow(Open3).to receive(:capture3) do |*arguments, **_options|
          calls << arguments
          arguments.include?('fetch') ? ['', "fatal: stopped here\n".b, failed] : ['', '', done]
        end
        expect { described_class.new(address).fetch('shop', '1.0.0') }.to raise_error(described_class::Failure, /stopped here/)
        fetching = calls.find { |arguments| arguments.include?('fetch') }
        expect(fetching.last(3)).to eq(['--', address, 'refs/tags/shop-1.0.0'])
        expect(fetching).to include('protocol.allow=never', 'protocol.https.allow=always', 'protocol.ssh.allow=always')
        expect(fetching.grep(/\Aprotocol\./).size).to eq(3)
        expect(fetching.first).to include('GIT_ALLOW_PROTOCOL' => 'https:ssh', 'GIT_TERMINAL_PROMPT' => '0')
        expect(fetching[1]).to eq('git')
      end
    end

    # Should the check of the address ever let one through: git refuses a host
    # that starts with a hyphen before it starts ssh.
    it 'do not let git start ssh with a host that is an option, even if the check of the address is skipped' do
      Dir.mktmpdir do |directory|
        marker = File.join(directory, 'ran')
        allow(described_class).to receive(:address_problem).and_return(nil)
        Dir.chdir(directory) do
          expect { described_class.new('ssh://-oProxyCommand=touch${IFS}ran/r').fetch('shop') }
            .to raise_error(described_class::Failure, /strange hostname '-oProxyCommand=touch\$\{IFS\}ran' blocked/)
        end
        expect(File.exist?(marker)).to eq(false)
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

    def failing_fetch(address, said)
      done = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3) do |_environment, _git, *arguments|
        arguments.include?('fetch') ? ['', said.b, failed] : ['', '', done]
      end
      described_class.new(address).fetch('shop')
    rescue described_class::Failure => e
      e.message
    end

    it 'comes with what to do when the repository asks for credentials that git does not have, or refuses them' do
      { "fatal: could not read Username for 'https://example.test': terminal prompts disabled\n" =>
          '(a private repository needs credentials that git already has for its host, such as a credential helper: ' \
          'without a terminal the command cannot ask for them)',
        "fatal: Authentication failed for 'https://example.test/r/'\n" =>
          '(the repository refused the user name or the password that git gave it)' }.each do |said, hint|
        expect(failing_fetch('https://example.test/r', said)).to eq("git could not read https://example.test/r: #{said.strip} #{hint}")
      end
    end

    it 'comes with what to do when ssh does not know the host, or has no key the host accepts, with the line where ssh says so' do
      { "Host key verification failed.\r\nfatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\n" =>
          'Host key verification failed. (ssh does not know this host: connect to it once with ssh, or add its key to known_hosts)',
        "git@example.test: Permission denied (publickey).\r\nfatal: Could not read from remote repository.\n" =>
          'git@example.test: Permission denied (publickey). (ssh has no key that this host accepts for the repository: ' \
          'check the key and the agent with ssh -T)' }.each do |said, shown|
        expect(failing_fetch('git@example.test:team/r', said)).to eq("git could not read git@example.test:team/r: #{shown}")
      end
    end

    # ssh ends both cases with "Host key verification failed": the advice to
    # trust the key must never answer its warning of a key that changed.
    it 'does not tell to trust a host whose key has changed' do
      said = "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\r\n" \
             "@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\r\n" \
             "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\r\n" \
             "IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!\r\n" \
             "Host key verification failed.\r\nfatal: Could not read from remote repository.\n"
      message = failing_fetch('git@example.test:team/r', said)
      expect(message).to eq('git could not read git@example.test:team/r: Host key verification failed. ' \
                            '(ssh says that the key of this host is not the one it knows: another machine may be ' \
                            'answering in its place. Find out why before you connect again)')
      expect(message).not_to include('known_hosts')
    end

    it 'chooses what to do from the lines of git and ssh, not from what a server writes' do
      { "remote: You are not allowed to download code from this project.\nfatal: Could not read from remote repository.\n" =>
          'remote: You are not allowed to download code from this project.',
        "ERROR: Repository not found. Host key verification failed. Permission denied (x)\nfatal: Could not read from remote repository.\n" =>
          'ERROR: Repository not found. Host key verification failed. Permission denied (x)',
        "remote: fatal: could not read Username for nobody: Authentication failed for nothing\nfatal: Could not read from remote repository.\n" =>
          'remote: fatal: could not read Username for nobody: Authentication failed for nothing' }.each do |said, shown|
        expect(failing_fetch('git@example.test:team/r', said)).to eq("git could not read git@example.test:team/r: #{shown}")
      end
      expect(failing_fetch('git@example.test:team/r', "fatal: Could not read from remote repository.\n"))
        .to eq('git could not read git@example.test:team/r: fatal: Could not read from remote repository.')
    end

    it 'must name a commit' do
      done = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).and_return(['not a commit', '', done])
      expect { described_class.new('https://example.test/r').fetch('shop') }
        .to raise_error(described_class::Failure, 'git did not say which commit of https://example.test/r it read')
    end
  end

  describe 'what git may ask' do
    def environments(**options)
      seen = []
      failed = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3) do |environment, *_arguments, **_options|
        seen << environment
        ['', "fatal: stopped here\n".b, failed]
      end
      expect { described_class.new('https://example.test/r', **options).fetch('shop') }.to raise_error(described_class::Failure)
      seen
    end

    it 'is nothing, unless it is told that someone can answer' do
      expect(environments).to all(include('GIT_TERMINAL_PROMPT' => '0'))
      expect(environments(ask: false)).to all(include('GIT_TERMINAL_PROMPT' => '0'))
    end

    it 'is the user name and the password, as git asks them, when someone can answer: the setting of the user stays' do
      expect(environments(ask: true)).not_to be_empty
      expect(environments(ask: true)).to all(satisfy { |environment| !environment.key?('GIT_TERMINAL_PROMPT') })
    end
  end

  it 'says when git is not installed' do
    allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)
    expect { described_class.new('https://example.test/r').fetch('shop') }
      .to raise_error(described_class::Failure, 'git was not found: install git, or install the recipe from a file')
  end
end
