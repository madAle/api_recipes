require 'spec_helper'

describe 'ApiRecipes.reset!' do
  it 'removes global api methods, storage and configuration' do
    configure_test_apis
    expect(ApiRecipes).to respond_to(:svc)

    ApiRecipes.reset!

    expect(ApiRecipes).not_to respond_to(:svc)
    expect(ApiRecipes.apis).to eq([])
    expect(ApiRecipes.configuration.apis_configs).to eq({})
  end

  it 'can be called before any configuration' do
    expect { ApiRecipes.reset! }.not_to raise_error
  end

  it 'resets print_urls' do
    ApiRecipes.configuration.print_urls = true
    ApiRecipes.reset!
    expect(ApiRecipes.configuration.print_urls).to eq(false)
  end
end
