require 'spec_helper'
require 'api_recipes/cli'
require 'stringio'
require 'tmpdir'

describe 'api_recipes upgrade' do
  let(:root) { File.expand_path('../fixtures/upgrade', __dir__) }

  def run(*argv)
    out = StringIO.new
    err = StringIO.new
    [ApiRecipes::CLI.run(argv, out: out, err: err), out.string, err.string]
  end

  def snapshot = Dir[File.join(root, '**/*')].to_h { |f| [f, File.file?(f) ? File.read(f) : nil] }

  it 'reports what was removed and what to check, with file and line' do
    code, out, = run('upgrade', File.join(root, 'app'))
    expect(code).to eq(1)
    expect(out).to match(%r{app/client\.rb:5: \[breaks\] endpoint\.route was removed})
    expect(out).to match(%r{app/client\.rb:6: \[check\] a bare rescue})
    expect(out).to match(%r{app/client\.rb:7: \[breaks\] use config\.print_urls})
    expect(out).to match(%r{app/client\.rb:10: \[check\] path parameters are now encoded})
    expect(out).to include('What this command cannot find', '4 findings')
  end

  it 'finds a rescue of an error class that was removed' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'a.rb'), <<~RUBY)
        begin
          call
        rescue ApiRecipes::RouteAndResourceNamesClashError, ApiRecipes::MissingRouteAttribute
        end
        rescue ApiRecipes::ProvidedObjectNotAsResponseData
        rescue ApiRecipes::NoConfigurationGivenForEndpoint
      RUBY
      code, out, = run('upgrade', dir)
      expect(code).to eq(1)
      expect(out.scan('[breaks] this error class was removed').size).to eq(3)
      expect(out).to include('a.rb:3:', 'a.rb:5:', 'a.rb:6:')
    end
  end

  it 'lists the accessors and changes that a text search cannot tell apart' do
    _, out, = run('upgrade', File.join(root, 'app'))
    expect(out).to include('Endpoint#name, #params, #children, #api and Api#name, #configs, #object',
                           'an object restored from a serialized form',
                           'response.uri leaves out the credential query parameter',
                           'a redirect to a host with non-ASCII characters needs the addressable gem',
                           'an endpoint called with, definition, authorization, basic_auth or variables',
                           'or run, url, with or definition')
  end

  it 'lists the changes that a search in the text cannot find' do
    _, out, = run('upgrade', File.join(root, 'app'))
    expect(out).to include('a class with its own host, protocol or port that relied on the global credential',
                           'cookies set by a server during a redirect chain',
                           'api names that are methods of Kernel',
                           'a base_url with a placeholder in a configuration given as a Hash',
                           'respond_to? on a response now tells the truth',
                           'serializing an Api, an Endpoint or a Response raises TypeError',
                           'a class that includes ApiRecipes and uses a top-level constant named Error, Internals, VERSION')
  end

  it 'validates configuration files with the 3.0 rules' do
    code, out, = run('upgrade', '--config', File.join(root, 'config/bad.yml'))
    expect(code).to eq(1)
    expect(out).to include("[config] github.endpoints.users: unknown option 'method'")
  end

  it 'evaluates ERB only when asked' do
    _, out, = run('upgrade', '--config', File.join(root, 'config/with_erb.yml'))
    expect(out).to include('contains ERB: run again with --erb')
    code, out, = run('upgrade', '--erb', '--config', File.join(root, 'config/with_erb.yml'))
    expect(code).to eq(0)
    expect(out).to include('Nothing to change')
  end

  it 'changes no file' do
    before = snapshot
    run('upgrade', root, '--config', File.join(root, 'config/bad.yml'))
    expect(snapshot).to eq(before)
  end

  it 'answers --version, --help and an unknown command' do
    expect(run('--version')).to match([0, /#{Regexp.escape(ApiRecipes::VERSION)}/, ''])
    expect(run('--help')[1]).to include('upgrade')
    expect(run('nope')).to match([2, '', /unknown command: nope/])
  end

  it 'says "1 finding" for exactly one' do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'a.rb'), "endpoint.route\n")
      _, out, = run('upgrade', dir)
      expect(out).to match(/^1 finding$/)
    end
  end

  describe 'the executable' do
    let(:exe) { File.expand_path('../../exe/api_recipes', __dir__) }

    it 'starts with a shebang and is executable' do
      expect(File.open(exe, &:readline)).to eq("#!/usr/bin/env ruby\n")
      expect(File.executable?(exe)).to be(true)
    end

    it 'runs directly' do
      lib = File.expand_path('../../lib', __dir__)
      out = `RUBYOPT=-I#{lib} #{exe} --version 2>/dev/null`
      expect(out.strip).to eq(ApiRecipes::VERSION)
      expect($?.success?).to be(true)
    end
  end

  it 'is not loaded with the library' do
    expect(`ruby -Ilib -e 'require "api_recipes"; print defined?(ApiRecipes::CLI).inspect'`).to eq('nil')
  end

  context 'with files it cannot trust' do
    around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

    def write(name, content)
      File.binwrite(File.join(@dir, name), content)
      File.join(@dir, name)
    end

    it 'never prints the scanned line' do
      write('secret.rb', "token = 'hunter2'; endpoint.route\n")
      code, out, err = run('upgrade', @dir)
      expect(code).to eq(1)
      expect(out + err).not_to include('hunter2')
      expect(out).to include('secret.rb:1: [breaks]')
    end

    it 'does not crash on a file that is not valid UTF-8' do
      write('bad.rb', "x = \"\xFF\xFE\"\nendpoint.route\n")
      code, out, err = run('upgrade', @dir)
      expect(code).to eq(2)
      expect(err).to match(/bad\.rb: .*UTF-8/)
      expect(out).not_to include('[breaks]')
    end

    it 'does not crash on a binary file with a .rb name' do
      write('bin.rb', "\x00\x01\x02\xFF\xD8endpoint.route\x00".b)
      code, _, err = run('upgrade', @dir)
      expect(code).to eq(2)
      expect(err).to match(/bin\.rb: /)
    end

    it 'does not crash on an unreadable file' do
      path = write('locked.rb', "endpoint.route\n")
      begin
        File.chmod(0, path)
        skip 'running as root' if File.readable?(path)
        code, _, err = run('upgrade', @dir)
        expect(code).to eq(2)
        expect(err).to match(/locked\.rb: cannot read/)
      ensure
        File.chmod(0o600, path)
      end
    end

    it 'does not crash on a directory that does not exist' do
      code, _, err = run('upgrade', File.join(@dir, 'missing'))
      expect(code).to eq(2)
      expect(err).to match(/missing: no such file or directory/)
    end

    it 'does not crash on a symlink loop' do
      File.symlink(File.join(@dir, 'loop.rb'), File.join(@dir, 'loop.rb'))
      code, _, err = run('upgrade', @dir)
      expect(code).to eq(2)
      expect(err).to match(/loop\.rb: cannot read/)
    end

    it 'does not loop on a directory symlinked into itself' do
      File.symlink(@dir, File.join(@dir, 'again'))
      write('a.rb', "endpoint.route\n")
      code, out, = run('upgrade', @dir)
      expect(code).to eq(1)
      expect(out).to match(/^1 finding$/)
    end

    it 'turns problems of a configuration file into findings' do
      empty = write('empty.yml', '')
      broken = write('broken.yml', "github: [\n")
      list = write('list.yml', "- 1\n")
      latin = write('latin.yml', "github: { host: \"caf\xE9\" }\n")
      shared = write('x.recipe.yml', "a: {}\n")
      code, out, err = run('upgrade', '--config', empty, '--config', broken, '--config', list,
                           '--config', latin, '--config', shared,
                           '--config', File.join(@dir, 'missing.yml'), '--config', @dir)
      expect(code).to eq(1)
      expect(err).to eq('')
      expect(out.scan('[config]').size).to eq(7)
      expect(out).to include('file is empty', 'invalid YAML', 'must contain a mapping', 'file not found')
    end

    it 'reports an ERB file that fails when evaluated' do
      path = write('boom.yml', "github: { host: <%= raise 'secret-value' %> }\n")
      code, out, err = run('upgrade', '--erb', '--config', path)
      expect(code).to eq(1)
      expect(out).to include('[config]')
      expect(out + err).not_to include('secret-value')
    end

    it 'does not evaluate ERB without --erb' do
      marker = File.join(@dir, 'marker')
      path = write('x.yml', "github: { host: <%= File.write(#{marker.inspect}, '1') %> }\n")
      run('upgrade', '--config', path)
      expect(File.exist?(marker)).to be(false)
    end

    it 'asks for something to check when given nothing' do
      code, _, err = run('upgrade')
      expect(code).to eq(2)
      expect(err).to include('upgrade needs')
    end

    it 'rejects an unknown option' do
      code, _, err = run('upgrade', '--nope', @dir)
      expect(code).to eq(2)
      expect(err).to include('--nope')
    end
  end
end
