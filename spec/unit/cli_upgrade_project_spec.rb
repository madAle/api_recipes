require 'spec_helper'
require 'api_recipes/cli'
require 'stringio'
require 'tmpdir'
require 'fileutils'

# `api_recipes upgrade` with no argument: the command finds by itself the Ruby
# files and the configuration files of the project in the current directory.
describe 'api_recipes upgrade, in a project' do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = File.realpath(dir)
      Dir.chdir(@dir) { example.run }
    end
  end

  let(:billing) do
    <<~YAML
      billing:
        host: billing.example.test
        endpoints:
          invoices:
    YAML
  end

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    path
  end

  def project(files = {})
    write('Gemfile', "source 'https://rubygems.org'\ngem 'api_recipes'\n")
    files.each { |path, text| write(path, text) }
  end

  def run(*argv)
    out = StringIO.new
    err = StringIO.new
    [ApiRecipes::CLI.run(argv, out: out, err: err), out.string, err.string]
  end

  it 'finds the Ruby files and the configuration files without being told where they are' do
    project('app/models/client.rb' => "ApiRecipes.print_urls = true\n",
            'lib/tasks/sync.rake' => "ApiRecipes.print_urls = true\n",
            'config/apis/billing.yml' => billing.sub('host:', 'hots:'),
            'config/database.yml' => "production:\n  host: db.example.test\n")
    code, out, err = run('upgrade')
    expect(code).to eq(1)
    expect(err).to eq('')
    expect(out).to include('app/models/client.rb:1: [breaks] use config.print_urls',
                           'lib/tasks/sync.rake:1: [breaks] use config.print_urls',
                           "config/apis/billing.yml: [config] billing: unknown option 'hots'")
    expect(out).not_to include('database.yml')
    expect(out).to include('Checked 2 Ruby files', 'Checked 1 configuration file: config/apis/billing.yml')
    expect(out).to match(/^3 findings$/)
  end

  it 'leaves out what is not the code of the project' do
    removed = "ApiRecipes.print_urls = true\n"
    project('app/a.rb' => "x = 1\n", 'vendor/bundle/gems/x/lib/x.rb' => removed, 'node_modules/y/y.rb' => removed,
            'tmp/cache/z.rb' => removed, 'log/l.rb' => removed, 'coverage/c.rb' => removed,
            '.hidden/h.rb' => removed, 'public/p.rb' => removed, 'storage/s.rb' => removed,
            'vendor/apis/billing.yml' => billing.sub('host:', 'hots:'))
    code, out, = run('upgrade')
    expect(code).to eq(0)
    expect(out).to include('Checked 1 Ruby file')
    expect(out).not_to include('[breaks]', '[config]')
  end

  it 'does not follow a directory that is a symbolic link' do
    project('app/a.rb' => "x = 1\n")
    outside = Dir.mktmpdir
    File.write(File.join(outside, 'o.rb'), "ApiRecipes.print_urls = true\n")
    File.symlink(outside, 'linked')
    File.symlink(@dir, 'app/loop')
    code, out, = run('upgrade')
    expect(code).to eq(0)
    expect(out).to include('Checked 1 Ruby file')
  ensure
    FileUtils.remove_entry(outside) if outside
  end

  it 'stops where there is no Gemfile, and says what to do' do
    write('app/a.rb', "ApiRecipes.print_urls = true\n")
    code, out, err = run('upgrade')
    expect(code).to eq(2)
    expect(out).to eq('')
    expect(err).to include('there is no Gemfile here', 'name the directories and the files to check')
  end

  it 'says that it found no configuration file instead of "Nothing to change"' do
    project('app/a.rb' => "x = 1\n")
    code, out, = run('upgrade')
    expect(code).to eq(0)
    expect(out).to include('No configuration file was found')
    expect(out).not_to match(/^Nothing to change$/)
  end

  it 'says "Nothing to change" when it checked code and configuration and found nothing' do
    project('app/a.rb' => "x = 1\n", 'config/apis/billing.yml' => billing)
    code, out, = run('upgrade')
    expect(code).to eq(0)
    expect(out).to match(/^Nothing to change$/)
  end

  describe 'the checks that also match code that has nothing to do with the gem' do
    let(:rescued) { "begin\n  work\nrescue\n  nil\nend\n" }

    it 'are applied only to the files that use the gem' do
      project('app/unrelated.rb' => rescued + "CGI.escape(x)\n",
              'app/with_constant.rb' => "ApiRecipes.github\n" + rescued,
              'config/apis/billing.yml' => billing)
      code, out, = run('upgrade')
      expect(code).to eq(1)
      expect(out).to include('app/with_constant.rb:4: [check] a bare rescue')
      expect(out).not_to include('app/unrelated.rb')
      expect(out).to include('Checked 2 Ruby files, 1 of them uses api_recipes')
    end

    it 'take as a use of the gem a call to an api by its name, from a file or from a declaration' do
      project('app/by_file.rb' => "def all = user.billing.invoices.run\n" + rescued,
              'app/declares.rb' => "class Client\n  include ApiRecipes\n  api :github, as: :hub\nend\n",
              'app/by_alias.rb' => "client.hub.users.run rescue StandardError\n",
              'app/by_name.rb' => "client.billing[:invoices]\n" + rescued,
              'app/other.rb' => "billing_total = 1\nhubs = []\n" + rescued,
              'config/apis/billing.yml' => billing)
      _, out, = run('upgrade')
      expect(out).to include('app/by_file.rb:4: [check] a bare rescue', 'app/by_alias.rb:1: [check] a bare rescue',
                             'app/by_name.rb:4: [check] a bare rescue')
      expect(out).not_to include('app/other.rb')
    end

    it 'still apply everywhere when the paths are given' do
      project('app/unrelated.rb' => rescued)
      code, out, = run('upgrade', 'app')
      expect(code).to eq(1)
      expect(out).to include('app/unrelated.rb:3: [check] a bare rescue')
    end

    it 'leave out the Hash methods of 2.x when the project has ActiveSupport' do
      project('app/a.rb' => "ApiRecipes.github\nh.symbolize_keys\n")
      expect(run('upgrade')[1]).to include('app/a.rb:2: [check] this method came from api_recipes 2.x')
      write('Gemfile.lock', "GEM\n  specs:\n    activesupport (8.0.0)\n")
      expect(run('upgrade')[1]).not_to include('app/a.rb:2')
    end
  end

  describe 'a configuration file with ERB' do
    it 'is checked without running its code: what a tag gives is not checked, the rest is' do
      marker = File.join(@dir, 'marker')
      project('config/apis/billing.yml' => <<~YAML)
        billing:
          host: <%= File.write(#{marker.inspect}, '1'); ENV.fetch('BILLING_HOST') %>
          timeout: <%= ENV.fetch('BILLING_TIMEOUT', 5) %>
          on_bad_code: explode
          default_headers:
            X-Api-Key: "<%= ENV['BILLING_KEY'] %>"
          endpoints:
            invoices:
              verb: <%= ENV['VERB'] -%>
      YAML
      code, out, err = run('upgrade')
      expect(File.exist?(marker)).to be(false)
      expect(code).to eq(1)
      expect(err).to eq('')
      expect(out).to include("config/apis/billing.yml: [config] billing.on_bad_code: 'explode' is not one of raise, ignore")
      expect(out.scan('[config]').size).to eq(1)
      expect(out).to include('config/apis/billing.yml: 4 values come from ERB and were not checked')
    end

    it 'finds a file whose name ends with .erb' do
      project('config/apis/billing.yml.erb' => billing.sub('billing.example.test', "<%= ENV['H'] %>").sub('invoices:', "invoices:\n      verb: yell"))
      _, out, = run('upgrade')
      expect(out).to include("config/apis/billing.yml.erb: [config] billing.endpoints.invoices.verb: 'yell' is not a verb known to http.rb")
    end

    it 'asks for --erb when a tag decides the structure of the file' do
      project('config/apis/billing.yml' => "billing:\n  host: h.test\n<% if ENV['X'] %>\n  endpoints:\n    invoices:\n<% end %>\n")
      code, out, = run('upgrade')
      expect(code).to eq(1)
      expect(out).to include('config/apis/billing.yml: [config] contains ERB that decides the structure of the file',
                             'run again with --erb')
    end

    it 'is evaluated with --erb, as before' do
      project('config/apis/billing.yml' => billing.sub('billing.example.test', "<%= 'evaluated.example.test' %>").sub('invoices:', "invoices:\n      verb: <%= 'yell' %>"))
      _, out, = run('upgrade', '--erb')
      expect(out).to include("[config] billing.endpoints.invoices.verb: 'yell' is not a verb known to http.rb")
      expect(out).not_to include('come from ERB')
    end

    it 'never shows what a tag contains' do
      project('config/apis/billing.yml' => billing.sub('billing.example.test', "<%= 'secret-value' %>").sub('host:', 'hots:'))
      _, out, err = run('upgrade')
      expect(out).to include("unknown option 'hots'")
      expect(out + err).not_to include('secret-value')
    end
  end

  it 'checks an installed portable recipe as a recipe' do
    recipe = "billing:\n  recipe:\n    name: billing\n    version: '1.0.0'\n  host: billing.example.test\n  endpoints:\n    invoices:\n"
    project('config/api_recipes/billing.recipe.yml' => recipe,
            'config/api_recipes/broken.recipe.yml' => recipe.gsub('billing', 'broken').sub("    version: '1.0.0'\n", ''))
    code, out, = run('upgrade')
    expect(code).to eq(1)
    expect(out.scan('[config]').size).to eq(1)
    expect(out).to match(%r{config/api_recipes/broken\.recipe\.yml: \[config\] .*version})
    expect(out).to include('Checked 2 configuration files')
  end

  it 'changes no file' do
    project('app/a.rb' => "ApiRecipes.print_urls = true\n", 'config/apis/billing.yml' => billing)
    snapshot = -> { Dir.glob('**/*', File::FNM_DOTMATCH).to_h { |f| [f, File.file?(f) ? File.read(f) : nil] } }
    before = snapshot.call
    run('upgrade')
    expect(snapshot.call).to eq(before)
  end
end
