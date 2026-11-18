require 'spec_helper'
require 'api_recipes/cli'
require 'stringio'
require 'tmpdir'

# The changes of 3.0 that `upgrade` finds by reading the Ruby of a file as a
# tree, and the description of an api as data: a line alone does not tell them.
describe 'api_recipes upgrade, what it finds by reading the code' do
  around do |example|
    Dir.mktmpdir do |dir|
      Dir.chdir(File.realpath(dir)) { example.run }
    end
  end

  # The findings for one Ruby file, as "line: [kind] start of the message".
  def findings(ruby, name = 'client.rb')
    File.write(name, ruby)
    out = StringIO.new
    ApiRecipes::CLI.run(['upgrade', '--no-code', name], out: out, err: StringIO.new)
    out.string.lines.grep(/\A#{Regexp.escape(name)}:\d+: \[/).map { |line| line.delete_prefix("#{name}:")[0, 44].strip }
  end

  def config_findings(yaml)
    File.write('billing.yml', yaml)
    out = StringIO.new
    ApiRecipes::CLI.run(['upgrade', '--config', 'billing.yml'], out: out, err: StringIO.new)
    out.string.lines.grep(/\Abilling\.yml: \[/).map { |line| line.delete_prefix('billing.yml: ').strip }
  end

  it 'finds a credential assigned in the body of a class, through a variable, over two lines and with send' do
    found = findings(<<~RUBY)
      class Client
        include ApiRecipes
        api :github
        github.authorization = ENV['TOKEN']
      end
      api = ApiRecipes.github
      api.basic_auth = { user: 'u', pass: 'p' }
      Client.github.
        authorization = token
      Client.github.public_send(:authorization=, token)
      request.send(:host=, 'x')
    RUBY
    expect(found).to eq(['4: [check] authorization= and basic_auth= no',
                         '7: [check] authorization= and basic_auth= no',
                         '8: [check] authorization= and basic_auth= no',
                         '10: [check] authorization= and basic_auth= n'])
  end

  it 'does not say twice a writer that a rule on lines found, and says a credential that is not text' do
    found = findings("ApiRecipes.github.authorization = :token\nclient.github.authorization = 123\nclient.github.with(authorization: 'x')\n" \
                     "class A\n  include ApiRecipes\n  api :github, authorization: :token\nend\n")
    expect(found).to eq(['1: [breaks] a credential of the whole applic', '1: [breaks] a credential must be a String: a',
                         '2: [check] authorization= and basic_auth= no', '2: [breaks] a credential must be a String: a',
                         '6: [breaks] a credential must be a String: a'])
  end

  it 'finds an api whose name is already a method, and a class with an address of its own and no credential' do
    found = findings(<<~RUBY)
      class Client
        include ApiRecipes
        api :format
        api :open, as: :opened
        api :github
        api :billing, host: 'billing.internal', port: 8443
        api :shop, host: 'shop.internal', authorization: ENV['SHOP']
      end
    RUBY
    expect(found).to eq(['3: [breaks] api :format raises ApiNameClashE',
                         '6: [check] this class gives the api its own'])
  end

  it 'finds apis_configs assigned after the files' do
    ruby = "ApiRecipes.configure do |config|\n  config.apis_files_paths = ['a.yml']\n  config.apis_configs = { b: {} }\nend\n"
    expect(findings(ruby)).to eq(['3: [check] apis_configs assigned after apis_'])
    expect(findings(ruby.sub("  config.apis_files_paths = ['a.yml']\n", ''))).to eq([])
  end

  it 'finds a block passed to run whose value is used, and not one whose value is dropped' do
    found = findings(<<~RUBY)
      names = ApiRecipes.github.users.run { |response| response.data.map(&:name) }
      ApiRecipes.github.users.run { |response| save(response.data) }
      show(ApiRecipes.github.users.run { |response| response.data })
      ApiRecipes.github.users.run { |response| response.data }.size
      total = ApiRecipes.github.users.run.data.size
    RUBY
    expect(found).to eq(['1: [check] run with a block now returns the',
                         '3: [check] run with a block now returns the',
                         '4: [check] run with a block now returns the'])
  end

  it 'finds request, to_s and respond_to? on what run returned, whatever the name of the variable' do
    found = findings(<<~RUBY)
      res = ApiRecipes.github.users.run
      log(res.request)
      puts res.to_s
      @last = ApiRecipes.github.users.show(1).run
      @last.respond_to?(:code)
      ApiRecipes.github.users.run { |answer| answer.request }
      other = build
      other.request
      other.to_s
    RUBY
    expect(found).to eq(['2: [check] request was removed from the resp',
                         '3: [check] to_s on a response now returns th',
                         '5: [check] respond_to? on a response now tel',
                         '6: [check] request was removed from the resp'])
  end

  it 'finds a constant of the gem written alone in a class that includes ApiRecipes, unless the class defines it' do
    found = findings(<<~RUBY)
      class Client
        include ApiRecipes
        api :github

        def call
          github.users.run
        rescue Error, ::Error, MyApp::Error => e
          raise ConfigurationError, VERSION
        end
      end

      class Other
        include ApiRecipes
        Error = Class.new(StandardError)
        class ConfigurationError < StandardError; end

        def call = raise(Error, ConfigurationError.name)
        class Inner
          def call = Internals
        end
      end

      class Plain
        def call = [Error, VERSION]
      end
    RUBY
    expect(found).to eq(['7: [check] Error written alone in a class th',
                         '8: [check] ConfigurationError written alone',
                         '8: [check] VERSION written alone in a class'])
  end

  it 'applies the rules that also match other code only to a file of a project that uses the gem' do
    File.write('Gemfile', "gem 'api_recipes'\n")
    FileUtils.mkdir_p('app')
    File.write('app/report.rb', "result = job.run { |step| step.name }\nmailer.authorization = token\nresult.to_s\n")
    out = StringIO.new
    expect(ApiRecipes::CLI.run(['upgrade'], out: out, err: StringIO.new)).to eq(0)
    expect(out.string).to include('Nothing to change')
  end

  it 'reads a file that is not valid Ruby with the rules on lines only' do
    expect(findings("class Client\n  github.authorization = 1\n")).to eq([])
  end

  describe 'in the description of an api' do
    let(:yaml) do
      <<~YAML
        billing:
          host: billing.example.test
          timeout: 5
          endpoints:
            reports:
              timeout: 60
              on_bad_code: ignore
              endpoints:
                monthly:
                export:
                  timeout: 300
            invoices:
              timeout: 9
            with:
            users:
              endpoints:
                url:
                  path: /address
      YAML
    end

    it 'finds an option that the endpoints inside now find before the one of the api' do
      expect(config_findings(yaml)).to include(
        '[check] billing.endpoints.reports: timeout is set here, and the endpoints it contains that do not set it now find it here ' \
        '(monthly): in 2.x they took the one of the api',
        '[check] billing.endpoints.reports: on_bad_code is set here, and the endpoints it contains that do not set it now find it here ' \
        '(monthly, export): in 2.x they took the one of the api'
      )
      expect(config_findings(yaml).join).not_to include('invoices')
    end

    it 'finds an endpoint that has no method of its own' do
      found = config_findings(yaml)
      expect(found).to include(match(/\A\[check\] billing\.endpoints\.with: an endpoint with this name has no method of its own.*reach it with \[:with\]/),
                               match(/\A\[check\] billing\.endpoints\.users\.endpoints\.url: .*reach it with \[:url\]/))
      expect(found.size).to eq(4)
    end

    it 'says nothing of a portable recipe, which is written for 3.0' do
      File.write('billing.recipe.yml', yaml.sub("  host:", "  recipe:\n    name: billing\n    version: 1.0.0\n    format: 1\n  host:"))
      out = StringIO.new
      ApiRecipes::CLI.run(['upgrade', '--config', 'billing.recipe.yml'], out: out, err: StringIO.new)
      expect(out.string).not_to include('[check]')
    end
  end
end
