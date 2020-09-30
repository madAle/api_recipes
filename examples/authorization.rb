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

  # Declare the endpoints that we're going to use
  api :github
end

# Setup Auth. This will set/replace the HTTP 'Authorization' header with the
# provided value

# Get your OAUTH token on Github.
# Navigate Profile => Settings => Developer Settings => Personal Access Tokens => Generate new token
# Copy the generated string and set the env variable
# e.g.  GITHUB_OAUTH_TOKEN=your_token bundle exec ruby examples/authorization.rb
MyFancyClass.github.authorization = "token #{ENV['GITHUB_OAUTH_TOKEN']}"

# From now on every MyFancyClass (and its instances) github's api request will
# be authenticated through the provided auth

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
