require 'api_recipes'
require 'yaml'

# Configure RemoteApi through a yaml file.
# Take a look at examples/config/apis.yml  for details
ApiRecipes.configure do |config|
  config.apis_configs = YAML.load_file(File.expand_path('examples/config/apis.yml'))
end

# Let's create a simple class that uses ApiRecipes
class MyFancyClass
  include ApiRecipes

  # Get your OAUTH token on Github.
  # Navigate Profile => Settings => Personal Access Tokens => Generate new token
  # Copy the generated string and substitute it to YOUR_GITHUB_OAUTH_TOKEN below

  MY_CUSTOM_CONFIG = {
      default_headers: {
          'Authorization' => 'token YOUR_GITHUB_OAUTH_TOKEN'
      }
  }

  # Declare the endpoints that we're going to use
  # Add some custom configs
  endpoint :github, MY_CUSTOM_CONFIG
end

# From now on every MyFancyClass (and its instances) github's api request will
# be authenticated through the provided Authorization header

# Get user's usernames from Github's Apis (https://github.com)
usernames = nil
MyFancyClass.github.users.list do |users|
  usernames = users.collect{ |user| user['login'] }
end

# Get user's repos
MyFancyClass.github.users.repos(user_id: usernames.first) do |repos|
  puts repos
end
