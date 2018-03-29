# This example aims to demonstrate how to provide custom configs to endpoints

require 'api_recipes'

# Configure RemoteApi through custom settings
FAKE_API_SETTINGS = {
    host: 'jsonplaceholder.typicode.com',
    timeout: 10,
    routes: {
        users: {
            list: nil,
            show: {
                path: '/:user_id'
            }
        },
        posts: {
            list: nil,
            comments: {
                path: '/:post_id/comments'
            }
        }
    }
}

# Let's create a simple class that uses ApiRecipes
class MyFancyClass
  include ApiRecipes

  # Declare the endpoints that we're going to use
  endpoint :fake_api, FAKE_API_SETTINGS
end

# Let's demonstrate that even a class instance can use enpoints
fancy_instance = MyFancyClass.new

# Get User's names
fancy_instance.fake_api.users.list do |users|
  names = users.collect{ |user| user['name'] }
  puts "Names: #{names}"
end

# Collect post ids
post_ids = nil
MyFancyClass.fake_api.posts.list do |posts|
  post_ids = posts.map{ |post| post['id'] }
end

# Fetch post's comments
fancy_instance.fake_api.posts.comments(post_id: post_ids.last) do |comments|
  puts "Comments: #{comments}"
end
