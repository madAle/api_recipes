require 'api_recipes'
require 'yaml'

ApiRecipes.configure do |config|
  config.apis_configs = YAML.load_file(File.expand_path('examples/config/apis.yml'))
end

class Foo
  include ApiRecipes

  api :jsonplaceholder
end

puts 'Use from class:'
puts Foo.jsonplaceholder.users
f1 = Foo.new

puts "\n\nUse from instance:"
puts f1.jsonplaceholder.users
