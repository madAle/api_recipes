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

  # Declare the apis that we're going to use
  api :jsonplaceholder
  api :github
end

# Get users from JSONPlaceholder (http://jsonplaceholder.typicode.com/users)
MyFancyClass.jsonplaceholder.users do |response|
  puts "Usernames: #{response.data.collect{ |user| user['name'] }}"
end

puts "\n\n\n\n"
# Get also Github users
# Warning: Github has a low rate limit for unauthorized api requests.
MyFancyClass.github.users do |response|
  puts "Response HTTP status code: #{response.code}"
end
