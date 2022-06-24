require 'api_recipes'
require 'yaml'

# Take a look at examples/config/github.yml.erb  for a full list of available options

ApiRecipes.configure do |config|
  config.apis_files_paths = ['examples/config/github.yml.erb']
  config.print_urls = true
end

# Let's create a simple class that uses ApiRecipes
class MyFancyClass
  include ApiRecipes

  # Declare the apis that we're going to use
  api :github
end

# Setup Basic Auth
MyFancyClass.github.basic_auth = { user: ENV['GITHUB_USERNAME'], pass: ENV['GITHUB_PASSWORD'] }

# From now on every github's api request will be authenticated with basic auth

# Get user's usernames from Github's Apis (https://github.com)
usernames = nil
MyFancyClass.github.users do |response|
  usernames = response.data.collect{ |user| user['login'] }
  puts "USERNAMES:\n#{usernames}\n\n"
end

# Get user's repos
user = usernames.first
MyFancyClass.github.users.repos(user) do |response|
  puts "Repos of user #{user}:\n#{response.data.collect { |repo| repo['name'] }}"
end
