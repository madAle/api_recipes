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

  let(:initializer) { "ApiRecipes.configure do |config|\n  config.apis_files_paths = Dir['config/apis/*.yml']\nend\n" }
  let(:files) do
    { 'Gemfile' => "gem 'api_recipes'\n",
      'config/initializers/api_recipes.rb' => "#{initializer}ApiRecipes.print_urls = true\n",
      'config/initializers/billing.rb' => "# the token of billing\nApiRecipes.billing.authorization = ENV['BILLING_TOKEN']\n",
      'config/apis/billing.yml' => "billing:\n  host: billing.example.test\n  endpoints:\n    invoices:\n" }
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

  # Runs upgrade with these answers typed on a terminal; nil for no terminal.
  def upgrade(answers, *arguments)
    out = StringIO.new
    input = StringIO.new(answers.to_s)
    input.define_singleton_method(:tty?) { true } if answers
    [ApiRecipes::CLI.run(['upgrade', *arguments], out: out, err: out, input: input), out.string]
  end

  it 'shows each change as a diff and makes the ones answered with yes, then says what it changed' do
    project
    code, out = upgrade("y\nyes\n")
    expect(out).to include("Move print_urls into the block of ApiRecipes.configure\n\nconfig/initializers/api_recipes.rb:1\n" \
                           "  ApiRecipes.configure do |config|\n    config.apis_files_paths = Dir['config/apis/*.yml']\n" \
                           "+   config.print_urls = true\n  end\n- ApiRecipes.print_urls = true\n\nMake this change? [y/N] ")
    expect(out).to include("+   config.values = {\n+     billing: { authorization: ENV['BILLING_TOKEN'] }\n+   }\n",
                           "config/initializers/billing.rb:1\n  # the token of billing\n- ApiRecipes.billing.authorization = ENV['BILLING_TOKEN']\n",
                           "Changed in the project\n  - edited config/initializers/api_recipes.rb\n  - edited config/initializers/billing.rb\n",
                           'Nothing to change')
    expect(out).not_to include('[breaks]', 'Code to paste')
    expect(code).to eq(0)
    expect(File.read('config/initializers/api_recipes.rb')).to eq(<<~RUBY)
      ApiRecipes.configure do |config|
        config.apis_files_paths = Dir['config/apis/*.yml']
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
    eval(File.read('config/initializers/api_recipes.rb').sub("  config.print_urls", "  config.logger = logger\n  config.print_urls")) # rubocop:disable Security/Eval
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

    it 'offers it also in a project with no block of configure, and leaves a rescue after a word to the person' do
      project('Gemfile' => "gem 'api_recipes'\n",
              'app/models/device.rb' => "class Device\n  include ApiRecipes\n  api :billing\n  def sync\n    billing.run\n  rescue StandardError, IOError => e\n    nil\n  end\nend\n",
              'lib/job.rb' => "ApiRecipes.billing.invoices.run\nbegin; work; rescue StandardError; end\n")
      _, out = upgrade("n\n")
      expect(out.scan('Make this change?').size).to eq(1)
      expect(out).to include('lib/job.rb:2: [check] a bare rescue now catches', 'the rescue at app/models/device.rb:6, as in 2.x')
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
