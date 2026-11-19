require 'spec_helper'
require 'api_recipes/cli'
require 'stringio'
require 'tmpdir'
require 'fileutils'

# What `api_recipes upgrade` shows: the same sections everywhere, with colours,
# marks and lines that fit on a terminal, and at the end what to do.
describe 'api_recipes upgrade, what it shows' do
  around do |example|
    Dir.mktmpdir do |dir|
      Dir.chdir(File.realpath(dir)) { example.run }
    end
  end

  let(:files) do
    { 'Gemfile' => "gem 'api_recipes'\n",
      'app/models/device.rb' => "class Device\n  include ApiRecipes\n  api :billing\n  def sync\n    billing.invoices.run\n  rescue\n    nil\n  end\nend\n",
      'config/initializers/api_recipes.rb' => "ApiRecipes.configure do |config|\n  config.apis_files_paths = Dir['config/apis/*.yml']\nend\n" \
                                              "ApiRecipes.print_urls = true\n",
      'config/apis/billing.yml' => "billing:\n  host: billing.example.test\n  hots: x\n  endpoints:\n    invoices:\n" }
  end

  def project(files)
    files.each do |path, text|
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text)
    end
  end

  def terminal(width = 100)
    StringIO.new.tap do |out|
      out.define_singleton_method(:tty?) { true }
      out.define_singleton_method(:winsize) { [40, width] }
    end
  end

  def run(out = StringIO.new, *arguments)
    [ApiRecipes::CLI.run(['upgrade', *arguments], out: out, err: StringIO.new), out.string]
  end

  def plain(text) = text.gsub(/\e\[[0-9;]*m/, '')

  it 'puts last what needs an answer: what was checked, what it cannot find, the findings, how many, what to do' do
    project(files)
    code, out = run
    expect(code).to eq(1)
    places = ['Checked 2 Ruby files', 'What this command cannot find', 'app/models/device.rb:6: [check]', 'Code to paste',
              "\n5 findings\n", 'What to do now'].map { |text| out.index(text) }
    expect(places).to eq(places.compact.sort)
    expect(out).not_to match(/\e|\n\n\n/)
  end

  it 'ends with what to do, a step for each kind of finding that there is' do
    project(files)
    steps = run[1][/What to do now\n(.*)\z/m, 1].lines.map(&:strip)
    expect(steps).to match([/\A1\. Run `api_recipes convert`: it moves the description of the project to portable recipes/,
                            /\A2\. Fix the 1 line marked breaks that convert does not take care of: .*The code to paste, above/,
                            /\A3\. Correct what is marked config \(1\)/, /\A4\. Read the 1 line marked check: .*reported at every run/,
                            /\A5\. Go through what this command cannot find/, /\A6\. Run this command again/,
                            /\A7\. Start the application and run its tests: ApiRecipes\.configure checks/])
  end

  it 'asks to run it again only when something has to change, and never to fix what is not there' do
    project(files.slice('Gemfile', 'app/models/device.rb'))
    code, out = run
    steps = out[/What to do now\n(.*)\z/m, 1].lines.map(&:strip)
    expect(code).to eq(1)
    expect(steps).to match([/\A1\. Read the 1 line marked check/, /\A2\. Go through what this command cannot find/, /\A3\. Start the application/])

    File.write('app/models/device.rb', "class Device\n  include ApiRecipes\n  api :billing\nend\n")
    code, out = run
    expect(code).to eq(0)
    expect(out).to include('Nothing to change')
    expect(out[/What to do now\n(.*)\z/m, 1].lines.map(&:strip)).to match([/\A1\. Go through what/, /\A2\. Start the application/])
  end

  describe 'on a terminal' do
    it 'shows the same results, in sections with a mark, with the kind of each finding in its colour' do
      project(files)
      code, out = run(terminal)
      expect(code).to eq(1)
      expect(out).to include("🔎 \e[1mWhat was checked\e[0m", "🙈 \e[1mWhat this command cannot find\e[0m", "📌 \e[1mFindings\e[0m",
                             "📋 \e[1mCode to paste\e[0m", "👉 \e[1mWhat to do now\e[0m",
                             "   👀 \e[1;33mcheck \e[0m  \e[1mapp/models/device.rb:6\e[0m\n      a bare rescue now catches ApiRecipes errors too\n",
                             "   💥 \e[1;31mbreaks\e[0m  \e[1mconfig/initializers/api_recipes.rb:4\e[0m\n",
                             "   🧩 \e[1;35mconfig\e[0m  \e[1mconfig/apis/billing.yml\e[0m\n      billing: unknown option 'hots'\n",
                             "💥 \e[1;31m5 findings\e[0m  \e[31m3 breaks\e[0m\e[2m · \e[0m\e[35m1 config\e[0m\e[2m · \e[0m\e[33m1 check\e[0m\n")
      expect(plain(out)).to include("      config.print_urls = true\n", "   1. Run `api_recipes convert`: it moves the description of the project")
      expect(plain(out)).to include("   • #{ApiRecipes::CLI::Upgrade::SILENT_CHANGES[2]}\n", '🙈 What this command cannot find  12 changes')
    end

    it 'says in green that there is nothing to change' do
      project(files.slice('Gemfile'))
      File.write('client.rb', "ApiRecipes.github.users.run\n")
      code, out = run(terminal)
      expect(code).to eq(0)
      expect(out).to include("✅ \e[1;32mNothing to change in the Ruby files.")
      expect(out).not_to include('📌', '📋')
    end

    it 'keeps every line within the width of the terminal, and within 110 columns on a wider one' do
      project(files)
      [60, 80, 110, 300].each do |width|
        lines = plain(run(terminal(width))[1]).lines.map(&:chomp)
        expect(lines.map(&:length).max).to be <= [width, 110].min
        expect(lines.join(' ').squeeze(' ')).to include(ApiRecipes::CLI::Upgrade::SILENT_CHANGES.max_by(&:length))
      end
    end

    it 'never leaves two empty lines, and writes no colours with NO_COLOR or away from a terminal' do
      project(files)
      expect(run(terminal)[1]).not_to include("\n\n\n")
      ENV['NO_COLOR'] = '1'
      expect(run(terminal)[1]).to eq(run[1])
      expect(run[1]).not_to match(/\e|🔎|💥|👉/)
    ensure
      ENV.delete('NO_COLOR')
    end
  end
end
