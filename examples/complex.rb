require 'api_recipes'
require 'yaml'

# Configure ApiRecipes through a yaml file.
# Take a look at examples/config/apis.yml  for details
ApiRecipes.configure do |config|
  config.apis_configs = YAML.load_file(File.expand_path('examples/config/apis.yml'))
  config.print_urls = true
end

# Let's create a simple class that uses ApiRecipes
class MyFancyClass
  include ApiRecipes

  api :github
end

fancy_instance = MyFancyClass.new

usernames = nil
fancy_instance.github.users do |response|
  usernames = response.data.collect{ |user| user['login'] }
end
puts "Usernames: #{usernames}\n\n"

# Select a random user
user_id = usernames.sample

# Retrieve user repos
repos = nil
fancy_instance.github.users.repos(user_id) do |response|
  repos = response.data#.map{ |post| post['id'] }
end

# Select a random repo
repo = repos.sample
repo_name = repo['name']

# Show a repository
repository = nil
fancy_instance.github.repos(user_id, repo_name).show do |response|
  repository = response.data
end
puts "Repository '#{repo_name}' details:\n\n#{repository}\n\n"

contributors = nil
fancy_instance.github.repos(user_id, repo_name).contributors do |response|
  contributors = response.data.map{ |post| post['login'] }
end
puts "Repository '#{repo_name}' contributors: #{contributors}\n\n"
