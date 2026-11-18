require 'spec_helper'
require 'api_recipes/cli'
require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'open3'

# `api_recipes upgrade` on a terminal: the changes it is sure of are shown as
# a diff, one at a time, and made only when the answer is yes.
describe 'api_recipes upgrade, the changes it offers' do
  around do |example|
    Dir.mktmpdir do |dir|
      Dir.chdir(File.realpath(dir)) { example.run }
    end
  end

  let(:initializer) { "ApiRecipes.configure do |config|\n  config.log_level = :info\nend\n" }
  let(:files) do
    { 'Gemfile' => "gem 'api_recipes'\n",
      'config/initializers/api_recipes.rb' => "#{initializer}ApiRecipes.print_urls = true\n",
      'config/initializers/billing.rb' => "# the token of billing\nApiRecipes.billing.authorization = ENV['BILLING_TOKEN']\n" }
  end

  def git(*arguments)
    out, status = Open3.capture2e('git', '-c', 'user.name=spec', '-c', 'user.email=spec@example.test', *arguments)
    raise out unless status.success?

    out
  end

  def project(given = files)
    given.each do |path, text|
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text)
    end
    git('init', '-q', '.')
    git('add', '-A')
    git('commit', '-q', '-m', 'start')
  end

  # Runs upgrade with these answers typed on a terminal, where the results
  # are shown, without colours; nil for no terminal.
  def upgrade(answers, *arguments)
    out = StringIO.new
    input = StringIO.new(answers.to_s)
    [input, out].each { |io| io.define_singleton_method(:tty?) { true } } if answers
    saved = ENV.fetch('NO_COLOR', nil)
    ENV['NO_COLOR'] = '1'
    [ApiRecipes::CLI.run(['upgrade', *arguments], out: out, err: out, input: input), out.string]
  ensure
    saved ? ENV['NO_COLOR'] = saved : ENV.delete('NO_COLOR')
  end

  it 'shows each change as a diff and makes the ones answered with yes, then says what it changed' do
    project
    code, out = upgrade("y\nyes\n")
    expect(out).to include("Move print_urls into the block of ApiRecipes.configure\n\nconfig/initializers/api_recipes.rb:1\n" \
                           "  ApiRecipes.configure do |config|\n    config.log_level = :info\n" \
                           "+   config.print_urls = true\n  end\n- ApiRecipes.print_urls = true\n\nMake this change? [y/N] ")
    expect(out).to include("+   config.values = {\n+     billing: { authorization: ENV['BILLING_TOKEN'] }\n+   }\n",
                           "config/initializers/billing.rb:1\n  # the token of billing\n- ApiRecipes.billing.authorization = ENV['BILLING_TOKEN']\n",
                           "Changed in the project\n  - edited config/initializers/api_recipes.rb\n  - edited config/initializers/billing.rb\n")
    expect(out).to include('Nothing to change')
    expect(out).not_to include('[breaks]', 'Code to paste')
    expect(code).to eq(0)
    expect(File.read('config/initializers/api_recipes.rb')).to eq(<<~RUBY)
      ApiRecipes.configure do |config|
        config.log_level = :info
        config.print_urls = true
        config.values = {
          billing: { authorization: ENV['BILLING_TOKEN'] }
        }
      end
    RUBY
    expect(File.read('config/initializers/billing.rb')).to eq("# the token of billing\n")
  end

  it 'leaves a project that loads and gives the values it gave' do
    project
    upgrade("y\ny\n")
    ENV['BILLING_TOKEN'] = 'Bearer t'
    logger = Logger.new(IO::NULL)
    described = "config.apis_configs = { billing: { host: 'billing.example.test', endpoints: { invoices: nil } } }"
    text = File.read('config/initializers/api_recipes.rb').sub(/config\.log_level = .*$/, described)
    eval(text.sub("  config.print_urls", "  config.logger = logger\n  config.print_urls")) # rubocop:disable Security/Eval
    expect(ApiRecipes.billing.authorization).to eq('Bearer t')
  ensure
    ENV.delete('BILLING_TOKEN')
  end

  it 'makes one change and not the other when the answers differ, and keeps giving the code for the one refused' do
    project
    code, out = upgrade("n\ny\n")
    expect(code).to eq(1)
    expect(File.read('config/initializers/api_recipes.rb')).to include('ApiRecipes.print_urls = true', "billing: { authorization: ENV['BILLING_TOKEN'] }")
    expect(out).to include('config/initializers/api_recipes.rb:7: [breaks] use config.print_urls', 'Code to paste', '1 finding')
    expect(out).not_to include('this writer now raises')
  end

  it 'changes nothing when the answer is not yes: no, nothing, or the end of the input' do
    project
    before = Dir.glob('**/*.rb').to_h { |file| [file, File.read(file)] }
    ["n\nn\n", "\n\n", '', "maybe\nY es\n"].each do |answers|
      code, out = upgrade(answers)
      expect(code).to eq(1)
      expect(out).to include('Make this change? [y/N]', 'Code to paste', '2 findings')
      expect(out).not_to include('Changed in the project')
    end
    expect(Dir.glob('**/*.rb').to_h { |file| [file, File.read(file)] }).to eq(before)
  end

  it 'offers nothing where it cannot write the result by itself, and gives the code as before' do
    project(files.merge('config/initializers/api_recipes.rb' => "#{initializer}ApiRecipes.print_urls = true # for now\n",
                        'config/initializers/billing.rb' => "ApiRecipes.billing.authorization = ENV['BILLING_TOKEN']; puts 'set'\n"))
    code, out = upgrade("y\ny\n")
    expect(code).to eq(1)
    expect(out).not_to include('Make this change?')
    expect(out).to include('Code to paste')
    expect(git('status', '--porcelain')).to eq('')
  end

  it 'offers nothing in a file whose lines end with CR LF, which the change would not keep' do
    project(files.merge('config/initializers/api_recipes.rb' => "#{initializer}ApiRecipes.print_urls = true\n".gsub("\n", "\r\n")))
    code, out = upgrade("y\ny\n")
    expect(out).to include('does not make the change: config/initializers/api_recipes.rb ends its lines with CR LF')
    expect(code).to eq(1)
    expect(git('status', '--porcelain')).to eq('')
  end

  it 'offers nothing for config.values when the block already assigns it, or when two blocks call configure' do
    project(files.merge('config/initializers/api_recipes.rb' => "#{initializer.sub("end\n", "  config.values = { other: {} }\nend\n")}",
                        'config/initializers/billing.rb' => files['config/initializers/billing.rb']))
    expect(upgrade("y\n")[1]).not_to include('Make this change?')
    File.write('config/initializers/other.rb', initializer)
    File.write('config/initializers/api_recipes.rb', "#{initializer}ApiRecipes.print_urls = true\n")
    git('add', '-A')
    git('commit', '-q', '-m', 'two')
    expect(upgrade("y\n")[1]).not_to include('Make this change?')
  end

  describe 'what it leaves to the person, with the code to paste' do
    def offered(startup, initializer_text = initializer)
      project('Gemfile' => "gem 'api_recipes'\n", 'config/initializers/api_recipes.rb' => "#{initializer_text}#{startup}")
      _, out = upgrade("y\ny\ny\n")
      expect(git('status', '--porcelain')).to eq('')
      out
    end

    it 'a line that does more than give the value: a condition, or a constant assigned with it' do
      expect(offered("ENV['DEBUG_URLS'] && ApiRecipes.print_urls = true\n")).not_to include('Make this change?')
      expect(offered("TOKEN = ApiRecipes.github.authorization = ENV.fetch('GITHUB_TOKEN')\n")).not_to include('Make this change?')
    end

    it 'a value that reads a local variable, an instance variable or a method of the file, which the block does not have' do
      expect(offered("token = File.read('/etc/token').strip\nApiRecipes.github.authorization = token\n")).not_to include('Make this change?')
      expect(offered("ApiRecipes.github.authorization = @token\n")).not_to include('Make this change?')
      expect(offered("ApiRecipes.github.authorization = token_from_vault\n")).not_to include('Make this change?')
    end

    it 'a value given after other code that may prepare it, as a require: in the block it would be read before' do
      expect(offered("require 'dotenv/load'\nApiRecipes.github.authorization = ENV['GITHUB_TOKEN']\n")).not_to include('Make this change?')
    end

    it 'two credentials for one api, which configure refuses together' do
      out = offered("ApiRecipes.github.authorization = ENV['A']\nApiRecipes.github.basic_auth = [ENV['U'], ENV['P']]\n")
      expect(out).not_to include('Give the credentials of the application')
    end

    it 'apis_files_paths given with a heredoc, whose lines the change would leave as code' do
      heredoc = "ApiRecipes.configure do |config|\n  config.apis_files_paths = <<~LIST.split\n    config/apis/github.yml\n  LIST\n  config.log_level = :info\nend\n"
      expect(offered('', heredoc)).not_to include('Take apis_files_paths')
    end
  end

  describe 'when it is given what to check' do
    before do
      project(files.merge('config/initializers/api_recipes.rb' => "ApiRecipes.configure do |config|\n  config.apis_files_paths = Dir['config/apis/*.yml']\nend\n",
                          'config/apis/billing.yml' => "billing:\n  host: billing.example.test\n  endpoints:\n    invoices:\n"))
    end

    it 'moves no api to a recipe and does not take apis_files_paths out: what it was given is not the whole project' do
      _, out = upgrade("n\nn\nn\n", 'config/initializers')
      expect(out).to include('Make this change?')
      expect(out).not_to include('Move the api', 'Take apis_files_paths')
      _, out = upgrade("n\nn\nn\n", 'config/initializers', '--config', 'config/apis/billing.yml')
      expect(out).not_to include('Move the api', 'Take apis_files_paths')
      Dir.chdir('config') { expect(upgrade("n\nn\n", 'initializers', '--config', 'apis/billing.yml')[1]).not_to include('Move the api') }
      expect(git('status', '--porcelain')).to eq('')
    end

    it 'offers no change of a rescue in a file that does not name the gem' do
      File.write('lib_job.rb', "begin\n  work\nrescue => e\n  log(e)\nend\n")
      git('add', '-A')
      git('commit', '-q', '-m', 'job')
      expect(upgrade("y\n", 'lib_job.rb')[1]).not_to include('Make this change?')
    end
  end

  it 'reports a description that is not valid UTF-8, given with --config, as away from a terminal' do
    project(files.merge('config/apis/bad.yml' => "bad:\n  host: h\xff\n  endpoints:\n    x:\n"))
    code, out = upgrade("n\nn\n", 'config/initializers', '--config', 'config/apis/bad.yml')
    expect(out).to include('config/apis/bad.yml: [config] file is not valid UTF-8')
    expect(code).to eq(1)
  end

  describe 'for a rescue that names no class' do
    let(:model) do
      <<~RUBY
        class Device
          include ApiRecipes
          api :billing

          def sync
            billing.invoices.run
          rescue => e
            log(e)
          end

          def load
            begin
              billing.invoices.run
            rescue StandardError
              nil
            end
          end
        end
      RUBY
    end

    it 'offers to put before it a rescue of the errors of the gem that raises them again, as 2.x behaved' do
      project('Gemfile' => "gem 'api_recipes'\n", 'app/models/device.rb' => model)
      code, out = upgrade("y\ny\n")
      expect(out).to include('Keep the errors of ApiRecipes out of the rescue at app/models/device.rb:14, as in 2.x',
                             'Keep the errors of ApiRecipes out of the rescue at app/models/device.rb:7, as in 2.x',
                             "In 2.x this rescue did not catch the errors of api_recipes: they went on to the code that called. In 3.0 it catches them.\n" \
                             "  - y: keep what 2.x did. The errors of api_recipes are raised again before this rescue sees them\n" \
                             "  - n: leave the code as it is. This rescue handles the errors of api_recipes too\n",
                             "    billing.invoices.run\n+   rescue ApiRecipes::Error\n+     raise\n    rescue => e\n")
      expect(out).not_to include('[check]')
      expect(code).to eq(0)
      expect(File.read('app/models/device.rb')).to eq(
        model.sub("  rescue => e\n", "  rescue ApiRecipes::Error\n    raise\n  rescue => e\n")
             .sub("    rescue StandardError\n", "    rescue ApiRecipes::Error\n      raise\n    rescue StandardError\n")
      )
      expect(upgrade("y\n")).to match([0, satisfy { |text| !text.include?('Make this change?') && !text.include?('bare rescue now') }])
    end

    it 'asks about each rescue once, and a refused one stays a finding where it is now' do
      project('Gemfile' => "gem 'api_recipes'\n", 'app/models/device.rb' => model)
      code, out = upgrade("n\ny\n")
      expect(out.scan('Make this change?').size).to eq(2)
      expect(code).to eq(1)
      expect(out).to include('app/models/device.rb:16: [check] a bare rescue now catches ApiRecipes errors too', '1 finding')
      expect(File.read('app/models/device.rb')).to eq(model.sub("  rescue => e\n", "  rescue ApiRecipes::Error\n    raise\n  rescue => e\n"))
    end

    it 'offers nothing, and reports nothing, for a bare rescue after one of Exception, which catches the errors first' do
      project('Gemfile' => "gem 'api_recipes'\n",
              'app/models/device.rb' => "class Device\n  include ApiRecipes\n  def sync\n    work\n  rescue Exception\n    nil\n  rescue\n    nil\n  end\nend\n")
      _, out = upgrade("y\n")
      expect(out).not_to include('Make this change?', 'bare rescue now')
    end

    it 'offers it also in a project with no block of configure, and leaves a rescue after a word to the person' do
      project('Gemfile' => "gem 'api_recipes'\n",
              'app/models/device.rb' => "class Device\n  include ApiRecipes\n  api :billing\n  def sync\n    billing.run\n  rescue StandardError, IOError => e\n    nil\n  end\nend\n",
              'lib/job.rb' => "ApiRecipes.billing.invoices.run\nbegin; work; rescue StandardError; end\n")
      _, out = upgrade("n\n")
      expect(out.scan('Make this change?').size).to eq(1)
      expect(out).to include('lib/job.rb:2: [check] a bare rescue now catches', 'the rescue at app/models/device.rb:6, as in 2.x')
    end
  end

  describe 'for a project that still describes its apis in files' do
    let(:old) do
      { 'Gemfile' => "gem 'api_recipes'\n",
        'config/initializers/api_recipes.rb' => "ApiRecipes.configure do |config|\n  config.apis_files_paths = Dir['config/apis/*.yml*']\nend\n",
        'config/apis/billing.yml.erb' => "billing:\n  host: <%= ENV['BILLING_HOST'] || 'billing.example.test' %>\n  endpoints:\n    invoices:\n",
        'config/apis/other.yml' => "other:\n  host: other.example.test\n  endpoints:\n    ping:\n" }
    end

    def descriptions = Dir.glob('config/**/*').select { |file| File.file?(file) && !file.end_with?('.rb') }.sort

    it 'offers to move each api to a portable recipe, shows what it creates, edits and deletes, and does it after a yes' do
      project(old)
      code, out = upgrade("y\ny\n")
      expect(out).to include('Move the api billing to a portable recipe', 'Move the api other to a portable recipe',
                             "config/api_recipes/billing.recipe.yml (new file)\n+ billing:\n+   recipe:\n+     name: billing\n",
                             "config/apis/billing.yml.erb (deleted)\n", '+   config.recipes_paths = ',
                             "+       billing_host: (ENV['BILLING_HOST'] || 'billing.example.test')", '-   config.apis_files_paths = ',
                             'billing 1.0.0 now comes from a portable recipe', 'other 1.0.0 now comes from a portable recipe',
                             "Changed in the project\n  - created config/api_recipes/billing.recipe.yml\n  - created config/api_recipes/recipes.lock\n" \
                             "  - edited config/initializers/api_recipes.rb\n" \
                             "  - deleted config/apis/billing.yml.erb\n  - created config/api_recipes/other.recipe.yml\n  - deleted config/apis/other.yml\n",
                             'Nothing to change')
      expect(out).not_to include('[breaks]')
      expect(code).to eq(0)
      expect(descriptions).to eq(%w[config/api_recipes/billing.recipe.yml config/api_recipes/other.recipe.yml config/api_recipes/recipes.lock])
      expect(File.read('config/initializers/api_recipes.rb')).not_to include('apis_files_paths')
      expect(ApiRecipes::CLI.run(['check'], out: StringIO.new, err: StringIO.new)).to eq(0)
      expect(upgrade("y\n")).to match([0, satisfy { |text| !text.include?('Make this change?') }])
    end

    it 'leaves an api where it is when the answer is no, and says that convert moves it' do
      project(old)
      code, out = upgrade("n\ny\n")
      expect(code).to eq(1)
      expect(descriptions).to eq(%w[config/api_recipes/other.recipe.yml config/api_recipes/recipes.lock config/apis/billing.yml.erb])
      expect(out).to include('config/apis/billing.yml.erb: [breaks] describes an api in a file of the project, which 3.0 no longer loads',
                             '1. Run `api_recipes convert`: it moves the description of the project to portable recipes')
      expect(File.read('config/initializers/api_recipes.rb')).to include('apis_files_paths', 'recipes_paths')
    end

    it 'offers nothing for a description it cannot convert by itself: it stays a finding' do
      project(old.merge('config/apis/other.yml' => "<% if ENV['X'] %>\nother:\n  host: other.example.test\n<% end %>\n"))
      code, out = upgrade("n\n")
      expect(out.scan('Make this change?').size).to eq(1)
      expect(out).to include('Move the api billing to a portable recipe')
      expect(out).not_to include('Move the api other')
      expect(code).to eq(1)
    end

    it 'takes apis_files_paths out of the block of configure when no file describes an api any more' do
      project('Gemfile' => "gem 'api_recipes'\n",
              'config/initializers/api_recipes.rb' => "ApiRecipes.configure do |config|\n  config.apis_files_paths = [\n    'config/apis/gone.yml'\n  ]\n  config.print_urls = false\nend\n")
      code, out = upgrade("y\n")
      expect(out).to include('Take apis_files_paths, which 3.0 refuses, out of the block of ApiRecipes.configure',
                             "-   config.apis_files_paths = [\n-     'config/apis/gone.yml'\n-   ]\n")
      expect(code).to eq(0)
      expect(File.read('config/initializers/api_recipes.rb')).to eq("ApiRecipes.configure do |config|\n  config.print_urls = false\nend\n")
    end
  end

  describe ApiRecipes::CLI::Upgrade::Diff do
    it 'gives the lines taken out and added with the lines around them, in parts that say where they start' do
      old = (1..20).map { |number| "line #{number}\n" }.join
      new = old.sub("line 3\n", "line three\n").sub("line 15\n", '').sub("line 20\n", "line 20\nline 21\n")
      expect(described_class.hunks(old, new, context: 1)).to eq(
        [[2, [[' ', 'line 2'], ['-', 'line 3'], ['+', 'line three'], [' ', 'line 4']]],
         [14, [[' ', 'line 14'], ['-', 'line 15'], [' ', 'line 16']]],
         [20, [[' ', 'line 20'], ['+', 'line 21']]]]
      )
      expect(described_class.hunks(old, old)).to eq([])
    end

    it 'does not compare line by line two texts too long for it' do
      old = (1..700).map { |number| "old #{number}\n" }.join
      new = (1..700).map { |number| "new #{number}\n" }.join
      signs = described_class.hunks(old, new).flat_map { |_, lines| lines.map(&:first) }
      expect(signs.tally).to eq('-' => 700, '+' => 700)
    end
  end
end
