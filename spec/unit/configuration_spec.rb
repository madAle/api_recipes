require 'spec_helper'

describe ApiRecipes::Configuration do
  def configure_files(*names)
    ApiRecipes.configure do |config|
      config.logger = Logger.new(IO::NULL)
      config.apis_files_paths = names.map { |name| "spec/fixtures/#{name}" }
    end
  end

  it 'loads apis from a YAML file evaluated with ERB' do
    configure_files('svc.yml.erb')
    expect(ApiRecipes.svc.users.url.to_s).to eq('https://api.example.test/users')
  end

  it 'lets a later file replace an api defined by an earlier one' do
    configure_files('svc.yml.erb', 'svc_override.yml')
    expect(ApiRecipes.svc.configs[:host]).to eq('other.example.test')
    expect(ApiRecipes.svc).not_to respond_to(:users)
    expect(ApiRecipes.svc).to respond_to(:ping)
  end

  it 'rejects apis_configs that are not a Hash' do
    expect { ApiRecipes.configuration.apis_configs = [] }.to raise_error(ArgumentError)
  end
end
