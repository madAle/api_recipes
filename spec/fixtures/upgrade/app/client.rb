class Client
  def all
    endpoint = ApiRecipes.github.users
    endpoint.run
    endpoint.route.fill(User)
  rescue => e
    ApiRecipes.print_urls = true
  end

  def one(login) = ApiRecipes.github.users.show(ERB::Util.url_encode(login)).run
end
