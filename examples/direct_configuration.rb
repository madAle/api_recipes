# This example aims to demonstrate how to provide direct configurations for an API

require 'api_recipes'

# Configure ApiRecipes through custom settings

FAKE_API_SETTINGS = {
    host: 'jsonplaceholder.typicode.com',
    timeout: 10,
    endpoints: {
        users: {
            endpoints: {
                show: {
                    path: '/:user_id'
                }
            }
        },
        posts: {
            endpoints: {
                comments: {
                    path: '/:post_id/comments'
                }
            }
        }
    }
}

# Let's create a simple class that uses ApiRecipes
class MyFancyClass
  include ApiRecipes

  # Declare the apis that we're going to use
  api :fake_api, FAKE_API_SETTINGS
end

# Let's demonstrate that even a class instance can use enpoints
fancy_instance = MyFancyClass.new

# Get User's names
fancy_instance.fake_api.users do |response|
  names = response.data.collect{ |user| user['name'] }
  puts "Names: #{names}\n\n"
end

# Collect post ids
post_ids = nil
MyFancyClass.fake_api.posts do |response|
  post_ids = response.data.map{ |post| post['id'] }
end

# Fetch post's comments
last_post_id = post_ids.last
comments = nil
fancy_instance.fake_api.posts.comments(last_post_id) do |response|
  comments = response.data
  puts "Last post's comments: #{comments}"
end
