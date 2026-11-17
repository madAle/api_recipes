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

  describe 'convert' do
    it 'never runs the ERB of the file, and has no option that does' do
      write('billing.yml', api.sub('billing.example.test', "<%= #{touch}; 'h.test' %>").sub('Accept: application/json', "Accept: application/json # <%# #{touch} %>"))
      expect(run_cli('convert', 'billing.yml').first).to eq(0)
      write('other.yml', "<% #{touch} %>\n#{api}")
      expect(run_cli('convert', 'other.yml').first).to eq(1)
      expect(run_cli('convert', '--erb', 'other.yml').first).to eq(2)
      expect(File.exist?(marker)).to be(false)
    end

    it 'never copies a credential into the recipe or onto the terminal: written in the file, or as the default of a tag' do
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
      secrets.each { |secret| expect(written + out + err).not_to include(secret) }
      expect(written).to include("X-Api-Key: \"{x_api_key}\"", 'access_token: "{access_token}"')
    end

    it 'does not copy one written on an endpoint either' do
      write('billing.yml', api.sub("    invoices:\n", "    invoices:\n      default_headers:\n        X-Secret: endpoint-secret\n"))
      code, out, err = run_cli('convert', 'billing.yml')
      expect(code).to eq(0)
      expect(File.read('billing.recipe.yml') + out + err).not_to include('endpoint-secret')
    end

    it 'gives no default to a credential, whatever else reads the same environment variable, before or after it' do
      [%w[X-Client X-Api-Key], %w[X-Api-Key X-Client]].each do |first, second|
        FileUtils.rm_f('billing.recipe.yml')
        tag = "<%= ENV.fetch('BILLING_KEY', 'default-of-a-tag') %>"
        write('billing.yml', api.sub('Accept: application/json', "#{first}: #{tag}\n    #{second}: #{tag}"))
        code, out, err = run_cli('convert', '--to', '.', 'billing.yml')
        expect(code).to eq(0)
        expect(File.read('billing.recipe.yml') + out + err).not_to include('default-of-a-tag')
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

    it 'deletes nothing that git could not bring back: a file with changes that are not committed stops it' do
      project
      File.write('config/apis/billing.yml', "#{erb_api}# not committed\n")
      before = snapshot
      expect(run_cli('convert', 'config/apis/billing.yml').first).to eq(1)
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
