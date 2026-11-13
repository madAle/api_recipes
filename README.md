[![Gem Version](https://img.shields.io/gem/v/api_recipes)](https://rubygems.org/gems/api_recipes)
[![CI](https://github.com/madAle/api_recipes/actions/workflows/ci.yml/badge.svg)](https://github.com/madAle/api_recipes/actions/workflows/ci.yml)

# ApiRecipes

<p align="center">
  <img width="300" height="160" src="api_recipes.png"/>
</p>

Describe an HTTP API once, in YAML, and call it with plain Ruby methods.

```ruby
ApiRecipes.github.users.repos('octocat') do |response|
  response.data.each { |repo| puts repo['name'] }
end
# GET https://api.github.com/users/octocat/repos
# prints "Hello-World" and the other repository names
```

There are no client classes to write. Hosts, paths, verbs, timeouts and expected
status codes live in a configuration file, and ApiRecipes turns them into a chain
of methods. Requests are made with [http.rb](https://github.com/httprb/http).

Coming from version 2? Read [UPGRADING.md](UPGRADING.md) first.

## Contents

- [Installation](#installation)
- [Quick start](#quick-start)
- [Describing an API](#describing-an-api)
- [Variables](#variables)
- [Loading the configuration](#loading-the-configuration)
- [Where an API is available](#where-an-api-is-available)
- [Making requests](#making-requests)
- [Options for one chain: `with`](#options-for-one-chain-with)
- [Reaching an endpoint by name: `[]`](#reaching-an-endpoint-by-name-)
- [Reading the response](#reading-the-response)
- [Deciding what counts as success](#deciding-what-counts-as-success)
- [Handling errors](#handling-errors)
- [Authorization](#authorization)
- [Logging and debugging](#logging-and-debugging)
- [Inspecting an API](#inspecting-an-api)
- [Recipes](#recipes)
- [Security](#security)
- [Options reference](#options-reference)
- [Good to know](#good-to-know)
- [Runnable examples](#runnable-examples)
- [Compatibility](#compatibility)
- [Upgrading from 2.x](#upgrading-from-2x)
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
response.data['name']
# => "The Octocat"
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
        contents:                       # GET  /repos/:owner/:repo/contents/*path
          path: /contents/*path
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

The configuration is checked when it is loaded. A mistake, such as an unknown
option, a verb that does not exist or a negative timeout, raises
`ApiRecipes::ConfigurationError`. Its message lists every problem at once, so you
fix them in one go. Keys that start with `x-` are free: ApiRecipes ignores them,
and you can use them for your own notes.

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

ApiRecipes encodes each value for you, so a value cannot add segments, a query
string or a fragment to the URL:

```ruby
ApiRecipes.github.users.show('Jane Doe').url.to_s
# => "https://api.github.com/users/Jane%20Doe"

ApiRecipes.github.users.show('a/b').url.to_s
# => "https://api.github.com/users/a%2Fb"
```

Do not encode values yourself: `%2F` would be sent as `%252F`. A value that is
`nil`, empty, `.` or `..` raises `ApiRecipes::InvalidPathParameter`.

When a value really is several segments, such as the path of a file, write the
placeholder with a `*`. Each segment is encoded and the slashes stay:

```ruby
ApiRecipes.github.repos('rails', 'rails').contents('lib/rails.rb').url.to_s
# => "https://api.github.com/repos/rails/rails/contents/lib/rails.rb"
```

A `*name` placeholder works only at the start of a segment, and a `:` that must
stay in the path is written `\:`.

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

`host` is a plain host name: no scheme, port, path or spaces. Use `protocol` and
`port` for those. A `base_url` cannot contain a `:name` or `*name` placeholder;
for a value that changes, use a [variable](#variables).

All options are listed in the [options reference](#options-reference).

## Variables

A variable is a `{name}` placeholder in the `host`, the `base_url` or the value
of a header. Use it for what changes from one account or one environment to the
next, such as the address of a shop. Declare the variables of the API, with an
optional `default` and `description`:

```yaml
shopify:
  variables:
    shop:
      description: the part of the shop address before .myshopify.com
    api_version:
      default: '2026-10'
  host: '{shop}.myshopify.com'
  base_url: admin/api/{api_version}
  auth:
    type: header
    name: X-Shopify-Access-Token
  endpoints:
    products:
```

A variable without a value and without a default raises
`ApiRecipes::MissingVariable` when the request is built. Give it a value in the
way that fits your code. The nearest one wins: the chain (`with`), then the
object, then its class, then `ApiRecipes.shopify`, then the default of the file.

```ruby
ApiRecipes.shopify.with(variables: { shop: 'acme' }).products.url.to_s
# => "https://acme.myshopify.com/admin/api/2026-10/products"

ApiRecipes.shopify.variables = { shop: 'acme' }
ApiRecipes.shopify.products.url.to_s
# => "https://acme.myshopify.com/admin/api/2026-10/products"

ApiRecipes.shopify.with(variables: { api_version: '2027-01' }).products.url.to_s
# => "https://acme.myshopify.com/admin/api/2027-01/products"
```

For one class, or for the objects of a class:

```ruby
class Store
  include ApiRecipes
  api :shopify, variables: { shop: 'acme' }
end

Store.shopify.products.url.to_s
# => "https://acme.myshopify.com/admin/api/2026-10/products"

store = Store.new
store.shopify.variables = { shop: 'zed' }
store.shopify.products.url.to_s
# => "https://zed.myshopify.com/admin/api/2026-10/products"
```

Or for everybody, when the application starts:

```ruby
ApiRecipes.configure do |config|
  config.variables = { shopify: { shop: 'acme' } }
end
```

ApiRecipes never reads the environment for you: if the shop comes from an
environment variable, read it in your code and pass it in.

A value is checked for the place where it ends up. In a `host` it can contain
only letters, digits, dots, hyphens and underscores. In a `base_url` it is
encoded like a path parameter. In a header it cannot contain a line break or
another control character. Anything else raises `ApiRecipes::InvalidVariable`.
A name that the API does not declare raises `ApiRecipes::ConfigurationError` at
every level, so a misspelled name is never ignored.
`variables` without an assignment returns the values set at the level you call
it on. Assigning `nil` clears them. At the global level (`ApiRecipes.shopify`)
that includes the values given with `config.variables`, which are the same level;
a default declared in the file applies again.

## Loading the configuration

Configure ApiRecipes once, when your application starts.

### From YAML files

```ruby
ApiRecipes.configure do |config|
  config.apis_files_paths = ['config/apis/github.yml', 'config/apis/billing.yml']
end
```

A file can describe one API or several. If two files describe the same API, the
later one replaces the earlier one entirely. The same holds for the sources
together: they are applied in the order they are assigned, so assigning
`apis_configs` after `apis_files_paths` lets the Hash replace the file.

A file that is missing, empty, not valid YAML or not valid UTF-8 raises
`ApiRecipes::RecipeFileError`, which names the file. A file called
`something.recipe.yml` is refused: that name is kept for another purpose.

Files are evaluated with ERB before being parsed, so values can come from the
environment:

```yaml
billing:
  host: <%= ENV.fetch('BILLING_HOST', 'billing.example.com') %>
  timeout: <%= ENV.fetch('BILLING_TIMEOUT', 3) %>
  endpoints:
    invoices:
```

Only files you wrote and trust should be loaded: ERB runs the Ruby code in them.

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

Keys can be strings or symbols, but not both for the same option.

If the configuration has a problem, `configure` raises and the previous
configuration stays active.

## Where an API is available

### On the `ApiRecipes` module

Every configured API is a method of the module, and `ApiRecipes[...]` reaches the
same API by name, which is handy when the name is in a variable:

```ruby
ApiRecipes.github.users.run
ApiRecipes[:github].users.run
```

`ApiRecipes.apis` lists the names:

```ruby
ApiRecipes.apis.inspect
# => "[:github, :billing, :shopify]"
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

`api :github, as: :gh` gives the method another name. An API is declared once in
a class and its ancestors, modules included: declaring it twice raises
`ApiRecipes::ApiNameClashError`. If a subclass needs other options, use
[`with`](#options-for-one-chain-with). A singleton class cannot declare an API
(`ApiRecipes::ApiNameClashError`): declare it in a module and `extend` the object
with it.

An API declared in a module is available as an instance method of every class
that includes the module, and as `Module.name_of_api` on the module itself. The
including class gets no class-level method.

A credential or a variable set through one declaration is never seen by another
declaration of the same API name.

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

The options are checked like the ones in a file. When a class changes the
destination, with its own `host`, `protocol` or `port`, it needs a credential of
its own: see [Authorization](#authorization).

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
not the response. `run` with a block yields the response and returns it.

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
| `follow:` | follow redirects: `true`, or a Hash with `strict`, `max_hops` and `on_redirect` |

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

An option http.rb does not know raises its own `ArgumentError`. `follow` accepts
`true`, `false`, `nil` or a Hash with the keys above, and anything else raises
`ApiRecipes::ConfigurationError` before the request is sent.

When a redirect leads to another origin (another scheme, host or port), the
`Authorization` header, the header named by `auth.name`, the `Cookie` header and
the credential query parameter are not sent there, wherever they came from.
Cookies that a server sets during a chain of redirects are not carried to the
next hop.

### Verbs

The verb is part of the endpoint description (`verb: post`, `put`, `patch`,
`delete`, `head`...). The default is `get`.

### Looking at the URL without calling it

```ruby
ApiRecipes.github.users.repos('octocat').url.to_s
# => "https://api.github.com/users/octocat/repos"
```

`url` sends nothing and has no query string. For an endpoint with `route: no` it
returns `nil`.

## Options for one chain: `with`

`with` returns a copy of the API with some options changed. The copy is used for
the chain that follows it, and nothing is stored: the API itself does not change.

```ruby
ApiRecipes.github.with(host: 'github.example.com').users.show('octocat').url.to_s
# => "https://github.example.com/users/octocat"
```

On an API, `with` takes `protocol`, `host`, `port`, `base_url`, `timeout`,
`on_bad_code`, `mime_type`, `verify_with`, `default_headers`, `variables`,
`authorization` and `basic_auth`. The values are checked like the ones in a file,
and an option that is not in this list raises `ApiRecipes::ConfigurationError`.

On an endpoint, `with` takes `timeout`, `on_bad_code`, `ok_code`, `mime_type` and
`verify_with`, for that request only:

```ruby
ApiRecipes.github.users.show('octocat').with(timeout: 10, ok_code: [200, 304]).run
```

Giving an option as `nil` drops the value given before it in the same chain.
`default_headers` given to `with` are added to the ones already configured:

```ruby
ApiRecipes.github.with(default_headers: { 'X-Request-Id' => 'abc123' }).users.run
```

The other way of changing an API for a while is `api :name, options` in a class.

## Reaching an endpoint by name: `[]`

Every endpoint can be reached with `[]`, with a name that is a Symbol or a
String. The arguments after the name are the path parameters:

```ruby
ApiRecipes.github[:users][:show, 'octocat'].url.to_s
# => "https://api.github.com/users/octocat"
```

It is the same call as `github.users.show('octocat')`. Use it when the name is
in a variable, and for an endpoint whose name is already a method (see
[Good to know](#good-to-know)). A name that does not exist raises
`ApiRecipes::UnknownEndpoint`, and its message lists the available names.

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

`response.success?` tells whether the response passed the rule of the endpoint
(see the next section). It is the way to check a response when `on_bad_code` is
`ignore`.

`response.uri` is the address that was requested. When the API sends its
credential in the query string, the parameter is left out of it.

### Filling an object

`fill` copies the data into an object, through its public writers:

```ruby
class Profile
  attr_accessor :login, :name
end

profile = ApiRecipes.github.users.show('octocat').run.fill(Profile.new)
profile.login
# => "octocat"

ApiRecipes.github.users.show('octocat').run.fill(Profile.new, only: :login).name.nil?
# => "true"
```

Given an Array, `fill` takes a class and returns one new object per element. Keys
that the object has no writer for, or that are not plain attribute names, are
skipped. `only:` and `except:` take one name or a list, as Symbols or Strings.
An error raised by a writer is not hidden.

With a block, `fill` calls it with the filled object (or the list of objects),
the parsed data and the status of the response, and still returns the filled
object:

```ruby
ApiRecipes.github.users.show('octocat').run.fill(Profile.new) do |profile, data, status|
  puts "#{status}: #{profile.login}"
end
```

## Deciding what counts as success

By default any 2xx status is a success and anything else raises
`ApiRecipes::ResponseCodeNotAsExpected`. Three options change that, for one
endpoint or for the whole API.

**Expect given statuses** with `ok_code`, one status or a list:

```yaml
create:
  path: ''
  verb: post
  ok_code: 201        # a 200 is now an error
```

```yaml
refresh:
  ok_code: [200, 304]
```

**Never raise** with `on_bad_code: ignore`, and inspect the response yourself:

```yaml
health:
  on_bad_code: ignore
```

```ruby
response = ApiRecipes.status.health.run
response.success?   # => false, and no exception
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
meant for APIs used from a class or an instance. A nested endpoint that has no
`verify_with` of its own uses the one of its parent.

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

Every error of ApiRecipes inherits from `ApiRecipes::Error`, which is a
`StandardError`. A bare `rescue` catches them, so rescue by name when you want
to treat them differently. The message of an error never contains the response
body, a credential or a query string: the body is on `error.response`.

| Error | Raised when |
| --- | --- |
| `ApiRecipes::ResponseCodeNotAsExpected` | the response is not a success; has `response`, `path` and `expected_code` |
| `ApiRecipes::PathParamsMismatch` | an endpoint gets the wrong number of path parameters |
| `ApiRecipes::InvalidPathParameter` | a path parameter is `nil`, empty, `.` or `..` |
| `ApiRecipes::NoRouteExists` | `run` is called on an endpoint with `route: no` |
| `ApiRecipes::UnknownEndpoint` | `[]` gets a name that does not exist |
| `ApiRecipes::MissingVariable` | a variable has no value and no default |
| `ApiRecipes::InvalidVariable` | the value of a variable is not allowed where it is used |
| `ApiRecipes::InvalidCredential` | a credential is not a String, or contains a line break or a control character |
| `ApiRecipes::CredentialOriginMismatch` | a request would send a credential to an origin other than the one it was set for |
| `ApiRecipes::InvalidUrl` | the address that would be contacted is not the one that was validated |
| `ApiRecipes::ConfigurationError` | the configuration or the options of `with` or `follow` are not valid; has `errors`, the list of problems |
| `ApiRecipes::RecipeFileError` | a configuration file cannot be read; a kind of `ConfigurationError` that names the file |
| `ApiRecipes::ApiNameClashError` | an API is declared twice in a class hierarchy, or `api :name` names a method the class already has |
| `ApiRecipes::ApiConfigIsNotAnHash` | the second argument of `api` is not a Hash |
| `HTTP::TimeoutError`, `HTTP::ConnectionError` | http.rb network errors |

## Authorization

A credential belongs to a level, and a request uses the nearest one. From the
nearest to the farthest:

1. the chain, with `with(authorization: ...)` or `with(basic_auth: ...)`
2. the object that makes the call
3. its class, then the classes and modules it inherits from
4. the API of the `ApiRecipes` module

**A token**, sent as the `Authorization` header, as it is written:

```ruby
ApiRecipes.github.authorization = "Bearer #{ENV.fetch('GITHUB_TOKEN')}"
```

**Basic auth:**

```ruby
ApiRecipes.github.basic_auth = { user: 'me', pass: 'secret' }
```

**A different token for one class.** It applies to the class and its instances:

```ruby
class AdminClient
  include ApiRecipes
  api :github
end

AdminClient.github.authorization = "Bearer #{ENV.fetch('ADMIN_TOKEN')}"
```

**A different token for one object**, for example one object per user:

```ruby
class UserRepos
  include ApiRecipes
  api :github

  def initialize(user)
    github.authorization = "Bearer #{user.github_token}"
  end
end
```

**A different token for one chain**, for example the token of the current user:

```ruby
ApiRecipes.github.with(authorization: "Bearer #{user.token}").users.repos('octocat').run
```

The reader returns what the nearest level assigned:

```ruby
ApiRecipes.github.authorization = 'Bearer abc'
ApiRecipes.github.authorization
# => "Bearer abc"
```

**No credential.** Assigning `nil` means "send none" and ends the search: it
does not fall back to a level farther away. The same goes for
`with(authorization: nil)`:

```ruby
AdminClient.github.authorization = nil               # this class sends none
ApiRecipes.github.with(authorization: nil).users.run  # this chain sends none
```

`authorization=`, `basic_auth=` and `variables=` change the level of the object
they are called on. They raise on an API that `with` returned: use
`with(authorization: ...)` there.

A credential is valid only for the origin it was set for: the scheme, the host
and the port. If a nearer level changes the destination (its own `host`,
`protocol` or `port`, or a variable of the host) and does not set a credential of
its own, the request raises `ApiRecipes::CredentialOriginMismatch` instead of
sending the credential somewhere else. Set the credential where you change the
destination:

```ruby
class EnterpriseClient
  include ApiRecipes
  api :github, host: 'github.example.com'
end

EnterpriseClient.github.authorization = "Bearer #{ENV.fetch('ENTERPRISE_TOKEN')}"
```

The readers `authorization` and `basic_auth` return the nearest credential that
was assigned. They do not apply that check: only a request does.

A credential with a line break or another control character raises
`ApiRecipes::InvalidCredential`. The message never contains the value. A client
restored from a serialized form has no credential.

An API can say where its credential goes with `auth`:

| `auth.type` | The credential assigned with `authorization=` goes |
| --- | --- |
| none of these, or `none`, `bearer`, `basic` | in the `Authorization` header, as it is written |
| `header`, with a `name` | in the header called `name` |
| `query`, with a `name` | in the query parameter called `name` |

```yaml
weather:
  host: api.weather.test
  auth:
    type: query
    name: api_key
  endpoints:
    forecast:
```

Basic auth cannot be sent to an API of type `header` or `query`: the request
raises `ApiRecipes::InvalidCredential`. Assign the value with `authorization=`.

A credential written in `headers:` or in `default_headers` is sent as it is.
ApiRecipes does not check its origin, so prefer the levels above.

## Logging and debugging

```ruby
ApiRecipes.configure do |config|
  config.logger = Rails.logger          # any Logger
  config.print_urls = true              # log the URL of every request
  config.apis_files_paths = ['config/apis/github.yml']
end
```

Without `logger`, ApiRecipes logs to STDERR at warn level, so normal use prints
nothing and a problem shows up. `config.log_to` (a path or an IO) and
`config.log_level` (`:debug`, `:info`, `:warn`, `:error`, `:fatal`) change that
without building a Logger. Without `log_level`, the `LOG_LEVEL` environment
variable is used, in any letter case; a value that is not a level is ignored.

- The level of the default logger is, in this order: `log_level`; the `LOG_LEVEL`
  variable; info when `print_urls` is on; otherwise warn. A level you chose is
  never lowered by `print_urls`. A logger you provide keeps its own level.
- `print_urls = true` logs the URL of each request at info level.
- At debug level, every request logs one line: the verb, the URL, the status and
  the time it took. A response with a bad status that raises is logged too. A
  request whose connection fails or times out logs nothing.
- A log line never contains a query string, a header, a body or a credential.
- `ApiRecipes.logger` is the logger in use, and `ApiRecipes.configuration` is the
  current configuration. Change the configuration only inside `configure`.

At the start, ApiRecipes logs one warning for each endpoint whose name cannot
become a method, when the configuration is loaded (see
[Good to know](#good-to-know)).

It also warns, once for each endpoint, when the value of a path parameter
contains a `/` (it is sent as `%2F`) or looks already percent-encoded (it is
encoded again). The warning names the endpoint and never the value.
`config.upgrade_warnings = false` turns these two warnings off.

## Inspecting an API

`inspect` is made for the console. It shows the name and the origin, and never a
credential, a header, a body or a query string:

```ruby
ApiRecipes.github.inspect
# => "#<ApiRecipes::Api github https://api.github.com endpoints: users, repos, search>"

ApiRecipes.github.users.show('octocat').inspect
# => "#<ApiRecipes::Endpoint github.users.show GET https://api.github.com/users/octocat>"
```

`definition` returns a read-only description of an API or of an endpoint:

```ruby
ApiRecipes.github.definition.host
# => "api.github.com"

ApiRecipes.github.users.show('octocat').definition.full_path
# => "/users/:login"
```

For an API: `name`, `protocol`, `host`, `port`, `base_url`, `timeout`,
`on_bad_code`, `mime_type`, `verify_with`, `default_headers`, `auth`,
`variables`, `endpoints`, `routes` and `to_h`. For an endpoint: `name`,
`full_name`, `path`, `full_path`, `path_params`, `verb`, `route?`, `ok_code`,
`timeout`, `on_bad_code`, `mime_type`, `verify_with`, `parent`, `endpoints` and
`to_h`. A definition never holds a credential assigned with `authorization=`,
`basic_auth=` or `with`, nor the value of a variable. It does return the
`default_headers` as they are configured, so do not write a credential there if
you pass definitions around; `to_h` and `inspect` hide the values of the headers.

`routes` lists every endpoint that can be called, with the call that reaches it:

```ruby
route = ApiRecipes.github.definition.routes.find { |r| r.call.end_with?('.contributors') }
[route.call, route.verb, route.url].join(' ')
# => "github.repos(owner, repo).contributors get https://api.github.com/repos/:owner/:repo/contributors"
```

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
reports:
  protocol: <%= ENV.fetch('REPORTS_PROTOCOL', 'https') %>
  host: <%= ENV.fetch('REPORTS_HOST', 'reports.example.com') %>
  endpoints:
    monthly:
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

### A token per user

Give each user's object its own credential, or pass it with the chain, and the
users never see each other's token:

```ruby
class UserRepos
  include ApiRecipes
  api :github

  def initialize(user)
    @token = user.github_token
  end

  def names
    github.with(authorization: "Bearer #{@token}").users.repos('octocat').run.data.map { |repo| repo['name'] }
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
  ApiRecipes.status.health.run.success?
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
global configuration, the API methods defined on the module and every credential
and variable value that was assigned, so each example can start clean:

```ruby
RSpec.configure do |config|
  config.before(:each) { ApiRecipes.reset! }
end
```

## Security

What ApiRecipes does:

- **Path parameters** are encoded one by one. A value cannot add a segment, a
  query string or a fragment. `nil`, an empty value, `.` and `..` are refused.
- **Variables** are checked for the place where they end up: a host, a path or a
  header.
- **Credentials** are sent only to the origin they were set for, and a request
  that would send one elsewhere raises. A value with a control character is
  refused, so a credential cannot add a header.
- **Redirects.** With `follow`, a redirect to another origin drops the
  credentials, the `Cookie` header and the credential query parameter. They are
  not sent again if the chain comes back.
- **Before sending**, the address that http.rb will contact is checked against
  the origin that was validated.
- **Logs, errors and `inspect`** never contain a credential, a header, a body or
  a query string. `definition` never holds a credential that was assigned with
  `authorization=`, `basic_auth=` or `with`.
- **Serialization.** An API, an endpoint and a response refuse `Marshal.dump`,
  `YAML.dump` and `as_json`, and raise `TypeError`: serialize `response.data` or
  `response.body.to_s` instead.
- **`fill`** calls only public writers and skips keys that are not plain
  attribute names.
- **Configuration files** are read with `YAML.safe_load`, and the options are
  validated when they are loaded.

What stays with your application:

- ApiRecipes checks the form of a host, not who owns it. Never pass a value
  chosen by an end user as a whole host: not in `with(host: ...)`, and not in a
  variable that is the entire host. Check it against a list of hosts you know. A
  variable that is only a part of a host, like the shop name in
  `{shop}.myshopify.com`, is the intended use.
- `response.original_response` is the raw http.rb response, and it gives access
  to the request that was sent, headers included. Do not log or serialize it.
- ERB in a configuration file runs code. Load only files you trust.
- Do not put a credential in the source of an application or in a file of the
  repository: read it from the place where your application keeps secrets.

Every protection has an example in [`spec/security`](spec/security); its
[README](spec/security/README.md) maps each one to the example that proves it.

## Options reference

### `ApiRecipes.configure`

| Option | Meaning |
| --- | --- |
| `apis_files_paths` | Array of YAML files, evaluated with ERB |
| `apis_configs` | Hash of API descriptions |
| `variables` | Hash of default variable values, as `{ api_name: { variable: value } }` |
| `logger` | a Logger to use |
| `log_to` | path or IO for the default logger (default: STDERR) |
| `log_level` | level of the default logger (default: the `LOG_LEVEL` variable, or warn) |
| `print_urls` | log the URL of each request at info level (default: false) |
| `upgrade_warnings` | warn when a path parameter value contains `/` or looks already percent-encoded (default: true) |

### API

| Option | Default | Meaning |
| --- | --- | --- |
| `protocol` | `https` | `http` or `https` |
| `host` | `localhost` | host name, which can contain `{variables}` |
| `port` | port of the protocol | port number |
| `base_url` | none | prefix of every path, for example `api/v1`; can contain `{variables}` |
| `timeout` | `3` | seconds allowed for the whole request |
| `default_headers` | none | headers sent with every request; a value can contain `{variables}` |
| `on_bad_code` | `raise` | `raise` or `ignore` when the response is not a success |
| `mime_type` | from the response | content type used by `response.data` |
| `verify_with` | none | method that decides whether a response is a success |
| `auth` | none | where the credential goes: `type` (`none`, `bearer`, `basic`, `header`, `query`) and `name` (for `header` and `query`) |
| `variables` | none | the variables of the API, each with an optional `default` and `description` |
| `endpoints` | none | the endpoints of the API |

### Endpoint

| Option | Default | Meaning |
| --- | --- | --- |
| `path` | the endpoint name | segment added to the parent path; `''` adds nothing |
| `verb` | `get` | HTTP verb |
| `route` | `yes` | `no` makes the endpoint a group that cannot be called |
| `ok_code` | any 2xx | the status, or the list of statuses, accepted as a success |
| `timeout` | the API value | seconds allowed for the whole request |
| `on_bad_code` | the API value | `raise` or `ignore` |
| `mime_type` | the API value | content type used by `response.data` |
| `verify_with` | the API or parent value | method that decides whether a response is a success |
| `endpoints` | none | nested endpoints |

An endpoint takes `timeout`, `on_bad_code` and `mime_type` from the API, not from
the endpoint that contains it.

## Good to know

- **Configure once, at startup.** Calling `configure` again replaces the whole
  configuration. A class sees the new configuration at its next call.
- **Mistakes are reported, not ignored.** An unknown option, a wrong value or a
  verb that does not exist raises `ApiRecipes::ConfigurationError` when the
  configuration is loaded. The only free keys start with `x-`.
- **Sharing a name.** An endpoint can have any name, and it is always reachable
  with `[]`. When the name is also a method of the object (`with`, `definition`,
  `authorization`, `basic_auth` or `variables` on an API; `run`, `url`, `with` or `definition`
  on an endpoint) or one of the names that Ruby and common libraries call on any
  object by themselves (`to_ary`, `to_str`, `to_json`...), no method is generated
  for it and ApiRecipes logs a warning when the configuration is loaded. Reach
  it with `[]`, as in `ApiRecipes.github[:with]`. Private methods of Ruby's
  `Kernel`, such as `test`, `open` and `format`, are not a problem. An API or an
  endpoint name cannot be empty or contain control characters.
- **An API name can be a method of the module.** An API called `configure`,
  `configuration`, `logger`, `apis` or `reset!` gets no method of its own, so the
  method of the module keeps working, and a warning is logged. Reach the API with
  `ApiRecipes[:logger]`. In a class, `api :open` raises
  `ApiRecipes::ApiNameClashError` because `open` is already a method of the
  class: give the API another method name with `as:`.
- **One declaration per API.** An API name is declared once in a class and its
  ancestors, modules included. A subclass that needs other options uses `with`.
  A credential or a variable set through one declaration is never seen by another
  declaration of the same API name.
- **Serialization is refused.** An API, an endpoint and a response cannot be
  dumped with `Marshal` or `YAML`.
- **Internationalized hosts.** A redirect to a host with non-ASCII characters
  needs the [addressable](https://github.com/sporkmonger/addressable) gem; without
  it http.rb raises `LoadError`.
- **No changes to Ruby.** The gem adds no method to `Hash`, `Array` or any other
  class of Ruby, and does not touch `URI`.

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
| `authorization_for_a_class.rb` | a token for one class |

Run one from the root of the repository:

    $ bundle exec ruby examples/simple_usage.rb

[`examples/config/github.yml.erb`](examples/config/github.yml.erb) is a
configuration file with every option commented.

## Compatibility

- Ruby 3.3 or higher. The test suite runs on the maintained versions: 3.3, 3.4 and 4.0
- http.rb 6 (6.0.4 or higher)
- uri 0.x and 1.x

## Upgrading from 2.x

[UPGRADING.md](UPGRADING.md) lists what stops with a message, what changes
silently and what is new, and explains the `api_recipes upgrade` command, which
looks for the changes in your code. Valid YAML files keep working.

## Development

    $ bundle install
    $ bundle exec rspec

The specs never use the network. To run them against a specific version of the
uri gem:

    $ URI_VERSION='~> 1.0' bundle exec rspec

The examples in this README and in UPGRADING.md are checked by
`spec/docs/examples_spec.rb`. The protections described in the Security section
are proved by the examples in [`spec/security`](spec/security).

What is planned for the next releases is in the [roadmap](docs/ROADMAP.md).

Bug reports and pull requests are welcome on
[GitHub](https://github.com/madAle/api_recipes). Contributors are expected to
follow the [Contributor Covenant](CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the
[MIT License](http://opensource.org/licenses/MIT).
