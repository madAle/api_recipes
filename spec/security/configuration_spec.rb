require 'spec_helper'
require 'tmpdir'

describe 'Configuration files and secrets' do
  def file(name, content)
    Dir.mktmpdir do |dir|
      path = File.join(dir, name)
      File.write(path, content)
      yield path
    end
  end

  it 'does not build Ruby objects from YAML' do
    file('x.yml', "svc: !ruby/object:Gem::Installer\n  i: x\n") do |path|
      expect { ApiRecipes.configure { |c| c.apis_files_paths = [path] } }.to raise_error(ApiRecipes::RecipeFileError)
    end
  end

  it 'evaluates ERB in the files of apis_files_paths and nowhere else' do
    file('x.yml', "svc:\n  host: <%= 'erb' %>.example.test\n") do |path|
      ApiRecipes.configure do |c|
        c.logger = Logger.new(IO::NULL)
        c.apis_files_paths = [path]
      end
      expect(ApiRecipes.svc.definition.host).to eq('erb.example.test')
    end
    ApiRecipes.reset!
    configure_test_apis(svc: { host: 'h.test', default_headers: { 'X-Note' => "<%= raise 'evaluated' %>" } })
    expect(ApiRecipes.svc.definition.default_headers['X-Note']).to eq("<%= raise 'evaluated' %>")
  end

  it 'reads YAML anchors and aliases without building objects, and refuses other tags' do
    file('x.yml', "base: &b\n  host: a.example.test\nsvc: *b\n") do |path|
      ApiRecipes.configure do |c|
        c.logger = Logger.new(IO::NULL)
        c.apis_files_paths = [path]
      end
      expect(ApiRecipes.svc.definition.host).to eq('a.example.test')
    end
    file('y.yml', "svc:\n  host: !ruby/regexp /x/\n") do |path|
      expect { ApiRecipes.configure { |c| c.apis_files_paths = [path] } }.to raise_error(ApiRecipes::RecipeFileError)
    end
  end

  it 'refuses a file that is not a mapping, is empty or is not UTF-8, without showing its content' do
    { 'a.yml' => "- SECRET\n", 'b.yml' => '', 'c.yml' => "svc: \xff SECRET\n".b }.each do |name, content|
      file(name, content) do |path|
        expect { ApiRecipes.configure { |c| c.apis_files_paths = [path] } }
          .to raise_error(ApiRecipes::RecipeFileError) { |error| expect(error.message).not_to include('SECRET') }
      end
    end
  end

  it 'refuses a file named *.recipe.yml in apis_files_paths, whatever the case and the link, and does not run its ERB' do
    Dir.mktmpdir do |dir|
      text = "svc:\n  host: <%= raise 'evaluated' %>\n"
      shared = File.join(dir, 'x.recipe.yml')
      upper = File.join(dir, 'Y.RECIPE.YML')
      link = File.join(dir, 'plain.yml')
      File.write(shared, text)
      File.write(upper, text)
      File.symlink(shared, link)
      [shared, upper, link].each do |path|
        expect { ApiRecipes.configure { |c| c.apis_files_paths = [path] } }
          .to raise_error(ApiRecipes::RecipeFileError, /not supported by this version/)
      end
    end
  end

  # verify_with calls a method, private ones included, of the calling object:
  # it comes from the local sources and from api and with, which the
  # application writes. Shared recipes (5.6) are a later release.
  it 'lets verify_with call a private method of the calling object, given in api or in with' do
    configure_test_apis(svc: { host: 'api.example.test', endpoints: { users: nil } })
    stub_request(:get, "#{base_url}/users").to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })
    calls = []
    klass = Class.new do
      include ApiRecipes
      api :svc, verify_with: :checked

      define_method(:checked) { |response| calls << [:checked, response.code] }
      define_method(:other) { |_response| calls << :other }
      private :checked, :other
    end
    klass.new.svc.users.run
    klass.new.svc.with(verify_with: :other).users.run
    expect(calls).to eq([[:checked, 200], :other])
  end

  it 'never evaluates ERB found in a value of apis_configs or in a response' do
    configure_test_apis(svc: { host: 'h.test', base_url: "<%= raise 'evaluated' %>", endpoints: { users: nil } })
    stub_request(:get, %r{\Ahttps://h\.test/}).to_return(status: 200, body: "{\"x\":\"<%= raise 'evaluated' %>\"}",
                                                         headers: { 'Content-Type' => 'application/json' })
    expect(ApiRecipes.svc.users.run.data).to eq('x' => "<%= raise 'evaluated' %>")
  end

  describe 'the content of an x- or x_ option' do
    let(:cyclic) { {}.tap { |hash| hash['self'] = hash } }
    let(:hostile) do
      [{ 1 => 2, true => false }, { "a\xff".dup.force_encoding('UTF-8') => 1 }, { 'k' => 1, k: 2 }, cyclic]
    end

    def hash_with(content)
      { svc: { host: 'h.test', 'x-note' => content, x_other: content,
               endpoints: { users: { 'x-doc' => content, x_more: content, endpoints: { show: { 'x-deep' => content } } } } } }
    end

    it 'is never inspected, in a Hash' do
      hostile.each do |content|
        ApiRecipes.reset!
        expect { configure_test_apis(hash_with(content)) }.not_to raise_error
        expect(ApiRecipes.svc.users.url.to_s).to eq('https://h.test/users')
      end
    end

    it 'is never inspected, in a YAML file' do
      yaml = "svc:\n  host: h.test\n  x-note: &n\n    1: 2\n    true: false\n  endpoints:\n    users:\n      x-doc: *n\n" \
             "      endpoints:\n        show:\n          x-deep:\n            3: 4\n"
      file('x.yml', yaml) do |path|
        ApiRecipes.configure do |c|
          c.logger = Logger.new(IO::NULL)
          c.apis_files_paths = [path]
        end
        expect(ApiRecipes.svc.users.url.to_s).to eq('https://h.test/users')
      end
    end
  end

  describe 'a later configure with a structure that contains itself under an x- key' do
    let(:note) { {}.tap { |hash| hash[:self] = hash } }
    let(:cyclic) { { host: 'h.test', endpoints: { users: nil }, 'x-note' => note } }

    def silent
      ->(c) { c.logger = Logger.new(IO::NULL) }
    end

    it 'works when the cycle was given as a Hash' do
      ApiRecipes.configure { |c| silent.call(c); c.apis_configs = { svc: cyclic } }
      expect { ApiRecipes.configure { |c| c.print_urls = false } }.not_to raise_error
      expect { ApiRecipes.configure { |c| c.print_urls = true } }.not_to raise_error
      expect(ApiRecipes.svc.users.url.to_s).to eq('https://h.test/users')
    end

    it 'works when the cycle was given in a YAML file' do
      yaml = "svc:\n  host: h.test\n  x-note: &n\n    self: *n\n  endpoints:\n    users:\n"
      file('cycle.yml', yaml) do |path|
        ApiRecipes.configure { |c| silent.call(c); c.apis_files_paths = [path] }
        expect { ApiRecipes.configure { |c| c.print_urls = false } }.not_to raise_error
        expect(ApiRecipes.svc.users.url.to_s).to eq('https://h.test/users')
      end
    end

    it 'yields a copy that shares no mutable object and keeps the cycle and the sharing' do
      shared = { 'a' => [+'text'] }
      source = ApiRecipes::Configuration.new
      source.apis_configs = { svc: cyclic.merge('x-one' => shared, 'x-two' => shared) }
      copy = source.dup
      before = source.apis_configs[:svc]
      after = copy.apis_configs[:svc]
      expect(after).not_to equal(before)
      expect(after[:'x-note']).not_to equal(before[:'x-note'])
      expect(after[:'x-note'][:self]).to equal(after[:'x-note'])
      expect(after[:'x-one']).not_to equal(before[:'x-one'])
      expect(after[:'x-one']).to equal(after[:'x-two'])
      expect(after[:'x-one']['a'].first).not_to equal(before[:'x-one']['a'].first)
      after[:'x-one']['a'].first << ' changed'
      expect(before[:'x-one']['a'].first).to eq('text')
    end

    it 'leaves the previous configuration untouched when a configure that edits it fails' do
      ApiRecipes.configure { |c| silent.call(c); c.apis_configs = { svc: cyclic } }
      expect do
        ApiRecipes.configure do |c|
          c.apis_configs[:svc][:'x-note'][:added] = 1
          c.apis_configs[:svc][:host] = 'other.test'
          raise 'stop'
        end
      end.to raise_error('stop')
      expect(ApiRecipes.configuration.apis_configs[:svc][:'x-note'].keys).to eq([:self])
      expect(ApiRecipes.configuration.apis_configs[:svc][:host]).to eq('h.test')
    end
  end

  describe 'a configuration that is refused before anything is built' do
    def refused(apis)
      expect { configure_test_apis(apis) }.to raise_error(ApiRecipes::ConfigurationError)
    end

    it 'has a Hash that contains itself' do
      loop = { host: 'h.test' }
      loop[:endpoints] = { users: loop }
      refused(svc: loop)
    end

    it 'has a YAML alias that points to its own mapping' do
      file('loop.yml', "svc: &a\n  host: h.test\n  endpoints:\n    users: *a\n") do |path|
        expect { ApiRecipes.configure { |c| c.apis_files_paths = [path] } }.to raise_error(ApiRecipes::ConfigurationError)
      end
    end

    it 'has an api called with a name that is not valid text' do
      refused("sv\xffc".dup.force_encoding('UTF-8') => { host: 'h.test' })
    end

    it 'has an option given twice, as a String and as a Symbol' do
      refused(svc: { 'host' => 'a.test', host: 'b.test' })
    end

    it 'has names that are empty or hold a control character' do
      refused(svc: { host: 'h.test', endpoints: { '' => nil } })
      refused(svc: { host: 'h.test', endpoints: { "us\ners" => nil } })
      refused('' => { host: 'h.test' })
    end

    it 'has input with invalid encoding' do
      refused(svc: { host: "h.test\xff".b.force_encoding('UTF-8') })
      refused(svc: { host: 'h.test', endpoints: { "a\xffb".dup.force_encoding('UTF-8') => nil } })
    end

    it 'has a placeholder in base_url, or a host with a character a host cannot have' do
      refused(svc: { host: 'h.test', base_url: 'v1/:id' })
      ['h.test/x', 'h.test:80', 'u@h.test', 'h.test?x', 'h .test', "h.test\r\n"].each { |host| refused(svc: { host: host }) }
    end

    it 'refuses a top-level api given as a String and as a Symbol' do
      refused('svc' => { host: 'a.test' }, svc: { host: 'b.test' })
    end

    it 'keeps the previous configuration when the new one is refused' do
      configure_test_apis(svc: { host: 'good.test', endpoints: { users: nil } })
      refused(svc: { host: 'bad host' })
      expect(ApiRecipes.svc.definition.host).to eq('good.test')
    end
  end

  it 'never shows a credential, whatever is inspected' do
    configure_test_apis
    client = new_client_class.new
    client.svc.authorization = 'Bearer SECRET'
    ApiRecipes.svc.basic_auth = { user: 'u', pass: 'SECRET' }
    shown = [client, client.svc, client.svc.users, client.svc.definition, client.svc.definition.to_h,
             ApiRecipes.svc, ApiRecipes.configuration, client.svc.with(authorization: 'Bearer SECRET')].map(&:inspect)
    expect(shown.join).not_to include('SECRET')
  end

  it 'does not put a credential with a line break in an error' do
    configure_test_apis
    expect { ApiRecipes.svc.authorization = "Bearer SECRET\n" }
      .to raise_error(ApiRecipes::InvalidCredential) { |e| expect(e.message).not_to include('SECRET') }
  end
end
