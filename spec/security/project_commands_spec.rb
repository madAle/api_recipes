require 'spec_helper'
require 'api_recipes/cli'
require 'tmpdir'
require 'fileutils'
require 'open3'

# What the files of a project can do to the commands that read them without
# being told which ones: `api_recipes upgrade` with no argument, and
# `api_recipes convert`, whose result is meant for a shared repository.
describe 'The commands that read the files of a project' do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = File.realpath(dir)
      Dir.chdir(@root) { example.run }
    end
  end

  let(:marker) { File.join(@root, 'MARKER') }
  let(:touch) { "File.write(#{marker.inspect}, 'run')" }
  let(:api) do
    <<~YAML
      billing:
        host: billing.example.test
        default_headers:
          Accept: application/json
        endpoints:
          invoices:
    YAML
  end

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    path
  end

  describe 'upgrade with no argument' do
    before { write('Gemfile', "gem 'api_recipes'\n") }

    it 'never runs the ERB of a file it found by itself: output tags, other tags, comments' do
      write('config/apis/billing.yml', api.sub('billing.example.test', "<%= #{touch}; 'h.test' %>"))
      write('config/apis/other.yml.erb', "<% #{touch} %>\n<%# #{touch} %>\n#{api.sub('billing:', 'other:')}")
      code, out, err = run_cli('upgrade')
      expect(File.exist?(marker)).to be(false)
      expect(code).to eq(1)
      expect(out).to include('config/apis/billing.yml: 1 value comes from ERB and was not checked',
                             'config/apis/other.yml.erb: [config] contains ERB that decides the structure of the file')
      expect(err).to eq('')
    end

    it 'runs it only with --erb' do
      write('config/apis/billing.yml', api.sub('billing.example.test', "<%= #{touch}; 'h.test' %>"))
      run_cli('upgrade', '--erb')
      expect(File.exist?(marker)).to be(true)
    end

    it 'does not read a file through a symbolic link, with or without --erb' do
      outside = Dir.mktmpdir
      File.write(File.join(outside, 'secret.yml'), api.sub('billing.example.test', "<%= #{touch} %>").sub('host:', 'hots:'))
      File.write(File.join(outside, 'code.rb'), "ApiRecipes.print_urls = true\n")
      FileUtils.mkdir_p(%w[config app])
      File.symlink(File.join(outside, 'secret.yml'), 'config/linked.yml')
      File.symlink(File.join(outside, 'code.rb'), 'app/linked.rb')
      _, out, = run_cli('upgrade', '--erb')
      expect(File.exist?(marker)).to be(false)
      expect(out).not_to include('[config]', '[breaks]')
    ensure
      FileUtils.remove_entry(outside) if outside
    end

    it 'does not send the name of a file to the terminal as it is written' do
      write("config/apis/\e[2Jbilling.yml", api.sub('host:', 'hots:'))
      _, out, err = run_cli('upgrade')
      expect(out).to include('[config]')
      expect(out + err).not_to include("\e")
    end

    it 'writes on a terminal only its own colours: the name of a file adds nothing that the terminal obeys' do
      write("config/apis/\e[2Jbilling\e[5m.yml", api.sub('host:', 'hots:'))
      write("app/\e]0;title\aclient.rb", "ApiRecipes.print_urls = true\n")
      terminal = StringIO.new
      terminal.define_singleton_method(:tty?) { true }
      ApiRecipes::CLI.run(['upgrade'], out: terminal, err: terminal)
      own = %w[0 1 2 31 32 33 35 36 1;31 1;32 1;33 1;35].map { |code| "\e[#{code}m" }
      expect(terminal.string).to include('breaks', 'config', "\e[1;31m")
      expect(terminal.string.scan(/\e\[[0-9;]*m/).uniq - own).to eq([])
      expect(terminal.string.gsub(/\e\[[0-9;]*m/, '')).not_to match(/[\e\a]/)
    end

    it 'does not leave the project through a symbolic link' do
      outside = Dir.mktmpdir
      File.write(File.join(outside, 'billing.yml'), api.sub('billing.example.test', "<%= #{touch} %>").sub('host:', 'hots:'))
      File.symlink(outside, 'config')
      _, out, = run_cli('upgrade')
      expect(out).to include('No configuration file was found')
      expect(out).not_to include('[config]')
    ensure
      FileUtils.remove_entry(outside) if outside
    end
  end

  # On a terminal `upgrade` offers to make the changes it is sure of.
  describe 'upgrade, when it offers to change the project' do
    let(:initializer) { "ApiRecipes.configure do |config|\n  config.log_level = :info\nend\n" }

    def git(*arguments)
      out, status = Open3.capture2e('git', '-c', 'user.name=spec', '-c', 'user.email=spec@example.test', *arguments)
      raise out unless status.success?

      out
    end

    def project(startup = "ApiRecipes.print_urls = true\n")
      write('Gemfile', "gem 'api_recipes'\n")
      write('config/initializers/api_recipes.rb', initializer)
      write('config/initializers/startup.rb', startup)
      git('init', '-q', '.')
      git('add', '-A')
      git('commit', '-q', '-m', 'start')
    end

    # The answers are typed on a terminal, where the results are shown; nil
    # for an input that is not one. typed: what happens as each answer is
    # typed.
    def upgrade(answers, *arguments, typed: nil)
      out = StringIO.new
      input = StringIO.new(answers.to_s)
      if answers
        [input, out].each { |io| io.define_singleton_method(:tty?) { true } }
        input.define_singleton_method(:gets) { typed&.call || super() } if typed
      end
      saved = ENV.fetch('NO_COLOR', nil)
      ENV['NO_COLOR'] = '1'
      ApiRecipes::CLI.run(['upgrade', *arguments], out: out, err: out, input: input)
      out.string
    ensure
      saved ? ENV['NO_COLOR'] = saved : ENV.delete('NO_COLOR')
    end

    def snapshot = Dir.glob('**/*').to_h { |f| [f, File.file?(f) ? File.read(f) : nil] }

    it 'changes a file only after a yes typed on a terminal: never away from one, whatever the input says' do
      project
      before = snapshot
      expect(upgrade(nil)).not_to include('Make this change?')
      out = StringIO.new
      ApiRecipes::CLI.run(['upgrade'], out: out, err: out, input: StringIO.new("y\nyes\n"))
      expect(out.string).not_to include('Make this change?')
      # Typed on a terminal, but the results go to a file, where nobody reads the question.
      typed = StringIO.new("y\nyes\n")
      typed.define_singleton_method(:tty?) { true }
      out = StringIO.new
      ApiRecipes::CLI.run(['upgrade'], out: out, err: out, input: typed)
      expect(out.string).not_to include('Make this change?')
      expect(upgrade("n\n")).to include('Make this change?')
      expect(snapshot).to eq(before)
      upgrade("y\n")
      expect(File.read('config/initializers/api_recipes.rb')).to include('config.print_urls = true')
    end

    it 'does not ask, and shows no code, with --no-code' do
      project("ApiRecipes.billing.authorization = 'written-secret'\n")
      before = snapshot
      out = upgrade("y\n", '--no-code')
      expect(out).not_to include('Make this change?', 'written-secret')
      expect(snapshot).to eq(before)
    end

    it 'moves an api to a recipe under the same rules: only after a yes on a terminal, and never with --no-code' do
      project
      write('config/apis/billing.yml', api)
      write('config/initializers/api_recipes.rb', "ApiRecipes.configure do |config|\n  config.apis_files_paths = ['config/apis/billing.yml']\nend\n")
      git('add', '-A')
      git('commit', '-q', '-m', 'old')
      before = snapshot
      [upgrade(nil), upgrade("y\n", '--no-code')].each { |out| expect(out).not_to include('Make this change?') }
      out = StringIO.new
      ApiRecipes::CLI.run(['upgrade'], out: out, err: out, input: StringIO.new("y\ny\ny\n"))
      expect(out.string).not_to include('Make this change?')
      expect(upgrade("n\nn\n")).to include('Move the api billing to a portable recipe', 'Make this change?',
                                           'config/api_recipes/billing.recipe.yml (new file)', 'config/api_recipes/recipes.lock (new file)',
                                           'config/apis/billing.yml (deleted)')
      expect(snapshot).to eq(before)
      upgrade("y\nn\n")
      expect(File.exist?('config/api_recipes/billing.recipe.yml')).to be(true)
      expect(File.exist?('config/apis/billing.yml')).to be(false)
    end

    it 'changes only a file that git has committed as it is now: not one with changes, one git does not know, or outside git' do
      project
      File.write('config/initializers/startup.rb', "ApiRecipes.print_urls = true\n# a note that is not committed\n")
      before = snapshot
      expect(upgrade("y\n")).to match(/does not make the change: config\/initializers\/startup\.rb is not a file that git has committed/)
      expect(snapshot).to eq(before)

      git('checkout', '--', '.')
      write('config/initializers/new.rb', "ApiRecipes.billing.authorization = 'x'\n")
      before = snapshot
      expect(upgrade("n\ny\n")).to match(/does not make the change: config\/initializers\/new\.rb is not a file/)
      expect(snapshot).to eq(before)

      git('add', '-N', 'config/initializers/new.rb')
      expect(upgrade("n\ny\n")).to match(/does not make the change: config\/initializers\/new\.rb is not a file/)
      expect(snapshot).to eq(before)

      FileUtils.rm_f('config/initializers/new.rb')
      git('add', '-A')
      git('update-index', '--assume-unchanged', 'config/initializers/startup.rb')
      before = snapshot
      expect(upgrade("y\n")).to match(/does not make the change: config\/initializers\/startup\.rb is not a file/)
      expect(snapshot).to eq(before)

      FileUtils.rm_rf('.git')
      expect(upgrade("y\ny\n")).to match(/does not make the change/)
      expect(snapshot).to eq(before)
    end

    it 'changes nothing through a symbolic link' do
      project
      FileUtils.mv('config/initializers/api_recipes.rb', 'real.rb')
      File.symlink(File.join(@root, 'real.rb'), 'config/initializers/api_recipes.rb')
      git('add', '-A')
      git('commit', '-q', '-m', 'link')
      before = snapshot
      expect(upgrade("y\n", 'config/initializers')).to match(/does not make the change: config\/initializers\/api_recipes\.rb is not a file/)
      expect(snapshot).to eq(before)
    end

    it 'does not run a program that the repository names for git' do
      project
      File.write('hook.sh', "#!/bin/sh\ntouch #{marker}\n")
      File.chmod(0o755, 'hook.sh')
      git('config', 'core.fsmonitor', File.join(@root, 'hook.sh'))
      git('add', '-A')
      git('commit', '-q', '-m', 'hook')
      FileUtils.rm_f(marker)
      upgrade("y\n")
      expect(File.read('config/initializers/api_recipes.rb')).to include('config.print_urls = true')
      expect(File.exist?(marker)).to be(false)
    end

    it 'does not run a filter that git is configured with to compare a file, as status would' do
      project
      File.write('.gitattributes', "*.rb filter=spy\n")
      git('config', 'filter.spy.clean', "sh -c 'touch #{marker}; cat'")
      git('add', '-A')
      git('commit', '-q', '-m', 'filter')
      FileUtils.rm_f(marker)
      FileUtils.touch('config/initializers/startup.rb', mtime: Time.now + 5)
      upgrade("y\n")
      expect(File.read('config/initializers/api_recipes.rb')).to include('config.print_urls = true')
      expect(File.exist?(marker)).to be(false)
    end

    it 'shows in the diff nothing that the terminal obeys, though the file holds it' do
      project("# \e[2J\e]0;title\a a note\nApiRecipes.print_urls = true\n")
      out = upgrade("n\n")
      expect(out).to include('- ApiRecipes.print_urls = true', '# ?[2J?]0;title? a note')
      expect(out).not_to match(/[\e\a]/)
    end

    it 'puts every file back when one cannot be written' do
      project
      before = snapshot
      real = File.method(:write)
      # The disk fills up after the file was opened, and emptied.
      allow(File).to receive(:write) do |path, *rest|
        if path.end_with?('api_recipes.rb') && rest.first.include?('print_urls')
          real.call(path, '')
          raise Errno::ENOSPC
        end

        real.call(path, *rest)
      end
      expect(upgrade("y\n")).to include('could not be written (ENOSPC): every file was put back as it was')
      expect(snapshot).to eq(before)
    end

    it 'writes no recipe outside the project, through a folder above the recipes that is a symbolic link' do
      outside = Dir.mktmpdir
      write('Gemfile', "gem 'api_recipes'\n")
      write('apis/billing.yml', api)
      write('lib/setup.rb', "ApiRecipes.configure do |config|\n  config.apis_files_paths = Dir[File.expand_path('../apis/*.yml', __dir__)]\nend\n")
      File.symlink(outside, 'config')
      git('init', '-q', '.')
      git('add', '-A')
      git('commit', '-q', '-m', 'start')
      code, _, err = run_cli('convert')
      expect(code).to eq(1)
      expect(err).to include('config/api_recipes is a symbolic link, or is below one')
      expect(Dir.children(outside)).to eq([])
      expect(git('status', '--porcelain')).to eq('')
    ensure
      FileUtils.remove_entry(outside) if outside
    end

    it 'writes nothing when a file changed while the question waited: what was saved meanwhile stays' do
      project
      saved = lambda do
        File.write('config/initializers/startup.rb', "ApiRecipes.print_urls = true
SAVED_MEANWHILE = 1
")
        "y\n"
      end
      before = snapshot.merge('config/initializers/startup.rb' => "ApiRecipes.print_urls = true\nSAVED_MEANWHILE = 1\n")
      out = upgrade("y\n", typed: saved)
      expect(out).to include('config/initializers/startup.rb changed while the question waited: nothing was written')
      expect(snapshot).to eq(before)
    end

    it 'does not write over a recipe that appeared while the question waited' do
      project
      write('config/apis/billing.yml', api)
      write('config/initializers/api_recipes.rb', "ApiRecipes.configure do |config|\n  config.apis_files_paths = ['config/apis/billing.yml']\nend\n")
      git('add', '-A')
      git('commit', '-q', '-m', 'old')
      done = false
      saved = lambda do
        write('config/api_recipes/billing.recipe.yml', "# written meanwhile\n") unless done
        done = true
        nil
      end
      out = upgrade("y\nn\n", typed: saved)
      expect(out).to include('config/api_recipes/billing.recipe.yml changed after this command read it')
      expect(File.read('config/api_recipes/billing.recipe.yml')).to eq("# written meanwhile\n")
      expect(File.exist?('config/apis/billing.yml')).to be(true)
    end

    it 'does not move an api to a recipe when its files changed while the question waited' do
      project
      write('config/apis/billing.yml', api)
      write('config/initializers/api_recipes.rb', "ApiRecipes.configure do |config|\n  config.apis_files_paths = ['config/apis/billing.yml']\nend\n")
      git('add', '-A')
      git('commit', '-q', '-m', 'old')
      done = false
      saved = lambda do
        File.write('config/apis/billing.yml', "#{api}    reports:\n") unless done
        done = true
        nil
      end
      before = snapshot.merge('config/apis/billing.yml' => "#{api}    reports:\n")
      out = upgrade("y\nn\n", typed: saved)
      expect(out).to include('config/apis/billing.yml changed after this command read it')
      expect(snapshot).to eq(before)
    end

    it 'takes out only a line that is one whole statement: what shares a line with other code is left to the person' do
      project("prepare; ApiRecipes.print_urls = true\nApiRecipes.billing.authorization = [\n  'x'\n].first\n")
      before = snapshot
      out = upgrade("y\ny\n")
      expect(out).not_to include('Make this change?')
      expect(out).to include('Code to paste')
      expect(snapshot).to eq(before)
    end
  end

  it 'routes never runs the ERB of a file, found or given, without --erb' do
    write('Gemfile', "gem 'api_recipes'\n")
    write('config/apis/billing.yml', api.sub('billing.example.test', "<%= #{touch}; 'h.test' %>"))
    write('config/apis/other.yml.erb', "<% #{touch} %>\n<%# #{touch} %>\n#{api.sub('billing:', 'other:')}")
    code, out, = run_cli('routes')
    expect(File.exist?(marker)).to be(false)
    expect([code, out]).to eq([1, "billing.invoices  GET  https://{erb}/invoices\n"])
    expect(run_cli('routes', 'config/apis/billing.yml').first).to eq(0)
    expect(File.exist?(marker)).to be(false)
    run_cli('routes', '--erb', 'config/apis/billing.yml')
    expect(File.exist?(marker)).to be(true)
  end

  describe 'convert' do
    it 'never runs the ERB of the file, and has no option that does' do
      write('billing.yml', api.sub('billing.example.test', "<%= #{touch}; 'h.test' %>").sub('Accept: application/json', "Accept: application/json # <%# #{touch} %>"))
      expect(run_cli('convert', 'billing.yml').first).to eq(0)
      write('other.yml', "<% #{touch} %>\n#{api}")
      expect(run_cli('convert', 'other.yml').first).to eq(1)
      expect(run_cli('convert', '--erb', 'other.yml').first).to eq(2)
      expect(File.exist?(marker)).to be(false)
    end

    it 'never copies a credential into the recipe, or among the changes it lists: written in the file, or as the default of a tag' do
      secrets = %w[written-header-secret written-param-secret default-of-a-tag bearer-secret]
      write('billing.yml', api.sub("    Accept: application/json\n", <<~YAML.gsub(/^/, '    ')))
        Accept: application/json
        X-Api-Key: written-header-secret
        Authorization: Bearer bearer-secret
        X-Auth-Token: "<%= ENV.fetch('TOKEN', 'default-of-a-tag') %>"
      YAML
      File.write('billing.yml', File.read('billing.yml').sub("  endpoints:\n", "  default_params:\n    access_token: written-param-secret\n  endpoints:\n"))
      code, out, err = run_cli('convert', 'billing.yml')
      expect(code).to eq(0)
      written = File.read('billing.recipe.yml')
      listed = out[/What changed.*?(?=\n\nIn the file)/m]
      secrets.each { |secret| expect(written + listed + err).not_to include(secret) }
      expect(written).to include("X-Api-Key: \"{x_api_key}\"", 'access_token: "{access_token}"')
    end

    it 'does not copy one written on an endpoint either' do
      write('billing.yml', api.sub("    invoices:\n", "    invoices:\n      default_headers:\n        X-Secret: endpoint-secret\n"))
      code, out, err = run_cli('convert', 'billing.yml')
      expect(code).to eq(0)
      expect(File.read('billing.recipe.yml') + err).not_to include('endpoint-secret')
    end

    it 'gives no default to a credential, whatever else reads the same environment variable, before or after it' do
      [%w[X-Client X-Api-Key], %w[X-Api-Key X-Client]].each do |first, second|
        FileUtils.rm_f('billing.recipe.yml')
        tag = "<%= ENV.fetch('BILLING_KEY', 'default-of-a-tag') %>"
        write('billing.yml', api.sub('Accept: application/json', "#{first}: #{tag}\n    #{second}: #{tag}"))
        code, out, err = run_cli('convert', '--to', '.', 'billing.yml')
        expect(code).to eq(0)
        expect(File.read('billing.recipe.yml') + err).not_to include('default-of-a-tag')
      end
    end

    it 'keeps a credential that the file already gives with a variable, and hides nothing new behind another name' do
      write('billing.yml', api.sub("  default_headers:\n", "  variables:\n    token: {}\n  default_headers:\n    Authorization: Bearer {token}\n"))
      expect(run_cli('convert', '--to', '.', 'billing.yml').first).to eq(0)
      expect(File.read('billing.recipe.yml')).to include('Authorization: Bearer {token}')
    end

    it 'never shows the value of a header or of a parameter, not even one too long for a recipe' do
      write('billing.yml', api.sub('Accept: application/json', "X-Client: client-secret-#{'x' * 2100}"))
      code, out, err = run_cli('convert', '--to', '.', 'billing.yml')
      expect(code).to eq(1)
      expect(out + err).not_to include('client-secret')
      expect(err).to include('default_headers.X-Client: is longer than the 2000 characters')
    end

    it 'refuses by its name a value that is not visible text, and gives no default to what the environment names like a credential' do
      write('billing.yml', api.sub('Accept: application/json', 'X-Trace: "SEKRET-VALUE\\x07bell"'))
      code, out, err = run_cli('convert', '--to', '.', 'billing.yml')
      expect(code).to eq(1)
      expect(out + err).not_to include('SEKRET')
      expect(err).to include('default_headers.X-Trace: holds a character that is not printed')
      write('billing.yml', api.sub('Accept: application/json', "X-Client: <%= ENV['CLIENT_SECRET'] || 'default-of-a-tag' %>"))
      expect(run_cli('convert', '--to', '.', 'billing.yml').first).to eq(0)
      expect(File.read('billing.recipe.yml')).not_to include('default-of-a-tag')
    end

    it 'does not send a name of the file to the terminal when it refuses it either' do
      write('billing.yml', api.sub("    invoices:\n", "    \"\\e[2J\\u202Eowned\": \"<%= x %>\"\n"))
      code, out, err = run_cli('convert', '--to', '.', 'billing.yml')
      expect(code).to eq(1)
      expect(out + err).not_to match(/\e|\u202E/)
    end

    it 'answers with one line, never with a backtrace, to a file it did not foresee' do
      inputs = ["a: foo\nb: bar\n", "a: [1, 2]\nb: {}\n", "billing:\n  host: <%= ENV['H'] %>\n  variables: [a]\n",
                "billing:\n  host: \"__API_RECIPES_ERB_\\x30__\"\n  endpoints:\n    a:\n", "x: #{'[' * 20_000}#{']' * 20_000}\n"]
      inputs.each_with_index do |text, index|
        write("in#{index}.yml", text)
        code, out, err = run_cli('convert', '--to', '.', '--name', text[/\A\w+/], "in#{index}.yml")
        expect([code, out]).to eq([1, '']).or eq([0, out])
        expect(err.lines.size).to be <= 3
        expect(err).not_to match(/NoMethodError|TypeError|convert\.rb|defect/)
      end
    end

    it 'is not kept busy by a few lines: a long tag, or aliases that stand for millions of values' do
      write('tag.yml', api.sub('billing.example.test', "<%= ENV[\"A\", #{' ' * 6000}x %>"))
      bomb = "a: &a [x, x, x, x, x, x, x, x, x, x]\n" + ('b'..'h').each_cons(2).map { |one, two| "#{two}: &#{two} [#{(['*' + (one == 'b' ? 'a' : one)] * 10).join(', ')}]\n" }.join
      write('bomb.yml', "#{bomb}billing:\n  host: h.test\n  x-all: *h\n  endpoints:\n    a:\n")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(run_cli('convert', '--to', '.', 'tag.yml').first).to eq(0)
      code, _, err = run_cli('convert', '--to', '.', '--name', 'billing', 'bomb.yml')
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 10
      expect(code).to eq(1)
      expect(err).to include('describes more values than a recipe can hold')
    end

    it 'creates the recipe and never writes over a file, not even through a symbolic link' do
      write('billing.yml', api)
      write('precious.txt', 'precious')
      File.symlink(File.join(@root, 'precious.txt'), 'billing.recipe.yml')
      code, _, err = run_cli('convert', 'billing.yml')
      expect(code).to eq(2)
      expect(err).to include('already exists')
      expect(File.read('precious.txt')).to eq('precious')
    end

    it 'writes only what passes as a portable recipe: a file that would not is refused and nothing is written' do
      write('billing.yml', api.sub('Accept: application/json', "Accept: \"application/json\\u202E\""))
      code, out, = run_cli('convert', 'billing.yml')
      expect(code).to eq(1)
      expect(out).to eq('')
      expect(Dir['*.recipe.yml']).to eq([])
    end

    it 'does not send a name of the file to the terminal as it is written' do
      write('apis.yml', "#{api}\"other\\e[2J\\u202E\":\n  host: h.test\n")
      code, out, err = run_cli('convert', 'apis.yml')
      expect(code).to eq(2)
      expect(err).to include('describes 2 apis (billing, other')
      expect(out + err).not_to match(/\e|\u202E/)
    end
  end

  describe 'convert in the root of a project, which changes its files' do
    let(:erb_api) { api.sub('billing.example.test', "<%= #{touch}; ENV['H'] || 'billing.example.test' %>").sub('Accept: application/json', "Accept: application/json\n    X-Api-Key: written-secret") }
    let(:initializer) { "ApiRecipes.configure do |config|\n  config.apis_files_paths = ['config/apis/billing.yml']\nend\n" }

    def git(*arguments)
      out, status = Open3.capture2e('git', '-c', 'user.name=spec', '-c', 'user.email=spec@example.test', *arguments)
      raise out unless status.success?
    end

    def project
      write('Gemfile', "gem 'api_recipes'\n")
      write('config/apis/billing.yml', erb_api)
      write('config/initializers/api_recipes.rb', initializer)
      git('init', '-q', '.')
      git('add', '-A')
      git('commit', '-q', '-m', 'start')
    end

    def snapshot = Dir.glob('**/*').to_h { |f| [f, File.file?(f) ? File.read(f) : nil] }

    it 'moves the code of a tag without running it, and never shows it or a value of the file' do
      project
      code, out, err = run_cli('convert', 'config/apis/billing.yml')
      expect(code).to eq(0)
      expect(File.exist?(marker)).to be(false)
      expect(out + err + File.read('config/api_recipes/billing.recipe.yml')).not_to match(/written-secret|MARKER|File\.write/)
      expect(File.read('config/initializers/api_recipes.rb')).to include('x_api_key: "written-secret"', 'File.write')
    end

    it 'gives the code to paste whole, so that it works, and leaves out only what a terminal would obey' do
      write('Gemfile', "gem 'api_recipes'\n")
      write('config/initializers/api_recipes.rb', initializer)
      write('config/apis/billing.yml', api.sub('billing.example.test', "<%= ENV['H'] || 'host.example.test' %>").sub('Accept: application/json', <<~YAML.gsub(/^/, '    ').strip))
        X-Api-Key: written-value
        X-Signature: <%= ENV.fetch('SIG', 'default-value') %>
        X-Trace: "<%= ENV['T'] + '\u202E' %>"
        X-Token: "written\\e[2Jvalue"
      YAML
      _, out, err = run_cli('convert', 'config/apis/billing.yml')
      expect(out).to include("h: (ENV['H'] || 'host.example.test'),", 'x_api_key: "written-value",', "sig: (ENV.fetch('SIG', 'default-value')),",
                             'x_trace: nil, # paste here the code of the tag for default_headers.X-Trace, at line 6 of config/apis/billing.yml',
                             'x_token: "written\\e[2Jvalue"')
      expect(out + err).not_to match(/\e|\u202E/)
      expect(Dir['config/api_recipes/*']).to eq([])
    end

    it 'deletes nothing that git could not bring back: a file with changes that are not committed stops it' do
      project
      File.write('config/apis/billing.yml', "#{erb_api}# not committed\n")
      before = snapshot
      expect(run_cli('convert', 'config/apis/billing.yml').first).to eq(1)
      expect(snapshot).to eq(before)
    end

    it 'changes nothing through a symbolic link, and nothing that git was told to look away from' do
      project
      outside = Dir.mktmpdir
      File.write(File.join(outside, 'apis.yml'), "#{erb_api.sub('billing:', 'linked:')}other:\n  host: o.test\n  endpoints:\n    a:\n")
      File.symlink(File.join(outside, 'apis.yml'), 'config/apis/linked.yml')
      git('add', '-A')
      git('commit', '-q', '-m', 'link')
      code, _, err = run_cli('convert', '--name', 'linked', 'config/apis/linked.yml')
      expect(code).to eq(1)
      expect(err).to include('config/apis/linked.yml is a symbolic link')
      expect(File.read(File.join(outside, 'apis.yml'))).to include('linked:')
      git('update-index', '--skip-worktree', 'config/apis/billing.yml')
      File.write('config/apis/billing.yml', "#{erb_api}# a local change\n")
      before = snapshot
      expect(run_cli('convert', 'config/apis/billing.yml').first).to eq(1)
      expect(snapshot).to eq(before)
    ensure
      FileUtils.remove_entry(outside) if outside
    end

    it 'does not run a program that the repository names for git' do
      project
      File.write('hook.sh', "#!/bin/sh\ntouch #{marker}\n")
      File.chmod(0o755, 'hook.sh')
      git('config', 'core.fsmonitor', File.join(@root, 'hook.sh'))
      git('add', '-A')
      git('commit', '-q', '-m', 'hook')
      FileUtils.rm_f(marker)
      run_cli('convert', 'config/apis/billing.yml')
      expect(File.exist?(marker)).to be(false)
    end

    it 'does not run a filter that git is configured with to compare a file, as status would' do
      project
      ran = File.join(@root, 'FILTER_RAN')
      File.write('.gitattributes', "*.rb filter=spy\n*.yml filter=spy\n")
      git('config', 'filter.spy.clean', "sh -c 'touch #{ran}; cat'")
      git('add', '-A')
      git('commit', '-q', '-m', 'filter')
      FileUtils.rm_f(ran)
      FileUtils.touch(%w[config/apis/billing.yml config/initializers/api_recipes.rb], mtime: Time.now + 5)
      expect(run_cli('convert', 'config/apis/billing.yml').first).to eq(0)
      expect(File.exist?(ran)).to be(false)
    end

    it 'takes nothing out of a file with changes that are not committed, also after it added lines to it in the same run' do
      project
      write('config/apis/other.yml', "other:\n  host: other.example.test\n  endpoints:\n    ping:\n")
      write('config/initializers/api_recipes.rb', "ApiRecipes.configure do |config|\n  config.apis_files_paths = Dir['config/apis/*.yml']\nend\n")
      git('add', '-A')
      git('commit', '-q', '-m', 'two')
      File.write('config/initializers/api_recipes.rb', File.read('config/initializers/api_recipes.rb').sub("end\n", "  config.log_level = :debug # not committed\nend\n"))
      _, out, = run_cli('convert')
      expect(out).to include('loads no file now: you can take it out')
      expect(File.read('config/initializers/api_recipes.rb')).to include("config.apis_files_paths = Dir['config/apis/*.yml']", '# not committed')
    end

    it 'puts the project back as it was when a write fails after others were made' do
      project
      before = snapshot
      allow(File).to receive(:delete).and_wrap_original { |original, path| path.end_with?('billing.yml') ? raise(Errno::EACCES) : original.call(path) }
      expect(run_cli('convert', 'config/apis/billing.yml').first).to eq(2)
      expect(snapshot).to eq(before)
    end

    it 'edits nothing that git does not know, and nothing at all outside git' do
      project
      git('rm', '-q', '--cached', 'config/initializers/api_recipes.rb')
      git('commit', '-q', '-m', 'untrack')
      before = snapshot
      expect(run_cli('convert', 'config/apis/billing.yml').first).to eq(1)
      FileUtils.remove_entry('.git')
      expect(run_cli('convert', 'config/apis/billing.yml').first).to eq(1)
      expect(snapshot).to eq(before)
    end

    it 'writes the file that calls configure only when the result is valid Ruby' do
      project
      File.write('config/apis/billing.yml', erb_api.sub("|| 'billing.example.test'", "|| 'billing.example.test' # note"))
      git('commit', '-q', '-am', 'comment')
      before = snapshot
      code, _, err = run_cli('convert', 'config/apis/billing.yml')
      expect(code).to eq(1)
      expect(err).to include('would not be valid Ruby')
      expect(snapshot).to eq(before)
    end

    it 'changes nothing when a single step is not possible: no recipe without the values, no values without the recipe' do
      project
      write('config/api_recipes/billing.recipe.yml', 'already here')
      git('add', '-A')
      git('commit', '-q', '-m', 'recipe')
      before = snapshot
      expect(run_cli('convert', 'config/apis/billing.yml').first).to eq(1)
      expect(snapshot).to eq(before)
    end
  end
end
