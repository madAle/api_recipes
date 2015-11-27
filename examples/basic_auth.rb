require 'api_recipes'
require 'yaml'

# Configure RemoteApi through a yaml file.
# Take a look at examples/config/apis.yml  for details
ApiRecipes.configure do |config|
  config.endpoints_configs = YAML.load_file(File.expand_path('examples/config/apis.yml'))
end

# Let's create a simple class that uses ApiRecipes
class MyFancyClass
  include ApiRecipes

  # Declare the endpoints that we're going to use
  endpoint :github
end

# Setup Basic Auth
MyFancyClass.github.basic_auth = { user: 'github_username', pass: 'github_password' }

# From now on every github's api request will be authenticated with basic auth

# Get user's usernames from Github's Apis (https://github.com)
usernames = nil
MyFancyClass.github.users.list do |users|
  usernames = users.collect{ |user| user['login'] }
end

# Get user's repos
MyFancyClass.github.users.repos(user_id: usernames.first) do |repos|
  puts repos
end
