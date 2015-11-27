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
  endpoint :jsonplaceholder
  endpoint :github
end

# Get users from JSONPlaceholder (http://jsonplaceholder.typicode.com/users)
MyFancyClass.jsonplaceholder.users.list do |users|
  puts 'Usernames:'
  puts users.collect{ |user| user['name'] }
end

# Get posts from JSONPlaceholder (http://jsonplaceholder.typicode.com/posts)
post_ids = nil
MyFancyClass.jsonplaceholder.posts.list do |posts|
  post_ids = posts.map{ |post| post['id'] }
end

puts "\n\n\n\n"
# Get first post's comments from JSONPlaceholder
# http://jsonplaceholder.typicode.com/posts/1/comments
MyFancyClass.jsonplaceholder.posts.comments(post_id: post_ids.first) do |comments|
  puts "Comments:"
  puts comments
end

puts "\n\n\n\n"
# Get also Github users
# Warning: Github has a low rate limit for unauthorized api requests.
MyFancyClass.github.users.list do |body, status_code, status_message|
  puts "Response: #{status_code}: #{status_message}"
  puts "Data: #{body}"
end

# If you need a 'raw' response (e.g. the response must not automatically be
# parsed as JSON) just don't provide a block and the result will be an
# HTTP::Response object. See https://github.com/httprb/http for further details

response = MyFancyClass.github.users.list
puts response.code    # e.g. 200
puts response.reason  # e.g. OK
puts response.body    # e.g  Some response body (not necessarely JSON)
