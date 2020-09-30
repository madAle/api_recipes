require 'api_recipes'
require 'yaml'

# Configure ApiRecipes through a yaml file.
# Take a look at examples/config/apis.yml  for details
ApiRecipes.configure do |config|
  config.apis_configs = YAML.load_file(File.expand_path('examples/config/apis.yml'))
end

# Let's create a simple class that uses ApiRecipes
class MyFancyClass
  include ApiRecipes

  api :github
end

# Warning: Github has a low rate limit for unauthorized api requests.

# Get user's usernames from Github's Apis (https://github.com)
usernames = nil
MyFancyClass.github.users do |response|
  usernames = response.data.collect{ |user| user['login'] }
end
puts "Usernames: #{usernames}\n\n"

# Get user's repos
user_id = usernames.first
repos = nil
MyFancyClass.github.users.repos(user_id) do |response|
  repos = response.data
end
puts "Repos of user '#{user_id}': #{repos.collect { |r| r['name'] }}\n\n"

# The endpoints are available on instances too
fancy = MyFancyClass.new

fancy.github.users do |response|
  puts "Using a class' instance. Usernames: #{response.data.collect{ |user| user['login'] }}"
end
