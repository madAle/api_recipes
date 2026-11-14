require 'spec_helper'

# An api or an endpoint kept in a variable keeps the tree it was created with.
# The credentials are read when the request is sent, so a credential is bound
# to the origin that the configuration in force gives to its level.
describe 'An api held across a configure' do
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:old_config) { { svc: { host: 'old.example.test', endpoints: { users: nil } } } }
  let(:new_config) { { svc: { host: 'new.example.test', endpoints: { users: nil } } } }
  let(:client_class) do
    Class.new do
      include ApiRecipes
      api :svc
    end
  end

  before { stub_request(:any, /example\.test/).to_return(status: 200, body: '[]', headers: json) }

  it 'does not take a credential of the global api to the host of the old configuration' do
    configure_test_apis(old_config)
    held = ApiRecipes.svc
    held_endpoint = ApiRecipes.svc.users
    configure_test_apis(new_config)
    ApiRecipes.svc.authorization = 'Bearer NEW'

    expect { held.users.run }.to raise_error(ApiRecipes::CredentialOriginMismatch)
    expect { held_endpoint.run }.to raise_error(ApiRecipes::CredentialOriginMismatch)
    expect(WebMock).not_to have_requested(:any, /example\.test/)
  end

  it 'does not take a credential of an object or of a class to the host of the old configuration' do
    configure_test_apis(old_config)
    client = client_class.new
    held = client.svc
    held_by_class = client_class.svc
    configure_test_apis(new_config)
    client.svc.authorization = 'Bearer OBJECT'

    expect { held.users.run }.to raise_error(ApiRecipes::CredentialOriginMismatch)
    client.svc.authorization = nil
    client_class.svc.authorization = 'Bearer CLASS'
    expect { held_by_class.users.run }.to raise_error(ApiRecipes::CredentialOriginMismatch)
    expect(WebMock).not_to have_requested(:any, /example\.test/)
  end

  it 'does not take a credential to the old host when the api is no longer configured' do
    configure_test_apis(old_config)
    held = ApiRecipes.svc
    ApiRecipes.svc.authorization = 'Bearer OLD'
    configure_test_apis(other: { host: 'other.example.test' })

    expect { held.users.run }.to raise_error(ApiRecipes::CredentialOriginMismatch)
    expect(WebMock).not_to have_requested(:any, /example\.test/)
  end

  it 'keeps sending the credential when the configure does not move the origin' do
    configure_test_apis(old_config)
    held = ApiRecipes.svc
    held_by_object = client_class.new.svc
    configure_test_apis(old_config)
    ApiRecipes.svc.authorization = 'Bearer SAME'

    held.users.run
    held_by_object.users.run
    expect(WebMock).to have_requested(:get, 'https://old.example.test/users')
      .with(headers: { 'Authorization' => 'Bearer SAME' }).twice
  end

  it 'still sends a credential given with with, which belongs to the chain' do
    configure_test_apis(old_config)
    held = ApiRecipes.svc
    configure_test_apis(new_config)

    held.with(authorization: 'Bearer MINE').users.run
    expect(WebMock).to have_requested(:get, 'https://old.example.test/users')
      .with(headers: { 'Authorization' => 'Bearer MINE' })
  end
end
