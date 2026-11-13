require 'spec_helper'

describe 'api_recipes.gemspec' do
  let(:gemspec) { Gem::Specification.load(File.expand_path('../../api_recipes.gemspec', __dir__)) }

  it 'declares its runtime dependencies' do
    expect(gemspec.runtime_dependencies.map(&:name)).to contain_exactly('http', 'logger')
  end

  it 'requires an http.rb with on_redirect that declares base64' do
    http = gemspec.runtime_dependencies.find { |dependency| dependency.name == 'http' }
    expect(http.requirement).to eq(Gem::Requirement.new('>= 5.2.0', '< 6'))
  end

  it 'links changelog and source' do
    expect(gemspec.metadata).to include(
      'changelog_uri'   => 'https://github.com/madAle/api_recipes/blob/master/CHANGELOG.md',
      'source_code_uri' => 'https://github.com/madAle/api_recipes'
    )
  end

  it 'requires a maintained Ruby and MFA to publish' do
    expect(gemspec.required_ruby_version).to eq(Gem::Requirement.new('>= 3.3.0'))
    expect(gemspec.metadata['rubygems_mfa_required']).to eq('true')
  end

  it 'ships the command and the upgrade guide' do
    expect(gemspec.executables).to eq(['api_recipes'])
    expect(gemspec.files).to include('exe/api_recipes', 'UPGRADING.md')
  end
end
