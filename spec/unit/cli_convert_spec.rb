require 'spec_helper'
require 'api_recipes/cli'
require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'yaml'

# `api_recipes convert FILE`: from a configuration file of a project to a
# portable recipe, without running anything in the file.
describe 'api_recipes convert' do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = File.realpath(dir)
      Dir.chdir(@dir) { example.run }
    end
  end

  let(:plain) do
    <<~YAML
      billing:
        host: billing.example.test
        base_url: api/v1
        timeout: 5
        default_headers:
          Accept: application/json
        endpoints:
          invoices:
            endpoints:
              show:
                path: /:id
              create:
                path: ''
                verb: post
                ok_code: [201, 202]
          reports:
            route: no
            endpoints:
              monthly:
    YAML
  end

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    path
  end

  def run(*argv)
    out = StringIO.new
    err = StringIO.new
    [ApiRecipes::CLI.run(argv, out: out, err: err), out.string, err.string]
  end

  def recipe(path = 'billing.recipe.yml') = YAML.safe_load(File.read(path)).values.first

  def calls(path)
    out = StringIO.new
    ApiRecipes::CLI.run(['routes', path], out: out, err: StringIO.new)
    out.string.lines.map { |line| line.split.first(2) }
  end

  it 'writes NAME.recipe.yml with the key recipe and the same calls' do
    write('config/apis/billing.yml', plain)
    code, out, err = run('convert', 'config/apis/billing.yml')
    expect(err).to eq('')
    expect(code).to eq(0)
    expect(out).to include('billing 1.0.0 is written in billing.recipe.yml: 4 calls')
    expect(recipe['recipe']).to eq('name' => 'billing', 'version' => '1.0.0', 'format' => 1)
    expect(recipe.keys.first).to eq('recipe')
    expect(recipe['endpoints']['invoices']['endpoints']['create']).to eq('path' => '', 'verb' => 'post', 'ok_code' => [201, 202])
    expect(recipe['endpoints']['reports']['route']).to be(false)
    expect(calls('billing.recipe.yml')).to eq(calls('config/apis/billing.yml'))
    expect(run('check', 'billing.recipe.yml').first).to eq(0)
  end

  it 'takes the version and the folder it is told' do
    write('billing.yml', plain)
    code, out, = run('convert', '--version', '2.1', '--to', 'cookbook/recipes', 'billing.yml')
    expect(code).to eq(0)
    expect(out).to include('billing 2.1 is written in cookbook/recipes/billing.recipe.yml')
    expect(recipe('cookbook/recipes/billing.recipe.yml')['recipe']['version']).to eq('2.1')
  end

  it 'never replaces a file' do
    write('billing.yml', plain)
    write('billing.recipe.yml', 'mine')
    code, _, err = run('convert', 'billing.yml')
    expect(code).to eq(2)
    expect(err).to include('billing.recipe.yml already exists')
    expect(File.read('billing.recipe.yml')).to eq('mine')
  end

  it 'asks which api when the file describes several, and takes the one of --name' do
    write('apis.yml', plain + "github:\n  host: api.github.test\n  endpoints:\n    users:\n")
    code, _, err = run('convert', 'apis.yml')
    expect(code).to eq(2)
    expect(err).to include('describes 2 apis (billing, github): choose one with --name')
    expect(run('convert', '--name', 'github', 'apis.yml').first).to eq(0)
    expect(recipe('github.recipe.yml')['host']).to eq('api.github.test')
    expect(run('convert', '--name', 'nope', 'apis.yml')).to match([2, '', /does not describe an api called nope/])
  end

  it 'writes out what anchors, aliases and merge keys stand for' do
    write('billing.yml', <<~YAML)
      billing:
        host: billing.example.test
        endpoints:
          invoices: &paged
            default_params:
              per_page: 50
          customers:
            <<: *paged
    YAML
    expect(run('convert', 'billing.yml').first).to eq(0)
    expect(File.read('billing.recipe.yml')).not_to match(/[&*]paged|<</)
    expect(recipe['endpoints']['customers']).to eq('default_params' => { 'per_page' => 50 })
  end

  describe 'ERB' do
    let(:with_erb) do
      <<~YAML
        billing:
          host: <%= ENV.fetch('BILLING_HOST', 'billing.example.test') %>
          port: <%= ENV['BILLING_PORT'] %>
          protocol: <%= ENV.fetch("BILLING_PROTOCOL", "http") %>
          timeout: <%= ENV.fetch('BILLING_TIMEOUT', 7) %>
          base_url: api/<%= Rails.application.config.x.billing_version %>
          default_headers:
            Accept: application/json
            X-Tenant: "<%= ENV['TENANT'] %>"
          endpoints:
            invoices:
              path: /<%= ENV['TENANT'] %>/invoices
      YAML
    end

    it 'becomes a variable where a recipe can have one, named after the environment variable' do
      write('billing.yml.erb', with_erb)
      code, out, = run('convert', 'billing.yml.erb')
      expect(code).to eq(0)
      expect(recipe['host']).to eq('{billing_host}')
      expect(recipe['base_url']).to eq('api/{base_url}')
      expect(recipe['default_headers']).to eq('Accept' => 'application/json', 'X-Tenant' => '{tenant}')
      expect(recipe['endpoints']['invoices']['path']).to eq('/{tenant}/invoices')
      expect(recipe['variables']).to include('billing_host' => { 'default' => 'billing.example.test' }, 'base_url' => {}, 'tenant' => {})
      expect(out).to include('host: the ERB tag is now the variable {billing_host}, with the default written in the tag',
                             'base_url: the ERB tag is now the variable {base_url}',
                             'default_headers.X-Tenant: the ERB tag is now the variable {tenant}')
    end

    it 'becomes a variable in the protocol, in the port and in the other options of a request too' do
      write('billing.yml.erb', with_erb)
      _, out, = run('convert', '--to', '.', 'billing.yml.erb')
      expect(recipe.values_at('protocol', 'port', 'timeout')).to eq(['{billing_protocol}', '{billing_port}', '{billing_timeout}'])
      expect(recipe['variables']).to include('billing_protocol' => { 'default' => 'http' }, 'billing_port' => {},
                                             'billing_timeout' => { 'default' => '7' })
      expect(out).to include('protocol: the ERB tag is now the variable {billing_protocol}, with the default written in the tag',
                             'port: the ERB tag is now the variable {billing_port}')
    end

    it 'reads the default written after ||' do
      write('billing.yml', plain.sub('billing.example.test', "<%= ENV['BILLING_HOST'] || 'billing.example.test' %>").sub('timeout: 5', "timeout: <%= ENV['T'] || 5 %>"))
      run('convert', '--to', '.', 'billing.yml')
      expect(recipe['variables']).to eq('billing_host' => { 'default' => 'billing.example.test' }, 't' => { 'default' => '5' })
    end

    it 'says what to give in the application, by the names of the environment variables' do
      write('billing.yml.erb', with_erb)
      _, out, = run('convert', '--to', '.', 'billing.yml.erb')
      expect(out).to include(<<~TEXT)
        In the file that calls ApiRecipes.configure, inside its block:

            config.recipes_paths = Dir['config/api_recipes/*.recipe.yml']
            config.values = {
              billing: { variables: {
                billing_host: (ENV.fetch('BILLING_HOST', 'billing.example.test')),
                billing_port: ENV['BILLING_PORT'],
                billing_protocol: (ENV.fetch("BILLING_PROTOCOL", "http")),
                billing_timeout: (ENV.fetch('BILLING_TIMEOUT', 7)),
                base_url: (Rails.application.config.x.billing_version),
                tenant: ENV['TENANT']
              }.compact }
            }

        Variables that have a default in the recipe: billing_host, billing_protocol, billing_timeout. .compact leaves out the ones whose code gives nil.
      TEXT
    end

    it 'leaves to the application a default of a variable that a tag gave' do
      write('billing.yml', plain.sub("  timeout: 5\n", "  timeout: 5\n  variables:\n    region:\n      default: <%= ENV.fetch('REGION', 'eu') %>\n      description: where\n").sub('billing.example.test', "'{region}.example.test'"))
      code, out, = run('convert', '--to', '.', 'billing.yml')
      expect(code).to eq(0)
      expect(recipe['variables']).to eq('region' => { 'description' => 'where' })
      expect(out).to include('variables.region.default: came from an ERB tag: the application gives the variable from now on',
                             "        region: (ENV.fetch('REGION', 'eu'))\n")
    end

    it 'refuses a tag that gives a part of an option that only a whole variable can give' do
      write('billing.yml', plain.sub('timeout: 5', "timeout: 1<%= ENV['T'] %>"))
      code, _, err = run('convert', '--to', '.', 'billing.yml')
      expect(code).to eq(1)
      expect(err).to include('timeout: an ERB tag gives a part of the value')
    end

    it 'is never run' do
      marker = File.join(@dir, 'marker')
      write('billing.yml', plain.sub('billing.example.test', "<%= File.write(#{marker.inspect}, '1'); 'h.test' %>"))
      expect(run('convert', 'billing.yml').first).to eq(0)
      expect(File.exist?(marker)).to be(false)
      expect(recipe['host']).to eq('{host}')
    end

    it 'has no option to run it' do
      write('billing.yml', plain)
      expect(run('convert', '--erb', 'billing.yml')).to match([2, '', /--erb/])
      expect(File.exist?('billing.recipe.yml')).to be(false)
    end

    it 'refuses a tag that decides the structure of the file, and says where' do
      write('billing.yml', plain.sub("  timeout: 5\n", "<% if ENV['SLOW'] %>\n  timeout: 5\n<% end %>\n"))
      code, out, err = run('convert', 'billing.yml')
      expect(code).to eq(1)
      expect(out).to eq('')
      expect(err).to include('billing.yml:4: an ERB tag that is not <%= ... %> decides the structure of the file',
                             'billing.yml:6: an ERB tag')
      expect(File.exist?('billing.recipe.yml')).to be(false)
    end

    it 'refuses a tag that gives the name of an option' do
      write('billing.yml', plain.sub('invoices:', "<%= ENV['NAME'] %>:"))
      code, _, err = run('convert', 'billing.yml')
      expect(code).to eq(1)
      expect(err).to include('billing.yml:8: an ERB tag gives a name')
    end
  end

  describe 'what looks like a credential' do
    let(:with_secrets) do
      plain.sub("    Accept: application/json\n", <<~YAML.gsub(/^/, '    '))
        Accept: application/json
        Api-Key-Client: <%= ENV.fetch('CLIENT', 'default-client-secret') %>
        Api-Key-Secret: literal-secret-value
        Authorization: Bearer literal-token-value
      YAML
    end

    it 'is never copied: a header or a parameter named like one becomes a variable without a default' do
      write('billing.yml', with_secrets.sub("  timeout: 5\n", "  timeout: 5\n  default_params:\n    api_token: literal-param-secret\n    page: 1\n"))
      code, out, err = run('convert', 'billing.yml')
      expect(code).to eq(0)
      text = File.read('billing.recipe.yml')
      listed = out[/What changed.*?(?=\n\nIn the file)/m]
      expect(text + listed + err).not_to match(/literal-secret-value|literal-token-value|literal-param-secret|default-client-secret/)
      expect(out).to include('api_key_secret: "literal-secret-value",', "client: (ENV.fetch('CLIENT', 'default-client-secret')),")
      expect(recipe['default_headers']).to eq('Accept' => 'application/json', 'Api-Key-Client' => '{client}',
                                              'Api-Key-Secret' => '{api_key_secret}', 'Authorization' => '{authorization}')
      expect(recipe['default_params']).to eq('api_token' => '{api_token}', 'page' => 1)
      expect(recipe['variables']).to eq('api_token' => {}, 'client' => {}, 'api_key_secret' => {}, 'authorization' => {})
      expect(out).to include('default_headers.Api-Key-Secret: looks like a credential: its value is not copied, it is now the variable {api_key_secret}')
    end
  end

  it 'leaves verify_with out and says where it goes' do
    write('billing.yml', plain.sub("  timeout: 5\n", "  timeout: 5\n  verify_with: expected_response?\n").sub("        monthly:\n", "        monthly:\n          verify_with: monthly_ok?\n"))
    code, out, = run('convert', 'billing.yml')
    expect(code).to eq(0)
    expect(File.read('billing.recipe.yml')).not_to include('verify_with')
    expect(out).to include('verify_with: left out, a recipe cannot carry it: give it where a class declares the api, as `api :billing, verify_with: ...`',
                           'endpoints.reports.endpoints.monthly.verify_with: left out')
    expect(out).not_to include('expected_response?', 'monthly_ok?')
  end

  describe 'a file that cannot become a recipe' do
    it 'is reported with the problems of the result, and nothing is written' do
      write('billing.yml', plain.sub('host: billing.example.test', "hots: billing.example.test\n  on_bad_code: explode"))
      code, out, err = run('convert', 'billing.yml')
      expect(code).to eq(1)
      expect(out).to eq('')
      expect(err).to include('billing.yml cannot become a portable recipe', 'host is required')
      expect(Dir['*.recipe.yml']).to eq([])
    end

    it 'is refused for a name that a recipe cannot have' do
      write('apis.yml', plain.sub('billing:', 'BillingApi:'))
      code, _, err = run('convert', 'apis.yml')
      expect(code).to eq(1)
      expect(err).to include('lowercase letters, digits, - and _')
    end

    it 'is refused when it already is one' do
      write('billing.recipe.yml', plain)
      expect(run('convert', 'billing.recipe.yml')).to match([2, '', /is already called \.recipe\.yml/])
    end

    it 'is reported when it is missing, empty, not YAML, not text or not a mapping' do
      expect(run('convert', 'missing.yml')).to match([2, '', /missing\.yml: no such file/])
      expect(run('convert', write('empty.yml', ''))).to match([1, '', /empty\.yml: does not describe an api/])
      expect(run('convert', write('list.yml', "- 1\n"))).to match([1, '', /list\.yml: does not describe an api/])
      expect(run('convert', write('broken.yml', "billing: [\n"))).to match([1, '', /broken\.yml: is not valid YAML/])
      expect(run('convert', write('binary.yml', "billing:\0"))).to match([1, '', /binary\.yml: is not text/])
    end
  end

  describe 'with --calls' do
    it 'writes beside each endpoint how it is called, and the same recipe' do
      write('billing.yml', plain)
      expect(run('convert', '--to', 'plain', 'billing.yml').first).to eq(0)
      expect(run('convert', '--calls', '--to', '.', 'billing.yml')).to match([0, /billing 1\.0\.0 is written in billing\.recipe\.yml: 4 calls/, ''])
      text = File.read('billing.recipe.yml')
      expect(YAML.safe_load(text)).to eq(YAML.safe_load(File.read('plain/billing.recipe.yml')))
      expect(File.read('plain/billing.recipe.yml')).not_to include('#')
      expect(text.lines.grep(/#/).map { |line| line.strip.squeeze(' ') })
        .to eq(['invoices: # .invoices', 'show: # .invoices.show(id)', 'create: # .invoices.create', 'monthly: # .reports.monthly'])
      expect(text.lines.grep(/#/).map { |line| line.index('#') }.uniq).to eq([34])
      expect(run('check', 'billing.recipe.yml').first).to eq(0)
    end

    it 'writes a call only beside an endpoint: not beside a header or a parameter with its name' do
      write('billing.yml', <<~YAML)
        billing:
          host: billing.example.test
          default_headers:
            invoices: all
          default_params:
            endpoints: some
          endpoints:
            invoices:
              default_params:
                show: 1
                endpoints: 2
              endpoints:
                show:
                  path: /:id
      YAML
      expect(run('convert', '--calls', '--to', '.', 'billing.yml').first).to eq(0)
      expect(File.read('billing.recipe.yml').lines.grep(/#/).map { |line| line.strip.squeeze(' ') })
        .to eq(['invoices: # .invoices', 'show: # .invoices.show(id)'])
    end

    it 'writes them in the recipe it installs in a project too' do
      write('Gemfile', "gem 'api_recipes'\n")
      write('config/apis/billing.yml', plain)
      write('config/initializers/api_recipes.rb', "ApiRecipes.configure do |config|\n  config.apis_files_paths = Dir['config/apis/*.yml']\nend\n")
      system('git', 'init', '-q', '.', exception: true)
      system('git', 'add', '.', exception: true)
      system('git', '-c', 'user.name=spec', '-c', 'user.email=spec@example.test', 'commit', '-q', '-m', 'Start', exception: true)
      expect(run('convert', '--calls', 'config/apis/billing.yml').first).to eq(0)
      expect(File.read('config/api_recipes/billing.recipe.yml')).to match(/show: +# \.invoices\.show\(id\)\n/)
      expect(run('check', 'config/api_recipes/billing.recipe.yml').first).to eq(0)
    end
  end

  it 'needs exactly one file, and a version a recipe can have' do
    expect(run('convert')).to match([2, '', /convert needs one configuration file/])
    write('billing.yml', plain)
    expect(run('convert', '--version', 'one point two', 'billing.yml')).to match([2, '', /--version/])
  end

  it 'is listed in the help' do
    expect(run('--help')[1]).to include('convert [--name NAME] [--version VERSION] [--calls] [--to DIR] FILE')
  end
end
