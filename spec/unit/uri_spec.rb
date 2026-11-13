require 'spec_helper'
require 'support/constants'

# Route#build_uri builds request URLs with URI::Generic.build2, which validates the
# host with URI::DEFAULT_PARSER. The uri gem's RFC 2396 parser (uri < 1.0) rejects
# underscores, common in service names (e.g. docker-compose), so api_recipes widens
# its hostname pattern. From uri 1.0 the default parser follows RFC 3986, which
# accepts them already.
#
# Run against uri 1.x with: URI_VERSION='~> 1.0' bundle exec rspec
describe 'URI' do
  it 'should accept underscores in hostnames' do
    uri = URI::Generic.build2(scheme: 'http', host: 'web_service_1', port: '3000', path: '/users')

    expect(uri.to_s).to eq('http://web_service_1:3000/users')
  end
end
