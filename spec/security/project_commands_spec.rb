require 'spec_helper'
require 'api_recipes/cli'
require 'tmpdir'
require 'fileutils'

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
end
