require 'spec_helper'
require 'api_recipes/cli'
require 'tmpdir'
require 'fileutils'

# `api_recipes routes` with no argument: the calls of every api of the project
# in the current directory, found as `upgrade` finds them.
describe 'api_recipes routes, in a project' do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = File.realpath(dir)
      Dir.chdir(@root) { example.run }
    end
  end

  let(:marker) { File.join(@root, 'MARKER') }
  let(:billing) { "billing:\n  host: billing.example.test\n  endpoints:\n    invoices:\n      endpoints:\n        show:\n          path: /:id\n" }
  let(:recipe) { "shop:\n  recipe:\n    name: shop\n    version: '1.0.0'\n  host: shop.example.test\n  endpoints:\n    orders:\n      verb: post\n" }

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def project(files)
    write('Gemfile', "gem 'api_recipes'\n")
    files.each { |path, text| write(path, text) }
  end

  it 'lists the calls of every description and of every installed recipe, without being told where they are' do
    project('config/apis/billing.yml' => billing, 'config/api_recipes/shop.recipe.yml' => recipe,
            'config/database.yml' => "production:\n  host: db.example.test\n", 'vendor/apis/x.yml' => billing.sub('billing:', 'vendored:'))
    code, out, err = run_cli('routes')
    expect(err).to eq('')
    expect(code).to eq(0)
    expect(out).to eq(<<~TEXT)
      shop.orders                POST  https://shop.example.test/orders
      billing.invoices           GET   https://billing.example.test/invoices
      billing.invoices.show(id)  GET   https://billing.example.test/invoices/:id
    TEXT
  end

  it 'shows what an ERB tag gives as a variable, without running the tag' do
    project('config/apis/billing.yml.erb' => <<~YAML)
      billing:
        protocol: <%= File.write(#{marker.inspect}, '1'); ENV['P'] || 'https' %>
        host: <%= ENV['BILLING_HOST'] %>
        port: <%= ENV['BILLING_PORT'] || 443 %>
        base_url: api/<%= ENV['V'] %>
        default_headers:
          X-Api-Key: "<%= ENV['KEY'] %>"
        endpoints:
          invoices:
            verb: <%= ENV['VERB'] %>
    YAML
    code, out, err = run_cli('routes')
    expect(File.exist?(marker)).to be(false)
    expect(code).to eq(0)
    expect(out).to eq("billing.invoices  {erb}  {erb}://{erb}:{erb}/api/{erb}/invoices\n")
    expect(err).to eq("config/apis/billing.yml.erb: what an ERB tag gives is shown as {erb}; --erb evaluates the file, which runs the code in it\n")
  end

  it 'evaluates the tags with --erb' do
    project('config/apis/billing.yml.erb' => billing.sub('billing.example.test', "<%= 'evaluated.example.test' %>"))
    code, out, = run_cli('routes', '--erb')
    expect(code).to eq(0)
    expect(out).to include('https://evaluated.example.test/invoices')
  end

  it 'takes another name for the variable when the api has one called erb' do
    project('config/apis/billing.yml.erb' => "billing:\n  variables:\n    erb: {}\n  host: <%= ENV['H'] %>\n  base_url: '{erb}'\n  endpoints:\n    invoices:\n")
    expect(run_cli('routes')[1]).to eq("billing.invoices  GET  https://{erb_tag}/{erb}/invoices\n")
  end

  it 'says of a file whose tags it cannot show, and lists the calls of the others' do
    project('config/apis/billing.yml' => billing,
            'config/apis/other.yml.erb' => "other:\n  host: o.test\n<% if ENV['X'] %>\n  endpoints:\n    a:\n<% end %>\n",
            'config/apis/named.yml.erb' => "named:\n  host: n.test\n  endpoints:\n    <%= ENV['NAME'] %>:\n")
    code, out, err = run_cli('routes')
    expect(code).to eq(1)
    expect(out).to include('billing.invoices.show(id)')
    expect(err).to include('config/apis/other.yml.erb: contains ERB that decides the structure of the file', 'run again with --erb',
                           'config/apis/named.yml.erb: an ERB tag gives a name: run again with --erb')
  end

  it 'says so when the project has no description of an api, or when it is not in a project' do
    project('app/a.rb' => "x = 1\n")
    expect(run_cli('routes')).to eq([1, '', "no file that describes an api was found in this project: name the files to read\n"])
    FileUtils.rm('Gemfile')
    expect(run_cli('routes')).to eq([2, '', "routes needs at least one configuration file, or to be run in the root of a project\n"])
  end

  it 'reads the files it is given as before, and shows their tags as variables too' do
    project('config/apis/billing.yml' => billing, 'other/billing.yml.erb' => billing.sub('billing.example.test', "<%= ENV['H'] %>"))
    code, out, = run_cli('routes', 'other/billing.yml.erb')
    expect(code).to eq(0)
    expect(out).to eq("billing.invoices           GET  https://{erb}/invoices\nbilling.invoices.show(id)  GET  https://{erb}/invoices/:id\n")
  end

  it 'does not send the name of a file to the terminal as it is written' do
    project("config/apis/\e[2Jbilling.yml" => billing.sub('host:', 'hots:'))
    code, out, err = run_cli('routes')
    expect(code).to eq(1)
    expect(out + err).not_to include("\e")
  end
end
