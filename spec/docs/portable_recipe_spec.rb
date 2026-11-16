# frozen_string_literal: true

require 'spec_helper'
require 'api_recipes/cli'

# The portable recipe that README.md shows under "Writing a portable recipe"
# must be one that the gem accepts, and the hosts the text gives as accepted
# or refused must be so.
RSpec.describe 'the portable recipe in the README' do
  let(:section) { File.read(File.expand_path('../../README.md', __dir__))[/^### Writing a portable recipe\n.*?(?=^## )/m] }
  let(:example) { section[/```yaml\n(.*?)```/m, 1] }

  it 'is a valid portable recipe' do
    recipe = ApiRecipes::Internals::Recipe.parse(example, 'README', file_name: 'billing.recipe.yml')
    expect(recipe.name).to eq('billing')
    expect(recipe.version).to eq('1.2.0')
    expect(recipe.definition.routes.map(&:call)).to eq(['billing.invoices', 'billing.invoices.show(id)'])
    expect(ApiRecipes::CLI::Recipes::Summary.new(recipe).warnings).to eq([])
  end

  it 'names hosts that are accepted and refused as it says' do
    with_host = lambda do |host, variable|
      example.sub("host: '{account}.billing.example.com'", "host: '#{host}'").sub('    account:', "    #{variable}:")
    end
    expect(section).to include('`{account}.billing.example.com` and', '`s3.{region}.example.com` are accepted, `api.example.{tld}` is not')
    expect { ApiRecipes::Internals::Recipe.parse(with_host.call('s3.{region}.example.com', 'region'), 'README') }.not_to raise_error
    expect { ApiRecipes::Internals::Recipe.parse(with_host.call('api.example.{tld}', 'tld'), 'README') }
      .to raise_error(ApiRecipes::RecipeFileError, /a variable would decide where the host ends/)
  end
end
