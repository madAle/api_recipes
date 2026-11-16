require 'spec_helper'

RSpec.describe ApiRecipes::Internals::PlainYaml do
  def load(text, max_bytes: 10_000)
    described_class.load(text, max_bytes: max_bytes)
  end

  def refused(text, message, **options)
    expect { load(text, **options) }.to raise_error(described_class::Refused, message)
  end

  it 'reads mappings, lists, text, numbers, booleans and nothing' do
    text = "api:\n  host: h.test\n  port: 8080\n  ratio: 1.5\n  list: [a, 'b']\n  enabled: true\n  none:\n"
    expect(load(text)).to eq('api' => { 'host' => 'h.test', 'port' => 8080, 'ratio' => 1.5, 'list' => %w[a b],
                                        'enabled' => true, 'none' => nil })
  end

  it 'reads a document that starts with ---' do
    expect(load("---\na: 1\n")).to eq('a' => 1)
  end

  it 'returns nil for an empty text' do
    expect(load('')).to be_nil
    expect(load("# only a comment\n")).to be_nil
  end

  it 'refuses a text larger than the limit, before parsing it' do
    expect(Psych::Parser).not_to receive(:new)
    refused('a: 1' * 10, 'is larger than 20 bytes', max_bytes: 20)
  end

  it 'refuses a text that is not valid UTF-8' do
    refused("a: \"caf\xE9\"\n", 'is not valid UTF-8')
  end

  it 'refuses a text that is not UTF-8 at all' do
    refused("a: 1\n".encode(Encoding::UTF_16LE), 'is not valid UTF-8')
  end

  it 'refuses invalid YAML and says the line' do
    refused("a: [\nb: 1\n", /\Ais not valid YAML \(line \d+\)\z/)
  end

  it 'refuses an alias and an anchor' do
    refused("a: &x 1\nb: *x\n", 'uses an anchor or an alias')
    refused("a: &x { b: 1 }\n", 'uses an anchor or an alias')
    refused("a: &x [1]\n", 'uses an anchor or an alias')
    refused("a: &x 1\n", 'uses an anchor or an alias')
  end

  it 'refuses a tag on a value, a mapping or a list' do
    refused("a: !!binary aGk=\n", 'uses a tag')
    refused("a: !ruby/object:Object {}\n", 'uses a tag')
    refused("a: !!set [1]\n", 'uses a tag')
    refused("a: !!str 1\n", 'uses a tag')
  end

  it 'refuses the same key twice in a mapping, however it is quoted' do
    refused("a: 1\na: 2\n", "the key 'a' is given twice")
    refused("x:\n  a: 1\n  \"a\": 2\n", "the key 'a' is given twice")
    refused("x: { a: 1, 'a': 2 }\n", "the key 'a' is given twice")
  end

  it 'accepts the same key in two different mappings' do
    expect(load("x: { a: 1 }\ny: { a: 2 }\n")).to eq('x' => { 'a' => 1 }, 'y' => { 'a' => 2 })
  end

  it 'refuses a key that is a mapping or a list' do
    refused("? { a: 1 }\n: 2\n", 'has a key that is not plain text')
    refused("? [a]\n: 2\n", 'has a key that is not plain text')
  end

  it 'refuses the merge key' do
    refused("a: 1\n<<: { a: 2 }\n", 'uses the merge key <<')
    refused("a: 1\n\"<<\": { a: 2 }\n", 'uses the merge key <<')
  end

  it 'refuses a key that YAML reads as something else than text' do
    refused("on: 1\n", "the key 'on' is read as a boolean, not as text: quote it")
    refused("200: 1\n", "the key '200' is read as a number, not as text: quote it")
    refused("x: { 1.5: a }\n", "the key '1.5' is read as a number, not as text: quote it")
    refused("~: 1\n", "the key '~' is read as nothing, not as text: quote it")
    refused("2026-10-01: 1\n", "the key '2026-10-01' is read as something else, not as text: quote it")
    refused(":name: 1\n", "the key ':name' is read as something else, not as text: quote it")
  end

  it 'accepts those keys when they are quoted' do
    expect(load("'on': 1\n'200': 2\n")).to eq('on' => 1, '200' => 2)
  end

  it 'refuses a value that is not plain data' do
    refused("a: 2026-10-01\n", /\Ahas a value that is not plain data \(Date\): quote it\z/)
    refused("a: :symbol\n", /\Ahas a value that is not plain data \(Symbol\): quote it\z/)
  end

  it 'refuses more than one document' do
    refused("a: 1\n---\nb: 2\n", 'holds more than one document')
  end

  it 'refuses a nesting deeper than 100 levels, without building it' do
    expect(Psych).not_to receive(:safe_load)
    refused("#{'[' * 101}#{']' * 101}\n", 'is nested deeper than 100 levels')
    refused("#{'[' * 5000}\n", 'is nested deeper than 100 levels', max_bytes: 100_000)
  end

  it 'accepts a nesting of 100 levels' do
    expect(load("#{'[' * 100}#{']' * 100}\n").flatten).to eq([])
  end

  it 'shows a key with control or format characters without them, and cut' do
    refused("\"a\\u202Eb\\e\": 1\n\"a\\u202Eb\\e\": 2\n", "the key 'a?b?' is given twice")
    long = 'k' * 100
    refused("#{long}: 1\n#{long}: 2\n", "the key '#{'k' * 40}' is given twice")
  end

  describe '.label' do
    it 'replaces what a terminal would not print as it is' do
      expect(described_class.label("a\nb\u2028c\u200Bd\u{E0001}e")).to eq('a?b?c?d?e')
    end

    it 'cuts to the limit' do
      expect(described_class.label('abcdef', 3)).to eq('abc')
    end

    it 'shows text that is not valid UTF-8 without raising' do
      expect(described_class.label("caf\xE9")).to eq('caf?')
    end
  end

  describe 'the text of the file' do
    it 'cannot hold a line break that is not a new line: the parser would start a line where a reader sees none' do
      { 0x2028 => 'line separator', 0x2029 => 'paragraph separator', 0x85 => 'next line' }.each_key do |code|
        text = "a: 1 # only a#{[code].pack('U')}b: 2\n"
        refused(text, 'line 1: contains a character that is not printed (a control or a format character, ' \
                      'or a line break that is not a new line)')
      end
      refused("a: 1 # only a\rb: 2\n", /\Aline 1: contains a character that is not printed/)
    end

    it 'cannot hold a control or a format character, in a comment either, and says the line' do
      [0x202E, 0x2066, 0x200B, 0xFEFF, 0xE0041, 0x1B, 0x00].each do |code|
        refused("a: 1\nb: 2 # hidden#{[code].pack('U')}\n", /\Aline 2: contains a character that is not printed/)
      end
    end

    it 'can end its lines with a carriage return and a new line, and hold tabs' do
      expect(load("a: 1\r\nb: 2 #\tcomment\r\n")).to eq('a' => 1, 'b' => 2)
    end
  end
end
