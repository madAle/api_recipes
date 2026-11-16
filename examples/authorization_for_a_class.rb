require 'api_recipes'

# Take a look at examples/config/github.yml.erb  for a full list of available options
ApiRecipes.configure do |config|
  config.apis_files_paths = ['examples/config/github.yml.erb']
end

# Get your OAUTH token on Github.
# Navigate Profile => Settings => Developer Settings => Personal Access Tokens => Generate new token
# Copy the generated string and set the env variable
# e.g.  GITHUB_OAUTH_TOKEN=your_token bundle exec ruby examples/authorization_for_a_class.rb

# Let's create a simple class that uses ApiRecipes
class MyFancyClass
  include ApiRecipes

  # Declare the apis that we're going to use. A credential belongs to the whole
  # application, to a class, to an object or to one chain. Here the class gives
  # it where it declares the api: it is used by MyFancyClass, its subclasses
  # and their objects, and by nobody else.
  api :github, authorization: "token #{ENV.fetch('GITHUB_OAUTH_TOKEN')}"
end

# From now on every MyFancyClass (and its instances) github's api request will
# be authenticated through the provided Authorization header.
# A class that changes the host of the api needs a credential of its own.

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
