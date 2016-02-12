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
end


# Warning: Github has a low rate limit for unauthorized api requests.


# Get user's usernames from Github's Apis (https://github.com)
usernames = nil

MyFancyClass.github.users.list do |users|
  usernames = users.collect{ |user| user['login'] }
end

# Get user's repos
MyFancyClass.github.users.repos(user_id: usernames.first) do |repos|
  puts repos
end
