require 'spec_helper'

describe ApiRecipes::Core::Template do
  def expand(string, position, values)
    described_class.new(string, position).expand(values, api: :shopify)
  end

  it 'knows its variables' do
    template = described_class.new('{shop}.myshopify.com', :host)
    expect(template.names).to eq(%i[shop])
    expect(template.static?).to eq(false)
    expect(described_class.new('api.github.com', :host).static?).to eq(true)
  end

  it 'fills a host' do
    expect(expand('{shop}.myshopify.com', :host, shop: 'acme')).to eq('acme.myshopify.com')
    expect(expand('{shop}.myshopify.com', :host, shop: 'a.b_c-1')).to eq('a.b_c-1.myshopify.com')
  end

  ['evil.test/', 'evil.test#', 'a@evil.test', 'evil.test:8080', "a\nb", 'a b', 'a\\b', '', 'città'].each do |value|
    it "rejects the host value #{value.inspect}" do
      expect { expand('{shop}.myshopify.com', :host, shop: value) }.to raise_error(ApiRecipes::InvalidVariable, /shop/)
    end
  end

  it 'never puts the value in the message' do
    expect { expand('{shop}.myshopify.com', :host, shop: 'private/value') }
      .to raise_error(ApiRecipes::InvalidVariable) { |e| expect(e.message).not_to include('private') }
  end

  it 'encodes a base_url value as one segment' do
    expect(expand('admin/api/{version}', :base_url, version: '2026-10')).to eq('admin/api/2026-10')
    expect(expand('admin/{account}', :base_url, account: 'a/b')).to eq('admin/a%2Fb')
    expect { expand('admin/{account}', :base_url, account: '..') }.to raise_error(ApiRecipes::InvalidVariable)
  end

  it 'refuses control characters in a header value' do
    expect(expand('Shop {shop}', :header, shop: 'acme')).to eq('Shop acme')
    expect { expand('Shop {shop}', :header, shop: "a\r\nX-Evil: 1") }.to raise_error(ApiRecipes::InvalidVariable)
  end

  it 'names the missing variable' do
    expect { expand('{shop}.myshopify.com', :host, {}) }.to raise_error(ApiRecipes::MissingVariable, /shop/)
  end

  describe 'a value with an invalid byte' do
    let(:bad) { "a\xFF".dup.force_encoding('UTF-8') }

    it 'is rejected in a host' do
      expect { expand('{shop}.myshopify.com', :host, shop: bad) }.to raise_error(ApiRecipes::InvalidVariable, /shop/)
    end

    it 'is not a control character in a header, so it expands' do
      expect(expand('Shop {shop}', :header, shop: bad)).to eq("Shop #{bad}")
    end

    it 'is percent-encoded in a base_url' do
      expect(expand('admin/{account}', :base_url, account: bad)).to eq('admin/a%FF')
    end
  end

  describe 'what is shown' do
    it 'inspects the position and the variable names, never the string' do
      expect(described_class.new('{shop}.s3cret.test', :header).inspect).to eq('#<ApiRecipes::Core::Template header variables: shop>')
      expect(described_class.new('Bearer s3cret', :header).inspect).to eq('#<ApiRecipes::Core::Template header variables: none>')
      expect(described_class.new('{a}{b}/s3cret', :base_url).inspect).to eq('#<ApiRecipes::Core::Template base_url variables: a, b>')
      expect(described_class.new('h.test', :host).inspect).to eq('#<ApiRecipes::Core::Template host variables: none>')
    end

    it 'pretty prints like inspect and keeps to_s' do
      require 'pp'
      template = described_class.new('Bearer s3cret', :header)
      expect(template.pretty_inspect.strip).to eq(template.inspect)
      expect(template.to_s).to eq('Bearer s3cret')
      expect { template.instance_variable_set(:@x, 1) }.to raise_error(FrozenError) { |e| expect(e.message).not_to include('s3cret') }
    end
  end
end
