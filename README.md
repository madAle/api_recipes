[![Gem Version](https://img.shields.io/gem/v/api_recipes)](https://rubygems.org/gems/api_recipes)
[![CI](https://github.com/madAle/api_recipes/actions/workflows/ci.yml/badge.svg)](https://github.com/madAle/api_recipes/actions/workflows/ci.yml)

# ApiRecipes

<p align="center">
  <img width="300" height="160" src="api_recipes.png"/>
</p>

Describe an HTTP API once, in YAML, and call it with plain Ruby methods.

```ruby
ApiRecipes.github.users.repos('octocat').run.data
# GET https://api.github.com/users/octocat/repos
# => [{ "name" => "Hello-World", ... }, ...]
```

There are no client classes to write. Hosts, paths, verbs, timeouts and expected
status codes live in a configuration file, and ApiRecipes turns them into a chain
of methods. Requests are made with [http.rb](https://github.com/httprb/http).

## Contents

- [Installation](#installation)
- [Quick start](#quick-start)
- [Describing an API](#describing-an-api)
- [Loading the configuration](#loading-the-configuration)
- [Where an API is available](#where-an-api-is-available)
- [Making requests](#making-requests)
- [Reading the response](#reading-the-response)
- [Deciding what counts as success](#deciding-what-counts-as-success)
- [Handling errors](#handling-errors)
- [Authorization](#authorization)
- [Logging and debugging](#logging-and-debugging)
- [Recipes](#recipes)
- [Options reference](#options-reference)
- [Good to know](#good-to-know)
- [Runnable examples](#runnable-examples)
- [Compatibility](#compatibility)
- [Development](#development)

## Installation

Add the gem to your Gemfile and run `bundle install`:

```ruby
gem 'api_recipes'
```

Or install it directly:

    $ gem install api_recipes

## Quick start

**1. Describe the API** in a YAML file, for example `config/apis/github.yml`:

```yaml
github:
  host: api.github.com
  endpoints:
    users:                # GET /users
      endpoints:
        show:             # GET /users/:login
          path: /:login
        repos:            # GET /users/:login/repos
          path: /:login/repos
```

**2. Load it** once, when your application starts:

```ruby
require 'api_recipes'

ApiRecipes.configure do |config|
  config.apis_files_paths = ['config/apis/github.yml']
end
```

**3. Call it:**

```ruby
response = ApiRecipes.github.users.show('octocat').run

response.code          # => 200
response.data['name']  # => "The Octocat"
```

Each endpoint in the file becomes a method, arguments fill the `:placeholders`
of the path, and `run` sends the request.

## Describing an API

The examples in this guide share one configuration. It is longer than the quick
start because it shows every way of shaping an endpoint:

```yaml
github:
  host: api.github.com
  default_headers:
    Accept: application/vnd.github+json
  endpoints:
    users:                              # GET  /users
      endpoints:
        show:                           # GET  /users/:login
          path: /:login
        repos:                          # GET  /users/:login/repos
          path: /:login/repos
    repos:
      route: no                         # groups the endpoints below, is not callable itself
      path: /repos/:owner/:repo
      endpoints:
        show:                           # GET  /repos/:owner/:repo
          path: ''
        contributors:                   # GET  /repos/:owner/:repo/contributors
        issues:                         # GET  /repos/:owner/:repo/issues
          endpoints:
            create:                     # POST /repos/:owner/:repo/issues
              path: ''
              verb: post
              ok_code: 201
    search:
      route: no
      endpoints:
        repositories:                   # GET  /search/repositories
```

### How a path is built

The path of an endpoint is the path of its parent followed by its own segment:

| In the file | Segment added |
| --- | --- |
| no `path` | the endpoint name: `contributors` adds `/contributors` |
| `path: /something` | that text: `path: /:login/repos` adds `/:login/repos` |
| `path: ''` | nothing: the endpoint has the same URL as its parent |

`path: ''` is how two endpoints share a URL with different verbs, like `issues`
(GET) and `issues.create` (POST) above.

### Path parameters

A `:name` in a path is a placeholder. Values are given, in order, to the method
of the endpoint whose `path` declares them:

```ruby
ApiRecipes.github.users.show('octocat').url.to_s
# => "https://api.github.com/users/octocat"

ApiRecipes.github.repos('rails', 'rails').contributors.url.to_s
# => "https://api.github.com/repos/rails/rails/contributors"
```

The wrong number of values raises `ApiRecipes::PathParamsMismatch`.

### Endpoints that only group others

With `route: no` an endpoint exists only to hold nested endpoints. `search` above
is not callable, `search.repositories` is. Calling `run` on it raises
`ApiRecipes::NoRouteExists`.

### Settings for the whole API

```yaml
billing:
  protocol: http              # default: https
  host: billing_service       # underscores are accepted
  port: 3000                  # default: the port of the protocol
  base_url: api/v1            # prefix of every path
  timeout: 5                  # seconds for the whole request, default: 3
  default_headers:
    Accept: application/json
  endpoints:
    invoices:
      endpoints:
        show:
          path: /:id
```

```ruby
ApiRecipes.billing.invoices.show(42).url.to_s
# => "http://billing_service:3000/api/v1/invoices/42"
```

All options are listed in the [options reference](#options-reference).

## Loading the configuration

Configure ApiRecipes once, before the first request.

### From YAML files

```ruby
ApiRecipes.configure do |config|
  config.apis_files_paths = ['config/apis/github.yml', 'config/apis/billing.yml']
end
```

A file can describe one API or several. If two files describe the same API, the
later one replaces the earlier one entirely.

Files are evaluated with ERB before being parsed, so values can come from the
environment:

```yaml
github:
  host: <%= ENV.fetch('GITHUB_HOST', 'api.github.com') %>
  timeout: <%= ENV.fetch('GITHUB_TIMEOUT', 3) %>
  endpoints:
    users:
```

### From a Hash

```ruby
ApiRecipes.configure do |config|
  config.apis_configs = {
    github: {
      host: 'api.github.com',
      endpoints: {
        users: { endpoints: { show: { path: '/:login' } } }
      }
    }
  }
end
```

Keys can be strings or symbols.

## Where an API is available

### On the `ApiRecipes` module

Every configured API is a method of the module:

```ruby
ApiRecipes.github.users.run
```

### In your classes

Include the module and declare the APIs the class uses. They become available to
the class and to its instances:

```ruby
class GithubProfile
  include ApiRecipes
  api :github

  def self.all
    github.users.run.data
  end

  def initialize(login)
    @login = login
  end

  def repo_names
    github.users.repos(@login).run.data.map { |repo| repo['name'] }
  end
end
```

### With settings of its own

A class can change the configuration it uses. The Hash is merged over the global
one, so only the differences are needed:

```ruby
class EnterpriseProfile
  include ApiRecipes
  api :github, host: 'github.example.com', timeout: 10
end

EnterpriseProfile.github.users.url.to_s
# => "https://github.example.com/users"
```

A class can also declare an API that is not in the global configuration at all:

```ruby
class Forecast
  include ApiRecipes
  api :weather, host: 'api.weather.test',
                endpoints: { forecast: { path: '/forecast/:city' } }
end

Forecast.weather.forecast('rome').url.to_s
# => "https://api.weather.test/forecast/rome"
```

## Making requests

### `run` or a block

`run` sends the request and returns the response:

```ruby
response = ApiRecipes.github.users.show('octocat').run
```

A block does the same and receives the response:

```ruby
ApiRecipes.github.users.show('octocat') do |response|
  puts response.data['name']
end
```

Use `run` when you need the returned value: the block form returns the endpoint,
not the response.

### Query string, body and headers

After the path parameters, an endpoint method takes one Hash of request options.
They are the options of
[http.rb](https://github.com/httprb/http/wiki/Passing-Parameters):

| Option | Sends |
| --- | --- |
| `params:` | a query string |
| `json:` | a JSON body, with `Content-Type: application/json` |
| `form:` | a form-encoded body |
| `body:` | a raw body |
| `headers:` | extra headers for this request only |

```ruby
# GET /search/repositories?q=api%20language:ruby&per_page=5
ApiRecipes.github.search.repositories(params: { q: 'api language:ruby', per_page: 5 }).run

# GET /users/octocat/repos?type=owner
ApiRecipes.github.users.repos('octocat', params: { type: 'owner' }).run

# POST /repos/rails/rails/issues with a JSON body
ApiRecipes.github.repos('rails', 'rails').issues.create(json: { title: 'Found a bug' }).run

# One more header, only for this request
ApiRecipes.github.users.show('octocat', headers: { 'X-Request-Id' => 'abc123' }).run
```

### Verbs

The verb is part of the endpoint description (`verb: post`, `put`, `patch`,
`delete`, `head`...). The default is `get`.

### Looking at the URL without calling it

```ruby
ApiRecipes.github.users.repos('octocat').url.to_s
# => "https://api.github.com/users/octocat/repos"
```

## Reading the response

`run` returns an `ApiRecipes::Response`. It adds `data` and forwards everything
else to the [http.rb response](https://github.com/httprb/http/wiki/Response-Handling):

```ruby
response = ApiRecipes.github.users.show('octocat').run

response.data                     # => { "login" => "octocat", ... }  parsed JSON
response.code                     # => 200
response.status.success?          # => true
response.headers['Content-Type']  # => "application/json; charset=utf-8"
response.body.to_s                # => "{\"login\":\"octocat\", ...}"
```

`data` parses the body according to the `Content-Type` of the response. For
anything that is not JSON, or for an empty body, it raises `HTTP::Error`: read
`response.body.to_s` instead. If a server sends JSON with the wrong
`Content-Type`, set `mime_type: application/json` on the endpoint or on the API.

## Deciding what counts as success

By default any 2xx status is a success and anything else raises
`ApiRecipes::ResponseCodeNotAsExpected`. Three options change that, for one
endpoint or for the whole API.

**Expect one exact status** with `ok_code`:

```yaml
create:
  path: ''
  verb: post
  ok_code: 201        # a 200 is now an error
```

**Never raise** with `on_bad_code: ignore`, and inspect the response yourself:

```yaml
health:
  on_bad_code: ignore
```

```ruby
response = ApiRecipes.status.health.run
response.status.success?   # => false, and no exception
```

**Decide in Ruby** with `verify_with`, the name of a method of the object that
makes the call. It receives the response; a false or nil result makes the call
fail:

```yaml
me:
  path: /user
  verify_with: valid_user?
```

```ruby
class Account
  include ApiRecipes
  api :github

  def current
    github.me.run.data
  end

  private

  def valid_user?(response)
    response.code == 200 && response.data.key?('login')
  end
end
```

The method can be private. It is looked up on the caller, so `verify_with` is
meant for APIs used from a class or an instance.

## Handling errors

```ruby
begin
  ApiRecipes.github.users.show('nobody-here').run
rescue ApiRecipes::ResponseCodeNotAsExpected => e
  e.response.code   # => 404
  e.response.data   # => { "message" => "Not Found", ... }
  e.path            # => "/users/nobody-here"
  e.expected_code   # => "200 <= CODE < 300"
rescue HTTP::TimeoutError
  # the request took longer than `timeout`
rescue HTTP::ConnectionError
  # the server could not be reached
end
```

> **Rescue ApiRecipes errors by name.** They inherit from `Exception`, not from
> `StandardError`, so a bare `rescue` or `rescue => e` does not catch them.

| Error | Raised when |
| --- | --- |
| `ApiRecipes::ResponseCodeNotAsExpected` | the response is not a success; has `response`, `path` and `expected_code` |
| `ApiRecipes::PathParamsMismatch` | an endpoint gets the wrong number of path parameters |
| `ApiRecipes::NoRouteExists` | `run` is called on an endpoint with `route: no` |
| `ApiRecipes::ApiNameClashError` | `api :name` is declared in a class that already has a method `name` |
| `ApiRecipes::ApiConfigIsNotAnHash` | the second argument of `api` is not a Hash |
| `ApiRecipes::RouteNameClashWithExistentMethod` | a nested endpoint has the name of an existing method, such as `url`, `run` or `name` |
| `HTTP::TimeoutError`, `HTTP::ConnectionError` | http.rb network errors; these are `StandardError`s |

## Authorization

Credentials are set on the API of the `ApiRecipes` module. They apply to every
request to that API, including those made from classes that declare it.

**A token**, sent as the `Authorization` header:

```ruby
ApiRecipes.github.authorization = "Bearer #{ENV.fetch('GITHUB_TOKEN')}"
```

**Basic auth:**

```ruby
ApiRecipes.github.basic_auth = { user: 'me', pass: 'secret' }
```

**A different token for one class**, through its own default headers:

```ruby
class AdminClient
  include ApiRecipes
  api :github, default_headers: { 'Authorization' => "Bearer #{ENV.fetch('ADMIN_TOKEN')}" }
end
```

**A different token for one request**, for example the token of the current user:

```ruby
ApiRecipes.github.users.repos('octocat', headers: { 'Authorization' => "Bearer #{user.token}" }).run
```

> Set credentials on `ApiRecipes.github`, not on `MyClass.github`. The second form
> returns a new object at every call, so the value is lost.

## Logging and debugging

```ruby
ApiRecipes.configure do |config|
  config.logger = Rails.logger          # any Logger; set it before the files
  config.print_urls = true              # print every URL to STDOUT as it is built
  config.apis_files_paths = ['config/apis/github.yml']
end
```

Without `logger`, ApiRecipes logs to STDOUT at debug level. `config.log_to`
(a path or an IO) and `config.log_level` (`:debug`, `:info`, `:warn`, `:error`,
`:fatal`) change that without building a Logger.

## Recipes

### Rails setup

```ruby
# config/initializers/api_recipes.rb
ApiRecipes.configure do |config|
  config.logger = Rails.logger
  config.apis_files_paths = Dir[Rails.root.join('config', 'apis', '*.yml').to_s]
end

ApiRecipes.github.authorization = "Bearer #{Rails.application.credentials.github_token}"
```

### One host per environment

Keep one file and let ERB pick the values:

```yaml
billing:
  protocol: <%= ENV.fetch('BILLING_PROTOCOL', 'https') %>
  host: <%= ENV.fetch('BILLING_HOST', 'billing.example.com') %>
  endpoints:
    invoices:
```

### Every page of a list

```ruby
def all_repos(login)
  repos = []
  page = 1
  loop do
    batch = ApiRecipes.github.users.repos(login, params: { per_page: 100, page: page }).run.data
    repos.concat(batch)
    break if batch.size < 100
    page += 1
  end
  repos
end
```

### Creating a resource

```ruby
response = ApiRecipes.github.repos('rails', 'rails').issues.create(
  json: { title: 'Found a bug', labels: ['bug'] }
).run

response.code            # => 201
response.data['number']  # => 1347
```

### A token per user in a multi-threaded application

Credentials set with `authorization=` are shared by the whole process. When each
user has a token, pass it with the request instead:

```ruby
class UserRepos
  def initialize(user)
    @headers = { 'Authorization' => "Bearer #{user.github_token}" }
  end

  def names
    ApiRecipes.github.users.repos('octocat', headers: @headers).run.data.map { |repo| repo['name'] }
  end
end
```

### A health check that never raises

```yaml
status:
  host: status.example.com
  timeout: 1
  on_bad_code: ignore
  endpoints:
    health:
```

```ruby
def service_up?
  ApiRecipes.status.health.run.status.success?
rescue HTTP::Error      # timeout, refused connection, DNS failure
  false
end
```

### Returning nil when a record does not exist

```ruby
def find_user(login)
  ApiRecipes.github.users.show(login).run.data
rescue ApiRecipes::ResponseCodeNotAsExpected => e
  raise unless e.response.code == 404
  nil
end
```

### Testing code that uses ApiRecipes

Stub the HTTP layer with [WebMock](https://github.com/bblimke/webmock); nothing in
ApiRecipes needs to be mocked. Send a `Content-Type`, or `data` cannot parse the
body:

```ruby
require 'webmock/rspec'

RSpec.describe GithubProfile do
  it 'lists the repository names' do
    stub_request(:get, 'https://api.github.com/users/octocat/repos')
      .to_return(status: 200,
                 body: [{ name: 'hello-world' }].to_json,
                 headers: { 'Content-Type' => 'application/json' })

    expect(GithubProfile.new('octocat').repo_names).to eq(['hello-world'])
  end
end
```

If your tests configure ApiRecipes themselves, `ApiRecipes.reset!` removes the
global configuration and the API methods defined on the module, so each example
can start clean:

```ruby
RSpec.configure do |config|
  config.before(:each) { ApiRecipes.reset! }
end
```

## Options reference

### `ApiRecipes.configure`

| Option | Meaning |
| --- | --- |
| `apis_files_paths` | Array of YAML files, evaluated with ERB |
| `apis_configs` | Hash of API descriptions |
| `logger` | a Logger to use |
| `log_to` | path or IO for the default logger (default: STDOUT) |
| `log_level` | level of the default logger (default: the `LOG_LEVEL` variable, or debug) |
| `print_urls` | print each URL to STDOUT when it is built (default: false) |

### API

| Option | Default | Meaning |
| --- | --- | --- |
| `protocol` | `https` | `http` or `https` |
| `host` | `localhost` | host name |
| `port` | port of the protocol | port number |
| `base_url` | none | prefix of every path, for example `api/v1` |
| `timeout` | `3` | seconds allowed for the whole request |
| `default_headers` | none | headers sent with every request |
| `on_bad_code` | `raise` | `raise` or `ignore` when the response is not a success |
| `mime_type` | from the response | content type used by `response.data` |
| `verify_with` | none | method that decides whether a response is a success |
| `endpoints` | none | the endpoints of the API |

### Endpoint

| Option | Default | Meaning |
| --- | --- | --- |
| `path` | the endpoint name | segment added to the parent path; `''` adds nothing |
| `verb` | `get` | HTTP verb |
| `route` | `yes` | `no` makes the endpoint a group that cannot be called |
| `ok_code` | any 2xx | the only status accepted as a success |
| `timeout` | the API value | seconds allowed for the whole request |
| `on_bad_code` | the API value | `raise` or `ignore` |
| `mime_type` | the API value | content type used by `response.data` |
| `verify_with` | the API or parent value | method that decides whether a response is a success |
| `endpoints` | none | nested endpoints |

An endpoint takes `timeout`, `on_bad_code` and `mime_type` from the API, not from
the endpoint that contains it.

## Good to know

- **Configure before the first request.** A class keeps the configuration it saw
  the first time it used its API.
- **Unknown options are ignored without a message.** If an option seems to have
  no effect, check its spelling: the verb is `verb`, not `method`.
- **Path parameters are not encoded.** A value containing `/` spans two path
  segments, and `nil` or an empty string produce the URL of the parent
  (`/users/`). Check values that come from user input, and encode them with
  `ERB::Util.url_encode` when they can contain reserved characters.
- **Credentials are shared by the whole process.** For a token per user, see
  [the recipe above](#a-token-per-user-in-a-multi-threaded-application).
- **Some names are taken.** An endpoint cannot be called like a method its parent
  already has. Directly under the API, such an endpoint (`name`, `configs`,
  `object`) is skipped without a message; a nested one (`url`, `run`, `name`,
  `params`, `route`, `children`) raises `RouteNameClashWithExistentMethod`. An
  API must not be called `configure`, `configuration`, `logger` or `print_urls`:
  it would replace that method of the module.
- **Core extensions.** The gem adds a few methods to `Hash` and `Array`
  (`deep_symbolize_keys`, `deep_merge`, `extract_options!` and similar, with the
  same behaviour as in ActiveSupport). With the uri gem older than 1.0 it also
  makes `URI` accept underscores in host names.

## Runnable examples

The [`examples`](examples) folder contains scripts that call public APIs:

| Script | Shows |
| --- | --- |
| `simple_usage.rb` | configuration from a YAML file; class, instance and module access |
| `direct_configuration.rb` | an API described directly in a class |
| `manual_configs.rb` | configuration from a Hash; nested endpoints with path parameters |
| `multiple_endpoints.rb` | two APIs from two files |
| `authorization.rb` | token authorization |
| `basic_auth.rb` | basic auth |
| `authorization_with_default_headers.rb` | a token for one class, through default headers |

Run one from the root of the repository:

    $ bundle exec ruby examples/simple_usage.rb

[`examples/config/github.yml.erb`](examples/config/github.yml.erb) is a
configuration file with every option commented.

## Compatibility

- Ruby 2.7 or higher. The test suite runs on the maintained versions: 3.3, 3.4 and 4.0
- http.rb 6.0.4 or higher
- uri 0.x and 1.x

## Development

    $ bundle install
    $ bundle exec rspec

The specs never use the network. To run them against a specific version of the
uri gem:

    $ URI_VERSION='~> 1.0' bundle exec rspec

What is planned for the next releases is in the [roadmap](docs/ROADMAP.md).

Bug reports and pull requests are welcome on
[GitHub](https://github.com/madAle/api_recipes). Contributors are expected to
follow the [Contributor Covenant](CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the
[MIT License](http://opensource.org/licenses/MIT).
