require 'spec_helper'
require 'api_recipes/cli'
require 'json'
require 'tmpdir'

describe ApiRecipes::CLI::Import::Document do
  let(:error) { ApiRecipes::CLI::Import::Error }

  def parse(text) = described_class.parse(text)

  it 'reads YAML and JSON to the same document' do
    yaml = parse(openapi)
    json = parse(JSON.generate(YAML.safe_load(openapi)))
    expect(json.root).to eq(yaml.root)
    expect([yaml.title, yaml.version]).to eq(['Test API', '1.0'])
  end

  it 'reads JSON that starts with blank lines' do
    expect(parse("\n  #{JSON.generate(YAML.safe_load(openapi))}").title).to eq('Test API')
  end

  it 'follows an internal $ref, also through another $ref' do
    doc = parse(openapi('components' => { 'parameters' => {
                          'a' => { '$ref' => '#/components/parameters/b' },
                          'b' => { 'name' => 'page', 'in' => 'query' }
                        } }))
    expect(doc.resolve({ '$ref' => '#/components/parameters/a' }, 'here')).to eq('name' => 'page', 'in' => 'query')
  end

  it 'returns what is not a $ref as it is' do
    doc = parse(openapi)
    node = { 'name' => 'page' }
    expect(doc.resolve(node, 'here')).to equal(node)
    expect(doc.resolve(nil, 'here')).to be_nil
    expect(doc.resolve('text', 'here')).to eq('text')
  end

  it 'decodes ~1, ~0 and %XX in a pointer, and reads the items of a list' do
    doc = parse(openapi('paths' => { '/a/{b}' => { 'get' => { 'operationId' => 'x' } } },
                        'x-list' => [{ 'n' => 0 }, { 'n' => 1 }], 'x-odd' => { 'a~b' => 'tilde' }))
    expect(doc.resolve({ '$ref' => '#/paths/~1a~1%7Bb%7D' }, 'here')).to include('get')
    expect(doc.resolve({ '$ref' => '#/x-list/1' }, 'here')).to eq('n' => 1)
    expect(doc.resolve({ '$ref' => '#/x-odd/a~0b' }, 'here')).to eq('tilde')
  end

  it 'finds a key that YAML read as a number' do
    doc = parse("openapi: 3.0.3\ninfo: {title: T, version: '1'}\npaths: {}\nx-codes:\n  200: {description: ok}\n")
    expect(doc.resolve({ '$ref' => '#/x-codes/200' }, 'here')).to eq('description' => 'ok')
  end

  it 'refuses a $ref that leaves the file, and never opens the other file' do
    doc = parse(openapi)
    expect(File).not_to receive(:read)
    expect(File).not_to receive(:open)
    ['./other.yml#/x', 'other.yml', 'https://example.test/a.yml#/x', '/etc/passwd', '../x.json'].each do |ref|
      expect { doc.resolve({ '$ref' => ref }, 'paths./users') }
        .to raise_error(error, /paths\.\/users: .*another file: bundle the description into one file first/)
    end
  end

  it 'refuses a $ref to something that does not exist, or that is not text' do
    doc = parse(openapi('x-list' => [1]))
    ['#/components/missing', '#/info/title/deeper', '#/x-list/5', '#/x-list/first'].each do |ref|
      expect { doc.resolve({ '$ref' => ref }, 'here') }.to raise_error(error, /here: .*does not exist/)
    end
    expect { doc.resolve({ '$ref' => 42 }, 'here') }.to raise_error(error, /here: \$ref must be a string/)
  end

  it 'refuses a cycle of $ref instead of following it forever' do
    doc = parse(openapi('components' => { 'parameters' => {
                          'a' => { '$ref' => '#/components/parameters/b' },
                          'b' => { '$ref' => '#/components/parameters/a' },
                          'self' => { '$ref' => '#/components/parameters/self' }
                        } }))
    %w[a self].each do |name|
      expect { doc.resolve({ '$ref' => "#/components/parameters/#{name}" }, 'here') }
        .to raise_error(error, /here: circular \$ref/)
    end
  end

  it 'shows a $ref in a message on one line, without control characters' do
    doc = parse(openapi)
    expect { doc.resolve({ '$ref' => "evil\nhost: x#{'y' * 300}" }, 'here') }
      .to raise_error(error) { |e| expect(e.message).not_to match(/\n|y{100}/) }
  end

  it 'reads a description whose schemas refer to themselves' do
    doc = parse(openapi('components' => { 'schemas' => {
                          'Node' => { 'properties' => { 'next' => { '$ref' => '#/components/schemas/Node' } } }
                        } }))
    expect(doc.root.dig('components', 'schemas', 'Node')).to be_a(Hash)
  end

  it 'accepts dates and times written without quotes in YAML' do
    text = openapi('x-released' => 'RELEASED').sub("version: '1.0'", 'version: 2024-01-01')
                                             .sub('RELEASED', '2024-01-01 10:00:00 +00:00')
    expect(parse(text).version).to eq('2024-01-01')
  end

  it 'accepts the versions 3.0 and 3.1, also read as a number' do
    ['3.0.0', '3.0.3', '3.1.0', '3.1.1'].each do |version|
      expect(parse(openapi('openapi' => version)).title).to eq('Test API')
    end
    expect(parse(openapi.sub('openapi: 3.0.3', 'openapi: 3.1')).title).to eq('Test API')
  end

  it 'refuses Swagger 2.0 and tells to convert it' do
    text = YAML.dump('swagger' => '2.0', 'info' => { 'title' => 'T' }, 'paths' => {})
    expect { parse(text) }.to raise_error(error, /Swagger 2\.0 is not supported: convert it to OpenAPI 3/)
  end

  it 'refuses a version it does not know' do
    ['4.0.0', '3.2.0', '2.0', '30.1', nil, ['3.0.3']].each do |version|
      expect { parse(openapi('openapi' => version)) }.to raise_error(error, /only OpenAPI 3\.0 or 3\.1/)
    end
  end

  it 'reads YAML aliases, which are the same object and not a copy' do
    doc = parse("openapi: 3.0.3\ninfo: &a {title: T}\nx-copy: *a\n")
    expect(doc.root['x-copy']).to equal(doc.root['info'])
    expect { parse("openapi: 3.0.3\nx-copy: *missing\n") }.to raise_error(error, /alias that is not defined/)
  end

  it 'never turns a mapping or a list of the description into text' do
    levels = (1..40).map { |n| "x#{n}: &x#{n} [*x#{n - 1}, *x#{n - 1}, *x#{n - 1}, *x#{n - 1}]" }
    doc = parse("openapi: 3.0.3\nx0: &x0 [lol]\n#{levels.join("\n")}\ninfo: {title: *x40, version: *x40}\nswagger-like: *x40\n")
    expect([doc.title, doc.version]).to eq([nil, nil])
    expect(doc.inspect.length).to be < 200
    expect(ApiRecipes::CLI::Import.shown(doc.root['x40'])).to eq('a list')
    expect(ApiRecipes::CLI::Import.one_line(doc.root['x40'])).to eq('')
  end

  it 'refuses a Ruby object and a file that is not a mapping' do
    expect { parse("--- !ruby/object:Object {}\n") }.to raise_error(error, /plain data/)
    expect { parse("openapi: 3.0.3\nx-o: !ruby/object:OpenStruct {a: 1}\n") }.to raise_error(error, /plain data/)
    expect { parse("- a\n- b\n") }.to raise_error(error, /mapping/)
    expect { parse('') }.to raise_error(error, /empty/)
    expect { parse("# only a comment\n") }.to raise_error(error, /empty/)
  end

  it 'says so when the text is not valid YAML or JSON' do
    expect { parse("a: [1, 2\nb: }") }.to raise_error(error, /not valid YAML/)
    expect { parse('{"openapi": ') }.to raise_error(error, /not valid JSON/)
  end

  it 'says why a file cannot be read' do
    Dir.mktmpdir do |dir|
      missing = File.join(dir, 'missing.yml')
      binary = File.join(dir, 'binary.yml')
      File.binwrite(binary, "openapi: \xFF\xFE")
      expect { described_class.load(missing) }.to raise_error(error, /missing\.yml: no such file/)
      expect { described_class.load(dir) }.to raise_error(error, /is a directory/)
      expect { described_class.load(binary) }.to raise_error(error, /binary\.yml: is not valid UTF-8/)
    end
  end

  it 'loads a file' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'api.yml')
      File.write(path, openapi)
      expect(described_class.load(path).title).to eq('Test API')
    end
  end
end
