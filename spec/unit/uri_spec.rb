require 'spec_helper'
require 'open3'
require 'rbconfig'

# Request URLs are built without URI::DEFAULT_PARSER, so a host with an
# underscore, common in service names (e.g. docker-compose), works with any
# uri gem, and api_recipes changes neither URI nor the core classes.
#
# Run against uri 1.x with: URI_VERSION='~> 1.0' bundle exec rspec
describe 'URI' do
  it 'should accept underscores in hostnames' do
    configure_test_apis(svc: { protocol: 'http', host: 'web_service_1', port: 3000, endpoints: { users: nil } })

    expect(ApiRecipes.svc.users.url.to_s).to eq('http://web_service_1:3000/users')
  end

  it 'leaves URI::DEFAULT_PARSER and Hash alone' do
    script = <<~RUBY
      require 'uri'
      parser = URI::DEFAULT_PARSER
      require 'api_recipes'
      print URI::DEFAULT_PARSER.equal?(parser), ' ', {}.respond_to?(:deep_merge)
    RUBY
    output, status = Open3.capture2(RbConfig.ruby, '-Ilib', '-e', script, chdir: File.expand_path('../..', __dir__))

    expect(status).to be_success
    expect(output).to eq('true false')
  end
end
