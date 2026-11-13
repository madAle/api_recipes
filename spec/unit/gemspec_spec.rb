require 'spec_helper'

describe 'api_recipes.gemspec' do
  let(:gemspec) { Gem::Specification.load('api_recipes.gemspec') }

  it 'declares its runtime dependencies' do
    expect(gemspec.runtime_dependencies.map(&:name)).to contain_exactly('http', 'logger')
  end

  it 'links changelog and source' do
    expect(gemspec.metadata).to include(
      'changelog_uri'   => 'https://github.com/madAle/api_recipes/blob/master/CHANGELOG.md',
      'source_code_uri' => 'https://github.com/madAle/api_recipes'
    )
  end
end
