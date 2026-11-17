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
                           'edited   config/initializers/api_recipes.rb: recipes_paths and config.values',
                           'edited   app/models/invoice.rb: verify_with on the declaration of the api',
                           'deleted  config/apis/billing.yml.erb')
    expect(out).not_to include('Left to you')
    expect(File.exist?('config/apis/billing.yml.erb')).to be(false)
    expect(File.read('app/models/invoice.rb')).to include("api :billing, verify_with: :expected_response?\n")
    expect(File.read('config/initializers/api_recipes.rb')).to eq(<<~RUBY)
      ApiRecipes.configure do |config|
        config.apis_files_paths = Dir[File.expand_path('../apis/*.yml.erb', __dir__)] + Dir[File.expand_path('../apis/*.yml', __dir__)]
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
    allow(ApiRecipes).to receive(:configure).and_wrap_original { |original, &block| original.call { |config| config.logger = logger; block.call(config) } }
    load File.join(@root, 'lib/my_app/setup.rb')
    expect(ApiRecipes.billing.invoices.show(7).url.to_s).to eq('https://billing.example.test/invoices/7')
  end

  it 'works when the old files and the recipes share a folder and one pattern matches both' do
    project('config/initializers/api_recipes.rb' => "ApiRecipes.configure do |config|\n  config.apis_files_paths = Dir[File.expand_path('../api_recipes/*.yml*', __dir__)]\nend\n",
            'config/api_recipes/other.yml' => "other:\n  host: other.example.test\n  endpoints:\n    ping:\n")
    FileUtils.mv('config/apis/billing.yml.erb', 'config/api_recipes/billing.yml.erb')
    git('add', '-A')
    git('commit', '-q', '-m', 'one folder')
    expect(convert('config/api_recipes/billing.yml.erb').first).to eq(0)
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
    expect(ApiRecipes.apis).to contain_exactly(:billing, :github, :shop)
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
      refused('config/initializers/api_recipes.rb is not in git')
    end

    it 'changes nothing: the project is not in git' do
      project
      FileUtils.remove_entry('.git')
      refused('is not in git')
    end

    it 'changes nothing: configure is written in another way, is missing, or is called twice' do
      project('config/initializers/api_recipes.rb' => "ApiRecipes.configure { |c| c.apis_files_paths = [] }\n")
      refused('ApiRecipes.configure is not written once as `ApiRecipes.configure do |config|`')
      File.write('config/initializers/api_recipes.rb', "# nothing\n")
      git('commit', '-q', '-am', 'none')
      refused('no Ruby file of the project calls ApiRecipes.configure')
      File.write('config/initializers/api_recipes.rb', initializer)
      write('config/initializers/other.rb', initializer)
      git('add', '-A')
      git('commit', '-q', '-m', 'two')
      refused('ApiRecipes.configure is called in 2 files')
    end

    it 'changes nothing: config.values is already assigned in another way' do
      project('config/initializers/api_recipes.rb' => initializer.sub("end\n", "  config.values = VALUES\nend\n"))
      refused('config.values is already assigned in a way this command does not edit')
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
            config.apis_files_paths = Dir[File.expand_path('../apis/*.yml.erb', __dir__)] + Dir[File.expand_path('../apis/*.yml', __dir__)]
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

      3. On the line that declares the api (app/models/invoice.rb:3), give verify_with:

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

  it 'with --to writes the recipe alone and leaves the project as it is' do
    project
    before = snapshot
    code, out, = convert('config/apis/billing.yml.erb', '--to', 'tmp/recipes')
    expect(code).to eq(0)
    expect(out).to include('billing 1.0.0 is written in tmp/recipes/billing.recipe.yml')
    expect(snapshot.reject { |path, _| path.start_with?('tmp') }).to eq(before)
  end
end
