require 'spec_helper'
require 'api_recipes/cli'
require 'tmpdir'
require 'fileutils'
require 'open3'

# `api_recipes convert FILE` in the root of a project: the api moves to a
# portable recipe and the project still works afterwards.
describe 'api_recipes convert, in a project' do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = File.realpath(dir)
      Dir.chdir(@root) { example.run }
    end
  end

  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:billing) do
    <<~YAML
      billing:
        host: <%= ENV['BILLING_HOST'] || 'billing.example.test' %>
        port: <%= ENV['BILLING_PORT'] || 443 %>
        protocol: <%= ENV['BILLING_PROTOCOL'] || 'https' %>
        verify_with: expected_response?
        default_headers:
          Accept: application/json
          Api-Key-Client: <%= ENV['BILLING_CLIENT'] %>
          Api-Key-Secret: <%= Settings.billing_secret %>
        endpoints:
          invoices:
            endpoints:
              show:
                path: /:id
    YAML
  end
  let(:initializer) do
    <<~RUBY
      ApiRecipes.configure do |config|
        config.apis_files_paths = Dir[File.expand_path('../apis/*.yml.erb', __dir__)] + Dir[File.expand_path('../apis/*.yml', __dir__)]
      end
    RUBY
  end
  let(:model) { "class Invoice\n  include ApiRecipes\n  api :billing\nend\n" }

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    path
  end

  def git(*arguments)
    out, status = Open3.capture2e('git', '-c', 'user.name=spec', '-c', 'user.email=spec@example.test', *arguments)
    raise out unless status.success?

    out
  end

  def project(files = {})
    { 'Gemfile' => "gem 'api_recipes'\n", 'config/apis/billing.yml.erb' => billing,
      'config/initializers/api_recipes.rb' => initializer, 'app/models/invoice.rb' => model }.merge(files).each { |path, text| write(path, text) }
    git('init', '-q', '.')
    git('add', '-A')
    git('commit', '-q', '-m', 'start')
  end

  def snapshot = Dir.glob('**/*', File::FNM_DOTMATCH).reject { |f| f.start_with?('.git/') }.to_h { |f| [f, File.file?(f) ? File.read(f) : nil] }

  def convert(*arguments) = run_cli('convert', *arguments)

  # Loads the file that calls configure, as the application does when it starts.
  def boot(env = {})
    stub_const('Settings', Struct.new(:billing_secret).new('from-settings'))
    env.each { |name, value| stub_const('ENV', ENV.to_h.merge(name => value)) }
    logger = Logger.new(IO::NULL)
    # A project with descriptions still to convert assigns apis_files_paths,
    # which 3.0 refuses: here only what the recipes give is looked at.
    allow_any_instance_of(ApiRecipes::Configuration).to receive(:apis_files_paths=)
    allow(ApiRecipes).to receive(:configure).and_wrap_original { |original, &block| original.call { |config| config.logger = logger; block.call(config) } }
    load File.join(@root, 'config/initializers/api_recipes.rb')
  end

  it 'installs the recipe, moves the code of the tags to config.values, and removes the old file' do
    project
    code, out, err = convert('config/apis/billing.yml.erb')
    expect(err).to eq('')
    expect(code).to eq(0)
    expect(out).to include('billing 1.0.0 now comes from a portable recipe: 2 calls',
                           'created  config/api_recipes/billing.recipe.yml, with its line in config/api_recipes/recipes.lock',
                           'edited   config/initializers/api_recipes.rb: recipes_paths and config.values; apis_files_paths, which loads nothing now, is gone',
                           'edited   app/models/invoice.rb: verify_with on the declaration of the api',
                           'deleted  config/apis/billing.yml.erb')
    expect(out).not_to include('Left to you')
    expect(File.exist?('config/apis/billing.yml.erb')).to be(false)
    expect(File.read('app/models/invoice.rb')).to include("api :billing, verify_with: :expected_response?\n")
    expect(File.read('config/initializers/api_recipes.rb')).to eq(<<~RUBY)
      ApiRecipes.configure do |config|
        config.values = {
          billing: { variables: {
            billing_host: (ENV['BILLING_HOST'] || 'billing.example.test'),
            billing_port: (ENV['BILLING_PORT'] || 443),
            billing_protocol: (ENV['BILLING_PROTOCOL'] || 'https'),
            billing_client: ENV['BILLING_CLIENT'],
            api_key_secret: (Settings.billing_secret)
          }.compact }
        }
        config.recipes_paths = Dir[File.expand_path('../api_recipes/*.recipe.yml', __dir__)]
      end
    RUBY
    expect(run_cli('check').first).to eq(0)
  end

  it 'leaves a project that starts and sends the requests it sent before' do
    project
    convert('config/apis/billing.yml.erb')
    boot('BILLING_CLIENT' => 'client-1', 'BILLING_PORT' => '8443')
    stub_request(:get, 'https://billing.example.test:8443/invoices/7').to_return(status: 200, body: '{}', headers: json)
    ApiRecipes.billing.invoices.show(7).run
    expect(WebMock).to have_requested(:get, 'https://billing.example.test:8443/invoices/7')
      .with(headers: { 'Accept' => 'application/json', 'Api-Key-Client' => 'client-1', 'Api-Key-Secret' => 'from-settings' })
  end

  it 'works in any Ruby project: configure is found wherever it is called, and the paths start from that file' do
    setup = "require 'api_recipes'\n\nmodule MyApp\n  ApiRecipes.configure do |c|\n    c.apis_files_paths = Dir[File.expand_path('../../apis/*.yml.erb', __dir__)]\n  end\nend\n"
    write('apis/billing.yml.erb', billing)
    write('lib/my_app/setup.rb', setup)
    write('lib/my_app/invoice.rb', model)
    git('init', '-q', '.')
    git('add', '-A')
    git('commit', '-q', '-m', 'start')
    code, out, err = convert('apis/billing.yml.erb')
    expect(err).to eq('')
    expect(code).to eq(0)
    expect(out).to include('edited   lib/my_app/setup.rb: recipes_paths and config.values', 'deleted  apis/billing.yml.erb')
    expect(File.read('lib/my_app/setup.rb')).to include("    c.values = {\n      billing: { variables: {\n",
                                                        "    c.recipes_paths = Dir[File.expand_path('../../config/api_recipes/*.recipe.yml', __dir__)]\n  end\nend\n")
    stub_const('Settings', Struct.new(:billing_secret).new('from-settings'))
    logger = Logger.new(IO::NULL)
    # A project with descriptions still to convert assigns apis_files_paths,
    # which 3.0 refuses: here only what the recipes give is looked at.
    allow_any_instance_of(ApiRecipes::Configuration).to receive(:apis_files_paths=)
    allow(ApiRecipes).to receive(:configure).and_wrap_original { |original, &block| original.call { |config| config.logger = logger; block.call(config) } }
    load File.join(@root, 'lib/my_app/setup.rb')
    expect(ApiRecipes.billing.invoices.show(7).url.to_s).to eq('https://billing.example.test/invoices/7')
  end

  describe 'apis_files_paths, when the last description of the project goes' do
    def initializer_text = File.read('config/initializers/api_recipes.rb')

    it 'stays while another file describes an api, and goes with the last one' do
      project('config/apis/other.yml' => "other:\n  host: other.example.test\n  endpoints:\n    ping:\n")
      expect(convert('config/apis/billing.yml.erb').first).to eq(0)
      expect(initializer_text).to include('config.apis_files_paths = ')
      git('add', '-A')
      git('commit', '-q', '-m', 'first')
      code, out, = convert('config/apis/other.yml')
      expect(code).to eq(0)
      expect(out).to include('apis_files_paths, which loads nothing now, is gone')
      expect(initializer_text).not_to include('apis_files_paths')
      boot
      expect(ApiRecipes.apis).to contain_exactly(:billing, :other)
    end

    it 'stays, and the person is told, when the file that assigns it has changes that are not committed' do
      project('config/apis/other.yml' => "other:\n  host: other.example.test\n  endpoints:\n    ping:\n")
      expect(convert('config/apis/billing.yml.erb').first).to eq(0)
      code, out, = convert('config/apis/other.yml')
      expect(code).to eq(0)
      expect(out).to include('Left to you', 'config.apis_files_paths, at line 2 of config/initializers/api_recipes.rb, loads no file now: you can take it out')
      expect(initializer_text).to include('config.apis_files_paths = ')
    end

    it 'goes with the last description however it was written: what it named is gone' do
      project('config/initializers/api_recipes.rb' => "BASE = File.expand_path('../apis', __dir__)\nApiRecipes.configure do |config|\n  config.apis_files_paths = Dir[File.join(BASE, '*.yml.erb')]\nend\n")
      expect(convert('config/apis/billing.yml.erb').first).to eq(0)
      expect(initializer_text).not_to include('apis_files_paths')
      FileUtils.rm_rf(Dir.children('.'))
      project('config/initializers/api_recipes.rb' => "ApiRecipes.configure do |config|\n  config.apis_files_paths = Dir[Rails.root.join 'config', 'apis', '*']\nend\n",
              'config/apis/notes.txt' => "not a description\n")
      expect(convert('config/apis/billing.yml.erb').first).to eq(0)
      expect(initializer_text).not_to include('apis_files_paths')
    end

    it 'goes when it was a list that named only the file' do
      project('config/initializers/api_recipes.rb' => "ApiRecipes.configure do |config|\n  config.print_urls = false\n  config.apis_files_paths = [File.expand_path('../apis/billing.yml.erb', __dir__)]\nend\n")
      expect(convert('config/apis/billing.yml.erb').first).to eq(0)
      expect(initializer_text).to start_with("ApiRecipes.configure do |config|\n  config.print_urls = false\n  config.values = {\n")
    end
  end

  describe 'with no file' do
    let(:other) { "other:\n  host: other.example.test\n  endpoints:\n    ping:\n" }
    let(:two) { "first:\n  host: first.example.test\n  endpoints:\n    ping:\n\nsecond:\n  host: second.example.test\n  endpoints:\n    ping:\n" }

    it 'moves every api that the project describes to a recipe in one run, and takes apis_files_paths out' do
      project('config/apis/other.yml' => other, 'config/apis/two.yml' => two)
      code, out, err = convert
      expect([code, err]).to eq([0, ''])
      expect(out).to include('billing 1.0.0 now comes from a portable recipe', 'other 1.0.0 now comes from a portable recipe',
                             'first 1.0.0 now comes from a portable recipe', 'second 1.0.0 now comes from a portable recipe',
                             'apis_files_paths, which loads nothing now, is gone')
      expect(Dir.glob('config/**/*').select { |file| File.file?(file) }.sort)
        .to eq(%w[billing first other second].map { |name| "config/api_recipes/#{name}.recipe.yml" }.push('config/api_recipes/recipes.lock',
                                                                                                         'config/initializers/api_recipes.rb').sort)
      expect(File.read('config/initializers/api_recipes.rb')).not_to include('apis_files_paths')
      boot
      expect(ApiRecipes.apis).to contain_exactly(:billing, :other, :first, :second)
      expect(run_cli('check').first).to eq(0)
    end

    it 'converts what it can, says what it could not, and leaves that file and apis_files_paths where they are' do
      project('config/apis/other.yml' => "<% if ENV['X'] %>\n#{other}<% end %>\n")
      code, out, err = convert
      expect(code).to eq(1)
      expect(out).to include('billing 1.0.0 now comes from a portable recipe')
      expect(err).to include('config/apis/other.yml was not converted:')
      expect(File.exist?('config/apis/other.yml')).to be(true)
      expect(File.read('config/initializers/api_recipes.rb')).to include('apis_files_paths')
    end

    it 'says so when the project describes no api in a file, and still needs a file outside a project' do
      write('Gemfile', "gem 'api_recipes'\n")
      expect(convert).to match([0, /No file of this project describes an api/, ''])
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { expect(convert).to match([2, '', /convert needs one configuration file, or none in the root of a project/]) }
      end
    end
  end

  it 'works when the old files and the recipes share a folder and one pattern matches both' do
    project('config/initializers/api_recipes.rb' => "ApiRecipes.configure do |config|\n  config.apis_files_paths = Dir[File.expand_path('../api_recipes/*.yml*', __dir__)]\nend\n",
            'config/api_recipes/other.yml' => "other:\n  host: other.example.test\n  endpoints:\n    ping:\n")
    FileUtils.mv('config/apis/billing.yml.erb', 'config/api_recipes/billing.yml.erb')
    git('add', '-A')
    git('commit', '-q', '-m', 'one folder')
    expect(convert('config/api_recipes/billing.yml.erb').first).to eq(0)
    expect(convert('config/api_recipes/other.yml').first).to eq(0)
    boot
    expect(ApiRecipes.apis).to contain_exactly(:billing, :other)
    expect(ApiRecipes.billing.invoices.show(7).url.to_s).to eq('https://billing.example.test/invoices/7')
  end

  it 'adds a second api to the config.values it wrote, and takes only its lines out of a file with others' do
    apis = "github:\n  host: api.github.test\n  default_headers:\n    Authorization: Bearer written-token\n  endpoints:\n    users:\n" \
           "shop:\n  host: shop.example.test\n  endpoints:\n    orders:\n"
    project('config/apis/apis.yml' => apis)
    expect(convert('config/apis/billing.yml.erb').first).to eq(0)
    code, out, = convert('config/apis/apis.yml', '--name', 'github')
    expect(code).to eq(0)
    expect(out).to include('edited   config/apis/apis.yml: the lines of github are gone')
    expect(File.read('config/apis/apis.yml')).to eq("shop:\n  host: shop.example.test\n  endpoints:\n    orders:\n")
    expect(File.read('config/initializers/api_recipes.rb')).to include("    }.compact },\n    github: { variables: {\n      authorization: \"Bearer written-token\"\n    }.compact }\n  }\n")
    boot
    stub_request(:get, 'https://api.github.test/users').to_return(status: 200, body: '[]', headers: json)
    ApiRecipes.github.users.run
    expect(WebMock).to have_requested(:get, 'https://api.github.test/users').with(headers: { 'Authorization' => 'Bearer written-token' })
    # shop is still described in a file: it loads once it is a recipe too.
    expect(ApiRecipes.apis).to contain_exactly(:billing, :github)
  end

  describe 'when a step cannot be done safely' do
    def refused(expected)
      before = snapshot
      code, out, err = convert('config/apis/billing.yml.erb')
      expect(code).to eq(1)
      expect(out).to include('What to do by hand')
      expect(err).to include('the project was not changed', expected, 'Nothing was written')
      expect(snapshot).to eq(before)
    end

    it 'changes nothing: the old file has changes that are not committed' do
      project
      File.write('config/apis/billing.yml.erb', "#{billing}# a note\n")
      refused('config/apis/billing.yml.erb is not committed in git as it is now')
    end

    it 'changes nothing: git does not know the file that calls configure' do
      project
      git('rm', '-q', '--cached', 'config/initializers/api_recipes.rb')
      git('commit', '-q', '-m', 'untrack')
      refused('config/initializers/api_recipes.rb is not a file that git tracks')
    end

    it 'changes nothing: the project is not in git' do
      project
      FileUtils.remove_entry('.git')
      refused('is not committed in git as it is now')
    end

    it 'changes nothing: configure is written in another way, is missing, or is called twice' do
      project('config/initializers/api_recipes.rb' => "ApiRecipes.configure { |c| c.apis_files_paths = [] }\n")
      refused('the call to ApiRecipes.configure is written on one line')
      File.write('config/initializers/api_recipes.rb', "# nothing\n")
      git('commit', '-q', '-am', 'none')
      refused('no Ruby file of the project calls ApiRecipes.configure once')
      File.write('config/initializers/api_recipes.rb', initializer)
      write('config/initializers/other.rb', initializer)
      git('add', '-A')
      git('commit', '-q', '-m', 'two')
      refused('ApiRecipes.configure is called in 2 files')
    end

    it 'changes nothing: config.values is already assigned in another way' do
      project('config/initializers/api_recipes.rb' => initializer.sub("end\n", "  config.values = VALUES\nend\n"))
      refused('config.values is not given one Hash written between braces')
    end

    it 'changes nothing: the file would not be valid Ruby with the code of a tag' do
      project('config/apis/billing.yml.erb' => billing.sub("ENV['BILLING_CLIENT']", "ENV['BILLING_CLIENT'] # the client"))
      refused('config/initializers/api_recipes.rb would not be valid Ruby after the change')
    end

    it 'changes nothing: the recipe is already installed' do
      project('config/api_recipes/billing.recipe.yml' => 'mine')
      refused('config/api_recipes/billing.recipe.yml already exists')
    end
  end

  it 'gives the whole block of configure to paste over the one that is there, when it does not change the project' do
    project
    File.write('config/apis/billing.yml.erb', "#{billing}# a note\n")
    _, out, = convert('config/apis/billing.yml.erb')
    expect(out).to eq(<<~TEXT)

      What to do by hand

      1. Write the recipe and install it:

          bundle exec api_recipes convert config/apis/billing.yml.erb --to config/api_recipes
          bundle exec api_recipes install config/api_recipes/billing.recipe.yml --yes

      2. In config/initializers/api_recipes.rb, replace the block of ApiRecipes.configure (lines 1 to 3) with:

          ApiRecipes.configure do |config|
            config.values = {
              billing: { variables: {
                billing_host: (ENV['BILLING_HOST'] || 'billing.example.test'),
                billing_port: (ENV['BILLING_PORT'] || 443),
                billing_protocol: (ENV['BILLING_PROTOCOL'] || 'https'),
                billing_client: ENV['BILLING_CLIENT'],
                api_key_secret: (Settings.billing_secret)
              }.compact }
            }
            config.recipes_paths = Dir[File.expand_path('../api_recipes/*.recipe.yml', __dir__)]
          end

      3. Where the api is declared (app/models/invoice.rb:3), give verify_with:

          api :billing, verify_with: :expected_response?

      4. Remove the old description: delete config/apis/billing.yml.erb
    TEXT
  end

  it 'points at the config.values that is there, and at the lines to take out of a file with other apis' do
    project('config/initializers/api_recipes.rb' => initializer.sub("end\n", "  config.values = VALUES\nend\n"),
            'config/apis/billing.yml.erb' => "#{billing}other:\n  host: o.test\n  endpoints:\n    ping:\n")
    _, out, = convert('config/apis/billing.yml.erb', '--name', 'billing')
    expect(out).to include('add this to the Hash that config.values is given at line 3, and the line of recipes_paths:',
                           "    billing: { variables: {\n", "    }.compact }\n\n    config.recipes_paths = Dir[",
                           'take the lines of billing out of config/apis/billing.yml.erb (lines 1 to 14)')
  end

  it 'paints the code on a terminal, and only there' do
    project
    File.write('config/apis/billing.yml.erb', "#{billing}# a note\n")
    terminal = StringIO.new
    terminal.define_singleton_method(:tty?) { true }
    ApiRecipes::CLI.run(%w[convert config/apis/billing.yml.erb], out: terminal, err: StringIO.new)
    expect(terminal.string).to include("\e[36mbilling_client:\e[0m \e[33mENV\e[0m[\e[32m'BILLING_CLIENT'\e[0m]", "\e[33mApiRecipes\e[0m.configure \e[35mdo\e[0m |config|")
    expect(convert('config/apis/billing.yml.erb')[1]).not_to include("\e")
  end

  it 'says what it could not do by itself: verify_with when no class declares the api' do
    project('app/models/invoice.rb' => "class Invoice\nend\n")
    code, out, = convert('config/apis/billing.yml.erb')
    expect(code).to eq(0)
    expect(out).to include('Left to you', 'verify_with: was left out of the recipe and could not be written in the code')
  end

  it 'shows nothing of the file when it changes the project itself' do
    project('config/apis/billing.yml.erb' => billing.sub('Settings.billing_secret', "ENV.fetch('S', 'hard-coded-secret')").sub('Accept: application/json', "Accept: application/json\n    X-Api-Token: written-secret"))
    code, out, err = convert('config/apis/billing.yml.erb')
    expect(code).to eq(0)
    expect(out + err + File.read('config/api_recipes/billing.recipe.yml')).not_to match(/hard-coded-secret|written-secret|ENV|Settings/)
    expect(File.read('config/initializers/api_recipes.rb')).to include("s: (ENV.fetch('S', 'hard-coded-secret'))", 'x_api_token: "written-secret"')
  end

  describe 'on Ruby as people write it' do
    def initializer_text = File.read('config/initializers/api_recipes.rb')

    it 'gives each tag its own variable, also two in one value, and loses the code of none' do
      project('config/apis/billing.yml.erb' => <<~YAML)
        billing:
          host: <%= Settings.sub %>.<%= Settings.domain %>.example.test
          default_headers:
            X-Mode: <%= ENV['MODE'] || 'a' %>
          default_params:
            mode: <%= ENV['MODE'] || 'b' %>
          endpoints:
            invoices:
              path: /inv-<%= Settings.sub %>
      YAML
      expect(convert('config/apis/billing.yml.erb').first).to eq(0)
      expect(initializer_text).to include('host: (Settings.sub)', 'host_2: (Settings.domain)', "mode: (ENV['MODE'] || 'a')", "mode_2: (ENV['MODE'] || 'b')")
      stub_const('Settings', Struct.new(:sub, :domain).new('one', 'two'))
      load File.join(@root, 'config/initializers/api_recipes.rb')
      stub_request(:get, 'https://one.two.example.test/inv-one?mode=b').to_return(status: 200, body: '{}', headers: json)
      ApiRecipes.billing.invoices.run
      expect(WebMock).to have_requested(:get, 'https://one.two.example.test/inv-one?mode=b').with(headers: { 'X-Mode' => 'a' })
    end

    it 'gives verify_with to the call, wherever the line goes on, and leaves a string that looks like one alone' do
      { "api :billing if ENV['X']" => "api :billing, verify_with: :expected_response? if ENV['X']",
        'api :billing; puts 1' => 'api :billing, verify_with: :expected_response?; puts 1',
        'api(:billing)' => 'api(:billing, verify_with: :expected_response?)',
        "api :billing, as: :bills # the api" => 'api :billing, as: :bills, verify_with: :expected_response? # the api' }.each do |written, expected|
        FileUtils.rm_rf(Dir.children('.'))
        project('app/models/invoice.rb' => "class Invoice\n  include ApiRecipes\n  #{written}\n  TEXT = <<~T\n    api :billing\n  T\nend\n")
        expect(convert('config/apis/billing.yml.erb').first).to eq(0)
        expect(File.read('app/models/invoice.rb')).to eq("class Invoice\n  include ApiRecipes\n  #{expected}\n  TEXT = <<~T\n    api :billing\n  T\nend\n")
      end
    end

    it 'leaves to the person a verify_with that a tag gave, and writes no mark of its own in the code' do
      project('config/apis/billing.yml.erb' => billing.sub('verify_with: expected_response?', 'verify_with: <%= ENV["CHECK"] || "expected_response?" %>'))
      code, out, = convert('config/apis/billing.yml.erb')
      expect(code).to eq(0)
      expect(out).to include('Left to you', 'verify_with: was left out of the recipe')
      expect(File.read('app/models/invoice.rb')).to eq(model)
    end

    it 'does not touch a declaration in a file that git does not track' do
      project
      git('rm', '-q', '--cached', 'app/models/invoice.rb')
      git('commit', '-q', '-m', 'untrack')
      code, out, = convert('config/apis/billing.yml.erb')
      expect(code).to eq(0)
      expect(out).to include('Left to you')
      expect(File.read('app/models/invoice.rb')).to eq(model)
    end

    it 'adds its entry to a config.values written by hand, and keeps what was there' do
      project('config/initializers/api_recipes.rb' => initializer.sub("end\n", "  config.values = {\n    :github => { authorization: 'TOKEN-1' } # mine\n  }\nend\n"),
              'config/apis/github.yml' => "github:\n  host: api.github.test\n  endpoints:\n    users:\n")
      expect(convert('config/apis/billing.yml.erb').first).to eq(0)
      expect(initializer_text).to include(":github => { authorization: 'TOKEN-1' }, # mine\n    billing: { variables: {\n")
      expect(convert('config/apis/github.yml').first).to eq(0)
      boot
      stub_request(:get, 'https://api.github.test/users').to_return(status: 200, body: '[]', headers: json)
      ApiRecipes.github.users.run
      expect(WebMock).to have_requested(:get, 'https://api.github.test/users').with(headers: { 'Authorization' => 'TOKEN-1' })
    end

    it 'does not write a second entry for an api that config.values has, however its name is written' do
      [":billing => { authorization: 'T' }", "'billing': { authorization: 'T' }", "billing: { authorization: 'T' }"].each do |entry|
        FileUtils.rm_rf(Dir.children('.'))
        project('config/initializers/api_recipes.rb' => initializer.sub("end\n", "  config.values = {\n    #{entry}\n  }\nend\n"))
        before = snapshot
        code, _, err = convert('config/apis/billing.yml.erb')
        expect(code).to eq(1)
        expect(err).to include('config.values already has billing')
        expect(snapshot).to eq(before)
      end
    end

    it 'adds its lines at the end of the block, whatever the block holds' do
      body = "  if ENV['OFFLINE']\n  config.print_urls = true\nend\n  TEXT = <<~T\n    end\n  T\n  # config.recipes_paths = [] # later\n"
      project('config/initializers/api_recipes.rb' => initializer.sub("end\n", "#{body}end\n"))
      expect(convert('config/apis/billing.yml.erb').first).to eq(0)
      expect(initializer_text).to end_with("  # config.recipes_paths = [] # later\n  config.values = {\n#{initializer_text[/    billing: .*?\.compact \}\n/m]}  }\n" \
                                           "  config.recipes_paths = Dir[File.expand_path('../api_recipes/*.recipe.yml', __dir__)]\nend\n")
      boot
      expect(ApiRecipes.apis).to eq([:billing])
    end

    it 'changes nothing when the block of configure has a rescue, or assigns the values only sometimes' do
      [["end\n", "rescue StandardError\n  nil\nend\n", 'has a rescue or an ensure'],
       ["end\n", "  config.values = { a: {} } if ENV['A']\nend\n", 'config.values is assigned where the block does not always run it'],
       ["end\n", "  config.recipes_paths = OTHER\nend\n", 'config.recipes_paths is assigned at line 3 in a way this command cannot read']].each do |from, to, reason|
        FileUtils.rm_rf(Dir.children('.'))
        project('config/initializers/api_recipes.rb' => initializer.sub(from, to))
        before = snapshot
        expect(convert('config/apis/billing.yml.erb')).to match([1, /What to do by hand/, /#{Regexp.escape(reason)}/])
        expect(snapshot).to eq(before)
      end
    end

    it 'keeps both changes when configure and the declaration are in one file' do
      setup = "class Client\n  include ApiRecipes\n  api :billing\nend\n\nApiRecipes.configure do |config|\n  config.apis_files_paths = Dir[File.expand_path('../apis/*.yml.erb', __dir__)]\nend\n"
      project('config/initializers/api_recipes.rb' => setup, 'app/models/invoice.rb' => "class Invoice\nend\n")
      code, out, = convert('config/apis/billing.yml.erb')
      expect(code).to eq(0)
      expect(out).to include('edited   config/initializers/api_recipes.rb: recipes_paths and config.values; apis_files_paths, which loads nothing now, is gone, and verify_with on the declaration of the api')
      expect(initializer_text).to include('api :billing, verify_with: :expected_response?', 'config.values = {', 'config.recipes_paths = ')
    end

    it 'takes the old file out of the list given to apis_files_paths, on one line or on its own line' do
      ["config.apis_files_paths = [File.expand_path('../apis/billing.yml.erb', __dir__), 'config/apis/other.yml']",
       "config.apis_files_paths = [\n    File.expand_path('../apis/billing.yml.erb', __dir__),\n    'config/apis/other.yml'\n  ]"].each do |assignment|
        FileUtils.rm_rf(Dir.children('.'))
        project('config/initializers/api_recipes.rb' => "ApiRecipes.configure do |config|\n  #{assignment}\nend\n",
                'config/apis/other.yml' => "other:\n  host: other.example.test\n  endpoints:\n    ping:\n")
        expect(convert('config/apis/billing.yml.erb').first).to eq(0)
        expect(initializer_text).not_to include('billing.yml.erb')
        boot
        expect(ApiRecipes.apis).to contain_exactly(:billing)
      end
    end

    it 'takes out of the list the element that names the file, wherever it is, and nothing else' do
      project('config/initializers/api_recipes.rb' => "ApiRecipes.configure do |config|\n  config.apis_files_paths = ['config/apis/other.yml', 'config/apis/billing.yml.erb'] + Dir['config/more/*.yml']\nend\n",
              'config/apis/other.yml' => "other:\n  host: other.example.test\n  endpoints:\n    ping:\n")
      expect(convert('config/apis/billing.yml.erb').first).to eq(0)
      expect(File.read('config/initializers/api_recipes.rb')).to include("config.apis_files_paths = ['config/apis/other.yml'] + Dir['config/more/*.yml']\n")
    end

    it 'changes nothing when it cannot read how the project loads its files' do
      ["config.apis_files_paths = %w[config/apis/billing.yml.erb config/apis/other.yml]",
       "config.apis_files_paths = %w[billing].map { |n| \"config/apis/\#{n}.yml.erb\" }",
       "config.apis_files_paths = ['config/legacy/billing.yml.erb', 'config/apis/billing.yml.erb']",
       "config.apis_files_paths = ['config/apis/billing.yml.erb', *names.map { |n| \"config/apis/\#{n}.yml\" }]",
       "config.apis_files_paths = FILES", "config.print_urls = true"].each do |assignment|
        FileUtils.rm_rf(Dir.children('.'))
        project('config/initializers/api_recipes.rb' => "ApiRecipes.configure do |config|\n  #{assignment}\nend\n")
        before = snapshot
        code, out, err = convert('config/apis/billing.yml.erb')
        expect([code, err]).to match([1, /apis_files_paths is (given, at line 2, in a way this command cannot read|not assigned in the block)/])
        expect(out).to include('What to do by hand')
        expect(snapshot).to eq(before)
      end
    end

    it 'changes nothing when it cannot read all of the Hash given to config.values' do
      { "config.values = { other: {\n    authorization: 'x',\n  } }" => 'whose closing brace does not start a line',
        "config.values = {\n    **CREDS\n  }" => 'has a key that is not written as a name, or a **',
        "config.values = {\n    API => { authorization: 'x' }\n  }" => 'has a key that is not written as a name, or a **' }.each do |assignment, reason|
        FileUtils.rm_rf(Dir.children('.'))
        project('config/initializers/api_recipes.rb' => initializer.sub("end\n", "  #{assignment}\nend\n"))
        before = snapshot
        code, out, err = convert('config/apis/billing.yml.erb')
        expect([code, err]).to match([1, /#{Regexp.escape(reason)}/])
        expect(out).to include("add this to the Hash that config.values is given at line 3, and the line of recipes_paths:\n\n    billing: { variables: {\n")
        expect(snapshot).to eq(before)
      end
    end

    it 'changes nothing when the block of configure can end before its last line' do
      project('config/initializers/api_recipes.rb' => initializer.sub("end\n", "  next if ENV['SKIP_REST']\nend\n"))
      before = snapshot
      expect(convert('config/apis/billing.yml.erb')).to match([1, /What to do by hand/, /can end before its last line/])
      expect(snapshot).to eq(before)
    end

    it 'takes lines out of the file that calls configure only when git has it as it is, and edits no file that git only heard of' do
      list = "ApiRecipes.configure do |config|\n  config.apis_files_paths = [\n    'config/apis/billing.yml.erb',\n    'config/apis/other.yml'\n  ]\nend\n"
      project('config/apis/other.yml' => "other:\n  host: other.example.test\n  endpoints:\n    ping:\n")
      File.write('config/initializers/api_recipes.rb', list)
      before = snapshot
      expect(convert('config/apis/billing.yml.erb')).to match([1, /What to do by hand/, /api_recipes.rb is not committed in git as it is now/])
      expect(snapshot).to eq(before)
      git('checkout', '-q', '.')
      File.write('app/models/later.rb', model.sub('Invoice', 'Later'))
      git('add', '-N', 'app/models/later.rb')
      code, out, = convert('config/apis/billing.yml.erb')
      expect(code).to eq(0)
      expect(out).to include('Left to you')
      expect(File.read('app/models/later.rb')).to eq(model.sub('Invoice', 'Later'))
    end

    it 'gives verify_with only to a declaration of a class or a module, and to none when it cannot read one of them' do
      project('app/models/invoice.rb' => "class Invoice\n  include ApiRecipes\n  api :billing\n  def again = api(:billing)\nend\n")
      expect(convert('config/apis/billing.yml.erb').first).to eq(0)
      expect(File.read('app/models/invoice.rb')).to eq("class Invoice\n  include ApiRecipes\n  api :billing, verify_with: :expected_response?\n  def again = api(:billing)\nend\n")
      FileUtils.rm_rf(Dir.children('.'))
      project('app/models/other.rb' => "class Other\n  include ApiRecipes\n  api :billing, **OPTIONS\nend\n")
      code, out, = convert('config/apis/billing.yml.erb')
      expect(code).to eq(0)
      expect(out).to include('Left to you')
      expect(File.read('app/models/invoice.rb')).to eq(model)
      expect(File.read('app/models/other.rb')).to include("api :billing, **OPTIONS\n")
    end

    it 'adds lines with the line ends and the indentation of the file' do
      project('config/initializers/api_recipes.rb' => "ApiRecipes.configure do |config|\r\n\tconfig.apis_files_paths = Dir[File.expand_path('../apis/*.yml.erb', __dir__)]\r\nend\r\n")
      expect(convert('config/apis/billing.yml.erb').first).to eq(0)
      text = File.binread('config/initializers/api_recipes.rb')
      expect(text.scan(/(?<!\r)\n/)).to eq([])
      expect(text).to include("\tconfig.values = {\r\n\t\tbilling: { variables: {\r\n\t\t\tbilling_host: ")
    end

    it 'changes nothing when the old file is named somewhere it cannot take it out of' do
      project('lib/loader.rb' => "TEXT = File.read('config/apis/billing.yml.erb')\n")
      before = snapshot
      code, _, err = convert('config/apis/billing.yml.erb')
      expect(code).to eq(1)
      expect(err).to include('lib/loader.rb:1 names billing.yml.erb, which would be deleted')
      expect(snapshot).to eq(before)
    end

    it 'changes nothing when another file describes the api too, or when git would ignore the recipe' do
      project('config/apis/billing_override.yml' => "billing:\n  host: o.test\n  endpoints:\n    a:\n")
      before = snapshot
      expect(convert('config/apis/billing.yml.erb')).to match([1, /What to do by hand/, /billing is described in config\/apis\/billing_override.yml too/])
      expect(snapshot).to eq(before)
      FileUtils.rm_rf(Dir.children('.'))
      project('.gitignore' => "config/api_recipes/\n")
      before = snapshot
      expect(convert('config/apis/billing.yml.erb')).to match([1, /What to do by hand/, /would be ignored by git/])
      expect(snapshot).to eq(before)
    end

    it 'puts every file back when a write fails halfway, and says so' do
      project
      before = snapshot
      allow(File).to receive(:delete).and_wrap_original do |original, path|
        raise Errno::EACCES if path.end_with?('billing.yml.erb')

        original.call(path)
      end
      code, _, err = convert('config/apis/billing.yml.erb')
      expect(code).to eq(2)
      expect(err).to include('the project could not be changed (EACCES): every file was put back as it was')
      expect(snapshot).to eq(before)
    end

    it 'changes nothing when a file it would write cannot be written' do
      project
      File.chmod(0o444, 'app/models/invoice.rb')
      code, out, = convert('config/apis/billing.yml.erb')
      expect(code).to eq(0)
      expect(out).to include('Left to you')
      FileUtils.rm_rf('config/api_recipes')
      git('checkout', '-q', '.')
      File.chmod(0o444, 'config/initializers/api_recipes.rb')
      before = snapshot
      expect(convert('config/apis/billing.yml.erb').first).to eq(1)
      expect(snapshot).to eq(before)
    ensure
      File.chmod(0o644, 'app/models/invoice.rb', 'config/initializers/api_recipes.rb')
    end

    it 'gives as text a true or a number that was the value of what is named like a credential' do
      project('config/apis/billing.yml.erb' => billing.sub("  endpoints:\n", "  default_params:\n    tokenize: true\n    session_ttl: 30\n  endpoints:\n"))
      expect(convert('config/apis/billing.yml.erb').first).to eq(0)
      expect(initializer_text).to include('tokenize: "true"', 'session_ttl: "30"')
      boot
      expect(ApiRecipes.billing.invoices.show(7).url.to_s).to eq('https://billing.example.test/invoices/7')
    end

    it 'takes a file given with its whole path, and an api whose name is not a Ruby name' do
      project('config/apis/my-api.yml.erb' => "my-api:\n  host: <%= ENV['H'] || 'my.example.test' %>\n  endpoints:\n    ping:\n",
              'config/apis/billing.yml.erb' => "billing:\n  host: b.example.test\n  endpoints:\n    ping:\n")
      expect(convert(File.join(@root, 'config/apis/my-api.yml.erb')).first).to eq(0)
      expect(initializer_text).to include("\"my-api\": { variables: {\n")
      boot
      expect(ApiRecipes[:'my-api'].ping.url.to_s).to eq('https://my.example.test/ping')
    end

    it 'answers with one line to what it did not foresee' do
      project
      allow_any_instance_of(ApiRecipes::CLI::Convert::Migration).to receive(:call).and_raise('boom with a value')
      expect(convert('config/apis/billing.yml.erb')).to eq([1, '', "convert failed (RuntimeError): this is a defect of api_recipes, not of the file\n"])
    end
  end

  it 'with --to writes the recipe alone and leaves the project as it is' do
    project
    before = snapshot
    code, out, = convert('config/apis/billing.yml.erb', '--to', 'tmp/recipes')
    expect(code).to eq(0)
    expect(out).to include('billing 1.0.0 is written in tmp/recipes/billing.recipe.yml')
    expect(snapshot.reject { |path, _| path.start_with?('tmp') }).to eq(before)
  end
end
