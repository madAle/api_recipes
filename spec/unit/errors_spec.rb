require 'spec_helper'

describe 'ApiRecipes errors' do
  it 'all inherit from ApiRecipes::Error, a StandardError' do
    classes = ApiRecipes.constants.map { |c| ApiRecipes.const_get(c) }
                        .select { |c| c.is_a?(Class) && c <= Exception }
    expect(classes).to include(ApiRecipes::ResponseCodeNotAsExpected, ApiRecipes::ConfigurationError)
    expect(classes).to all(be <= ApiRecipes::Error)
    expect(ApiRecipes::Error.superclass).to eq(StandardError)
  end

  it 'lists every problem of a configuration' do
    error = ApiRecipes::ConfigurationError.new(['a: bad', 'b: worse'])
    expect(error.errors).to eq(['a: bad', 'b: worse'])
    expect(error.message).to eq("2 problems in the configuration\n  a: bad\n  b: worse")
  end

  it 'uses the singular for a single problem' do
    error = ApiRecipes::ConfigurationError.new(['a: bad'])
    expect(error.message).to eq("1 problem in the configuration\n  a: bad")
  end

  it 'names the file in a RecipeFileError' do
    error = ApiRecipes::RecipeFileError.new('/tmp/x.yml', 'file not found')
    expect(error.path).to eq('/tmp/x.yml')
    expect(error.message).to include('/tmp/x.yml: file not found')
    expect(error).to be_a(ApiRecipes::ConfigurationError)
  end

  it 'describes an invalid path parameter' do
    error = ApiRecipes::InvalidPathParameter.new('users.show', 'id', 'must not be empty')
    expect(error.message).to eq("invalid value for path parameter 'id' of 'users.show': must not be empty")
  end

  it 'lists the available endpoints of an UnknownEndpoint' do
    error = ApiRecipes::UnknownEndpoint.new('users', 'nope', %w[a b])
    expect(error.message).to eq("'users' has no endpoint 'nope'. Available: a, b")
  end

  it 'builds the messages of the variable, credential and url errors' do
    expect(ApiRecipes::MissingVariable.new('svc', 'region').message).to include('svc', 'region')
    expect(ApiRecipes::InvalidVariable.new('svc', 'region', 'bad value').message).to include('svc', 'region', 'bad value')
    expect(ApiRecipes::InvalidCredential.new('bad token').message).to include('bad token')
    expect(ApiRecipes::InvalidUrl.new('bad host').message).to include('bad host')
  end

  it 'names both origins in a CredentialOriginMismatch' do
    error = ApiRecipes::CredentialOriginMismatch.new('svc', 'https://a.test', 'https://b.test')
    expect(error.message).to include('https://a.test', 'https://b.test', 'nil')
    expect(ApiRecipes::CredentialOriginMismatch.new('svc', nil, 'https://b.test').message).to include('https://b.test')
  end

  it 'does not define the classes that were never raised' do
    %i[RouteAndResourceNamesClashError MissingRouteAttribute ProvidedObjectNotAsResponseData
       NoConfigurationGivenForEndpoint].each { |name| expect(ApiRecipes.const_defined?(name)).to eq(false) }
  end
end
