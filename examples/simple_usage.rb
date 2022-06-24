require 'api_recipes'

# Configure ApiRecipes through a single yaml file.
# Take a look at examples/config/github.yml.erb  for a list of supported options

ApiRecipes.configure do |config|
  # Give an array of paths to YAML files containing api configs. Files can contain ERB code.
  config.apis_files_paths = ['examples/config/github.yml.erb']
  # Debug option that will print invoked urls to console before making the call
  config.print_urls = true
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
puts "\n\nUsernames: #{usernames}\n\n"

# Get user's repos
user_id = usernames.first
repos = nil
MyFancyClass.github.users.repos(user_id) do |response|
  repos = response.data
end
puts "\n\nRepos of user '#{user_id}': #{repos.collect { |r| r['name'] }}\n\n"

# The endpoints are available on instances too
fancy = MyFancyClass.new

fancy.github.users do |response|
  puts "\n\nUsing a class' instance. Usernames: #{response.data.collect{ |user| user['login'] }}"
end


# ... and also directly on the ApiRecipes module
response = ApiRecipes.github.users.run
puts "\n\nDirectly calling .github on ApiRecipes module, and without a block: #{response.data}"
