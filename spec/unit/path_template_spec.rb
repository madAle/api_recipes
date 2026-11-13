require 'spec_helper'

describe ApiRecipes::PathTemplate do
  def expand(template, *values)
    described_class.parse(template).expand(values, endpoint: 'svc.things')
  end

  it 'lists the placeholders in order' do
    expect(described_class.parse('/repos/:owner/:repo').param_names).to eq(%i[owner repo])
    expect(described_class.parse('/contents/*path').param_names).to eq(%i[path])
    expect(described_class.parse('users').param_names).to eq([])
    expect(described_class.parse('/:1x').param_names).to eq([])
  end

  it 'is frozen' do
    expect(described_class.parse('/:id')).to be_frozen
  end

  it 'escapes every byte outside letters, digits and -._~' do
    expect(described_class.escape('a/b c')).to eq('a%2Fb%20c')
    expect(described_class.escape('città')).to eq('citt%C3%A0')
    expect(described_class.escape('AZaz09-._~')).to eq('AZaz09-._~')
  end

  {
    ['/:id', 7]                        => '/7',
    ['/:id', :rails]                   => '/rails',
    ['/:id', 1.5]                      => '/1.5',
    ['/:id', 'a/b']                    => '/a%2Fb',
    ['/:id', 'a?b#c']                  => '/a%3Fb%23c',
    ['/:id', 'a%2Fb']                  => '/a%252Fb',
    ['/:id', 'città nuova']            => '/citt%C3%A0%20nuova',
    ['/:id', 'a:b']                    => '/a%3Ab',
    ['/files/:name.json', 'report']    => '/files/report.json',
    ['/:owner/:repo', 'a:b', 'c']      => '/a%3Ab/c',
    ['/contents/*path', 'lib/a b.rb']  => '/contents/lib/a%20b.rb',
    ['/operations/:name\:cancel', 'x'] => '/operations/x:cancel'
  }.each do |(template, *values), expected|
    it "expands #{template} with #{values.inspect}" do
      expect(expand(template, *values)).to eq(expected)
    end
  end

  it 'encodes the fixed text once, when parsed' do
    expect(described_class.parse('/my files/a%20b\\c').to_s).to eq('/my%20files/a%20b%5Cc')
  end

  [nil, '', '.', '..', Object.new.tap { |o| o.define_singleton_method(:to_s) { '' } }].each do |value|
    it "rejects #{value.inspect}" do
      expect { expand('/:id', value) }
        .to raise_error(ApiRecipes::InvalidPathParameter, /path parameter 'id' of 'svc.things'/)
    end
  end

  ['a//b', '../etc', 'a/./b', '/a', 'a/'].each do |value|
    it "rejects the splat value #{value.inspect}" do
      expect { expand('/contents/*path', value) }.to raise_error(ApiRecipes::InvalidPathParameter)
    end
  end

  it 'encodes bytes that are not valid UTF-8, for a placeholder and for a splat' do
    expect(expand('/:id', "a\xFFb")).to eq('/a%FFb')
    expect(expand('/contents/*path', "a\xFF/b")).to eq('/contents/a%FF/b')
  end

  it 'encodes the bytes of a value in another encoding, for a placeholder and for a splat' do
    value = 'ab'.encode('UTF-16LE')
    expect(expand('/:id', value)).to eq('/a%00b%00')
    expect(expand('/contents/*path', value)).to eq('/contents/a%00b%00')
  end

  it 'never puts the value in the message' do
    expect { expand('/contents/*path', 'private/../x') }
      .to raise_error(ApiRecipes::InvalidPathParameter) { |e| expect(e.message).not_to include('private') }
  end

  it 'rejects a repeated placeholder' do
    expect { described_class.parse('/:id/:id') }.to raise_error(ArgumentError, /id/)
  end
end
