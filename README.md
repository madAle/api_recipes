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

This page describes version 3.0, which is in pre-release. The documentation of
version 2 is the
[README of the `v2.10.4` tag](https://github.com/madAle/api_recipes/blob/v2.10.4/README.md).
Coming from version 2? Read [UPGRADING.md](UPGRADING.md) first.

## Contents

- [Installation](#installation)
- [Quick start](#quick-start)
- [Describing an API](#describing-an-api)
- [Variables](#variables)
- [Loading the configuration](#loading-the-configuration)
- [Importing an OpenAPI description](#importing-an-openapi-description)
- [Portable recipes](#portable-recipes)
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

Add the gem to your Gemfile and run `bundle install`. While 3.0 is in
pre-release, Bundler installs it only when you ask for a pre-release version:

```ruby
gem 'api_recipes', '>= 3.0.0.beta1'
```

Or install it directly:

    $ gem install api_recipes --pre

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

An option is written once, at the highest place where it holds. An endpoint
that does not set `timeout`, `on_bad_code`, `mime_type` or `verify_with` looks
for it up the tree: in the endpoint that contains it, then in the one that
contains that one, up to the API. The first that sets the option gives the
value, and when none does the default applies. An endpoint that is not on that
way up, such as one next to it, is never looked at. `default_headers` and
`default_params` are looked for in the same way, one name at a time.
`path`, `verb`, `route`, `ok_code` and `resource` describe one endpoint and are
read only there.

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

A `{name}` in a path is a [variable](#variables): a value given once, to a
chain, an object, a class or the whole application, where a `:name` is an
argument of each call.

### Endpoints that only group others

With `route: no` an endpoint exists only to hold nested endpoints. `search` above
is not callable, `search.repositories` is. Calling `run` on it raises
`ApiRecipes::NoRouteExists`.

### REST resources

When an endpoint is a REST resource, `resource: true` adds the usual endpoints
under it, so you do not write them one by one:

```yaml
billing:
  host: billing.example.test
  endpoints:
    invoices:
      resource: true
```

| Call | Request |
| --- | --- |
| `invoices` | `GET /invoices`: the endpoint itself, as always |
| `invoices.show(id)` | `GET /invoices/:id` |
| `invoices.create` | `POST /invoices` |
| `invoices.update(id)` | `PATCH /invoices/:id` |
| `invoices.replace(id)` | `PUT /invoices/:id` |
| `invoices.delete(id)` | `DELETE /invoices/:id` |

```ruby
ApiRecipes.billing.invoices.show(42).url.to_s
# => "https://billing.example.test/invoices/42"

ApiRecipes.billing.invoices.delete(42).inspect
# => "#<ApiRecipes::Endpoint billing.invoices.delete DELETE https://billing.example.test/invoices/42>"
```

- A list adds only some of them: `resource: [show, create]`.
- An endpoint written under `endpoints` with one of those names completes the
  generated one: its options win and the others stay. `show: { path: /:number }`
  changes the placeholder, `delete: { ok_code: 204 }` adds the expected status.
- The other endpoints written by hand come after the generated ones.
- `resource` only adds endpoints. The options of the endpoint itself stay its
  own: `route: no` when the list cannot be called, `path` to change the path of
  all of them.
- A verb is never read from a name: an endpoint called `delete` that you write
  by hand is a GET until you give it `verb: delete`.

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

### Headers and parameters sent with every request

`default_headers` are sent with every request, and `default_params` are added
to every query string. Both can also be written on an endpoint: there they hold
for that endpoint and for the ones below it, on top of those of the API.

```yaml
billing:
  host: billing.example.test
  default_headers:
    Accept: application/json
  default_params:
    locale: en
  endpoints:
    invoices:
      endpoints:
        show:
          path: /:id
        overdue:                        # GET /invoices?locale=en&status=overdue
          path: ''
          default_params:
            status: overdue
        pdf:                            # GET /invoices/:id/pdf with Accept: application/pdf
          path: /:id/pdf
          default_headers:
            Accept: application/pdf
```

```ruby
ApiRecipes.billing.invoices.overdue.run.uri.to_s
# => "https://billing.example.test/invoices?locale=en&status=overdue"

ApiRecipes.billing.invoices.overdue(params: { status: 'paid', page: 2 }).run.uri.to_s
# => "https://billing.example.test/invoices?locale=en&status=paid&page=2"
```

On the same name the nearest to the request wins: the API, then
[`with`](#options-for-one-chain-with), then the endpoints from the farthest to
the nearest. After them come the credential and what the request gives. For a
header: the credential, then the `headers:` of the request. For a parameter:
the `params:` of the request, then the credential when it travels in the query,
which nothing replaces.

The names of headers are compared as HTTP does, without their case and with
`_` read as `-`: `accept` on an endpoint replaces the `Accept` of the API. The
same name written twice in one place is an error. A value can contain
[variables](#variables). When an API has `default_params`, the `params:` of a
request must be a Hash.

## Variables

A variable is a `{name}` placeholder in the `host`, the `base_url`, the `path`
of an endpoint, the value of a header or of a parameter sent with every
request, or in one of the options that are read when a request is sent:
`protocol`, `port`, `timeout`, `on_bad_code`, `mime_type`, `verb` and
`ok_code`. Use it for what changes from one account or one environment to the
next, such as the address of a shop. Declare the variables of the API, with an
optional `default` and `description`:

```yaml
shopify:
  variables:
    shop:
      description: the part of the shop address before .myshopify.com
    api_version:
      default: '2026-10'
    location:
      description: the id of the location this client works for
  host: '{shop}.myshopify.com'
  base_url: admin/api/{api_version}
  auth:
    type: header
    name: X-Shopify-Access-Token
  endpoints:
    products:
    inventory:
      path: /locations/{location}/inventory_levels
```

A variable without a value and without a default raises
`ApiRecipes::MissingVariable` as soon as it is needed: when the chain reaches
the `base_url` or the path that uses it, and at the latest when the request is
built. Give it a value in the way that fits your code. The nearest one wins: the chain (`with`), then the
object, then the class that declares the API, then the whole application, then
the default of the file.

For one chain:

```ruby
ApiRecipes.shopify.with(variables: { shop: 'acme' }).products.url.to_s
# => "https://acme.myshopify.com/admin/api/2026-10/products"
```

For the whole application, when it starts, with `config.values`:

```ruby
ApiRecipes.configure do |config|
  config.values = { shopify: { variables: { shop: 'acme' } } }
end

ApiRecipes.shopify.products.url.to_s
# => "https://acme.myshopify.com/admin/api/2026-10/products"

ApiRecipes.shopify.with(variables: { api_version: '2027-01' }).products.url.to_s
# => "https://acme.myshopify.com/admin/api/2027-01/products"
```

In a path, a `:name` is an argument of the method and a `{name}` is a variable.
The location is set once, and no call has to repeat it:

```ruby
ApiRecipes.shopify.with(variables: { shop: 'acme', location: 7 }).inventory.url.to_s
# => "https://acme.myshopify.com/admin/api/2026-10/locations/7/inventory_levels"
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

The options that a class gives to `api` can use the variables of the API, as in
`api :shopify, host: '{shop}.staging.example.test'`. When an API exists only in
a class, the names given in `variables:` are its variables, so each one gets a
value there, and an object or `with` can give another:

```ruby
class Sandbox
  include ApiRecipes
  api :sandbox, host: '{tenant}.sandbox.example.test', variables: { tenant: 'demo' },
                endpoints: { ping: nil }
end

Sandbox.sandbox.with(variables: { tenant: 'acme' }).ping.url.to_s
# => "https://acme.sandbox.example.test/ping"
```

`config.values` holds, for each API, its `variables` and its credential
(`authorization` or `basic_auth`, see [Authorization](#authorization)). A later
`configure` that assigns `config.values` replaces them all; one that does not
keeps them.

ApiRecipes never reads the environment for you: if the shop comes from an
environment variable, read it in your code and pass it in.

When the value changes with each request, as in a server where it depends on
the user who is signed in, give it to `with` or to an object that lives as long
as the request. Both belong to the code that created them, so two requests
served at the same time, in two threads, never see the value of each other:

```ruby
class OrdersController < ApplicationController
  def index
    shop = ApiRecipes.shopify.with(variables: { shop: current_user.shop, location: current_user.location_id },
                                   authorization: current_user.shopify_token)
    render json: shop.inventory.run.data
  end
end
```

What `ApiRecipes.shopify` and a class use is shared by the whole process, in
every thread. That is why it is given only where the application starts, to
`config.values` and to `api`, and why `ApiRecipes.shopify.variables = ...` and
`Store.shopify.variables = ...` raise `ApiRecipes::Error`: a value that changes
while requests are served goes to `with` or to an object. The same holds for
credentials.

A service whose address changes with the environment is described once, and
each environment gives its values:

```yaml
billing:
  variables:
    protocol:
      default: https
    host:
      default: billing.example.com
    port:
      default: 443
    timeout:
      default: 5
  protocol: '{protocol}'
  host: '{host}'
  port: '{port}'
  timeout: '{timeout}'
  endpoints:
    invoices:
```

```ruby
ApiRecipes.configure do |config|
  config.values = { billing: { variables: { protocol: 'http', host: 'localhost', port: 3000 } } }
end

ApiRecipes.billing.invoices.url.to_s
# => "http://localhost:3000/invoices"
```

In these options the variable gives a value of the option: `http` or `https`
for the protocol, an integer from 1 to 65535 for the port, a positive number
for the timeout, `raise` or `ignore`, a verb, a status. It is made when the
request is built, and a value that is not one raises
`ApiRecipes::InvalidVariable` before anything is sent, as a default that is
not one raises `ApiRecipes::ConfigurationError` when the configuration is
loaded. `definition`, `routes` and the `api_recipes routes` command show such
an option as it is written. What decides the shape of the tree is read when
the configuration is loaded and takes no variable: `endpoints`, `resource`,
`route`, the names, `verify_with` and `auth`.

The value of a variable is a String, a Symbol or a number, and is kept as
text. A value is checked for the place where it ends up. In a `host` it can contain
only letters, digits, dots, hyphens and underscores. In a `base_url` and in a
`path` it is encoded like a path parameter, and it cannot be empty, `.` or
`..`. In a header it cannot contain a line break or another control character.
In a parameter it is encoded like every value of a query string. Anything else
raises `ApiRecipes::InvalidVariable`.
A word in braces that is not a variable is written `\{word}` in a path and in
a `base_url`.
A name that the API does not declare raises `ApiRecipes::ConfigurationError` at
every level, so a misspelled name is never ignored.
`variables` without an assignment returns the values of the level you call it
on: those of `config.values` on `ApiRecipes.shopify`, those given to `api` on a
class, those assigned on an object. On an object, assigning `nil` clears them,
and a default declared in the file applies again.

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
`something.recipe.yml` is a [portable recipe](#portable-recipes) and goes in
`recipes_paths`, where it is never evaluated with ERB: here it is refused,
unless `recipes_paths` has it too, in which case it is left to `recipes_paths`.
So one pattern, such as `config/apis/*.yml*`, can match both kinds of file in
one folder.

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

## Importing an OpenAPI description

When an API publishes an OpenAPI description, the `api_recipes` command writes
the recipe for you:

    $ api_recipes import openapi.yml --name github --output config/apis/github.yml

The description is read once, when you run the command. Your application never
reads it: it loads the recipe, which is a file like the ones above, and you can
read it, trim it and rename things in it. These operations

```
GET    /users
GET    /users/{username}
GET    /users/{username}/repos
GET    /repos/{owner}/{repo}/issues
POST   /repos/{owner}/{repo}/issues
GET    /repos/{owner}/{repo}/issues/{issue_number}
PATCH  /repos/{owner}/{repo}/issues/{issue_number}
```

become this recipe:

```
# Generated by api_recipes import from GitHub 1.0
github:
  host: api.github.com
  endpoints:
    users:                        # GET /users (users/list)
      endpoints:
        show:                     # GET /users/{username} (users/get-by-username)
          path: "/:username"
        repos:                    # GET /users/{username}/repos (repos/list-for-user)
          path: "/:username/repos"
    repos:
      route: false
      endpoints:
        issues:                   # GET /repos/{owner}/{repo}/issues (issues/list-for-repo)
          path: "/:owner/:repo/issues"
          endpoints:
            create:               # POST /repos/{owner}/{repo}/issues (issues/create)
              path: ''
              verb: post
              ok_code: 201
            show:                 # GET /repos/{owner}/{repo}/issues/{issue_number} (issues/get)
              path: "/:issue_number"
            update:               # PATCH /repos/{owner}/{repo}/issues/{issue_number} (issues/update)
              path: "/:issue_number"
              verb: patch
```

| Request | Call |
| --- | --- |
| `GET /users` | `github.users` |
| `GET /users/{username}` | `github.users.show('octocat')` |
| `GET /users/{username}/repos` | `github.users.repos('octocat')` |
| `GET /repos/{owner}/{repo}/issues` | `github.repos.issues('rails', 'rails')` |
| `POST /repos/{owner}/{repo}/issues` | `github.repos.issues('rails', 'rails').create(json: { title: 'Bug' })` |
| `GET /repos/{owner}/{repo}/issues/{issue_number}` | `github.repos.issues('rails', 'rails').show(1347)` |
| `PATCH /repos/{owner}/{repo}/issues/{issue_number}` | `github.repos.issues('rails', 'rails').update(1347, json: { state: 'closed' })` |

### Options

| Option | Meaning |
| --- | --- |
| `--name NAME` | the name of the API in the recipe. Default: the title of the description, in lower case with `_` |
| `--only GLOB` | only the paths that match; can be repeated. `*` also crosses `/`: `--only 'repos/*'` |
| `--except GLOB` | leaves out the paths that match; can be repeated |
| `--server N` | which entry of `servers` gives the address, counted from 0. Default: the first |
| `--output FILE` | writes the recipe in FILE, which must not exist, instead of on STDOUT |

The input is one local file, YAML or JSON, OpenAPI 3.0 or 3.1. Warnings and a
summary go to STDERR, so the recipe can be redirected. The command exits with 1
when the description cannot be imported and with 2 when the arguments are wrong.

### What is read

| From the description | In the recipe |
| --- | --- |
| the address of the server | `protocol`, `host`, `port`, `base_url` |
| the variables of the server | `variables`, with their defaults |
| the paths | the tree of endpoints |
| the path parameters | `:name` placeholders |
| the query parameters | a comment beside the endpoint, with a `*` on the required ones |
| the documented 2xx statuses | `ok_code`: one status, or a list. Left out when `200` is the only one or none is documented, since every 2xx is accepted by default |
| `security` and `securitySchemes` | `auth`: `bearer` for http bearer, OAuth 2 and OpenID Connect; `basic`; `header` or `query` for an API key |
| `operationId`, `deprecated` | a comment beside the endpoint |

Schemas, bodies, callbacks, webhooks, links and cookie parameters are not read:
the gem does not validate requests and responses against them.

### How the names are made

Each segment of a path that is not a parameter is a node, named after the
segment in lower case, with `camelCase` turned into `snake_case` and every other
character into `_`. The parameters that come before a segment travel with it;
those at the end of the path travel with the operation. An operation is named
after its verb and after how its path ends:

| Verb | The path ends with a name (`/issues`) | The path ends with a parameter (`/issues/{n}`) |
| --- | --- | --- |
| GET | the node itself | `show` |
| POST | `create` | `post` |
| PUT | `replace_all` | `replace` |
| PATCH | `update_all` | `update` |
| DELETE | `delete_all` | `delete` |
| others | the name of the verb | the name of the verb and `_one` |

- A node whose path has no GET only groups others: `route: false`.
- Two endpoints with the same name under the same node: one gets a number
  (`show_2`), and a warning says so.
- A name that is an existing method, such as `with`, is written all the same,
  with a warning: reach it with `[]`.
- A single resource comes out badly: `PATCH /user` becomes `user.update_all`.
  Rename it in the file.

What the gem cannot write as a path is left out, with a warning for each path:
a parameter directly followed by a letter, a digit or `_` (`/files/{id}_meta`),
because the gem reads `:id_meta` as one name; a segment that starts with `*` and
a name, which the gem reads as a parameter that spans segments; and an empty
segment (`/a//b`), because the gem joins two slashes into one.

### What the command refuses

- Swagger 2.0: convert the description to OpenAPI 3 first.
- A `$ref` to another file or to an address: bundle the description into one
  file first. References inside the file are followed.
- A description whose text would become code in the recipe: `<%` in a value is
  an error that says where, and it is removed from the comments.
- A YAML description with binary values, with keys that are not plain text, or
  with aliases that stand for more than ten million values.

The command reads that one file, never uses the network and runs nothing of the
description.

## Portable recipes

A portable recipe is a recipe made to be shared: one API in one file, and
nothing but data. You install it with a command that shows what it does before
it writes anything, and you load it with `recipes_paths`.

    $ api_recipes install github
    github 1.0.0
      summary:       GitHub REST API, users, repositories, issues and pull requests
      homepage:      https://docs.github.com/en/rest
      from:          https://github.com/madAle/api_recipes-cookbook, commit a4e8dd017d05
      address:       https://api.github.com
      credential:    in the Authorization header
      headers:       Accept: application/vnd.github+json
      calls:         14, of which 2 are not GET:
        POST  github.repos.issues(owner, repo).create                         /repos/:owner/:repo/issues
        POST  github.repos.issues(owner, repo).comments(issue_number).create  /repos/:owner/:repo/issues/:issue_number/comments
    Install github 1.0.0 in config/api_recipes? [y/N] y
    github 1.0.0 is installed in config/api_recipes/github.recipe.yml

```ruby
ApiRecipes.configure do |config|
  config.recipes_paths = Dir['config/api_recipes/*.recipe.yml']
end

ApiRecipes.github.users.show('octocat').run
```

The command writes two files in `config/api_recipes`: the recipe,
`github.recipe.yml`, and `recipes.lock`, which records the version, the
repository, the commit and the checksum of each installed recipe. Commit both
to your repository: the application downloads nothing when it starts.

Recipes come from the
[cookbook](https://github.com/madAle/api_recipes-cookbook), a Git repository
that takes contributions by pull request, or from any repository with the same
layout.

### Installing, updating and checking

    $ api_recipes install github                      # the recipe at the head of the cookbook
    $ api_recipes install github --version 1.0.0      # the one at the tag github-1.0.0
    $ api_recipes install billing --from https://github.com/acme/api-recipes
    $ api_recipes install ./billing.recipe.yml        # a file of yours
    $ api_recipes update github
    $ api_recipes check
    $ api_recipes check recipes/billing.recipe.yml

- `install NAME` reads `recipes/NAME.recipe.yml` from the repository. `--from`
  names another repository: an `https://` address without a user name or a
  password, or an `ssh` address. The `git` command of your machine does the
  download, and the command says which address it reads before `git` connects.
  For a repository of your company, see [private repositories](#private-repositories).
- Before writing, `install` shows the address the requests go to, as the recipe
  writes it and with the defaults of its variables, where the credential goes,
  the headers and the parameters sent with every request, with the endpoint
  for those that only an endpoint adds, the variables to set and every call
  that is not a GET. The address is shown whole. A name or a value longer than
  100 characters is cut and followed by its length, so you know to read it in
  the file. It warns when the credential would travel in the query string,
  and when the protocol is `http`. Only `y` or `yes` installs; `--yes` installs
  without asking.
- `--to DIR` installs in another folder. `update` and `check` take it as
  `--dir DIR`.
- `update NAME` takes the recipe that its repository has now, or the one of
  `--version`, and shows what changes in the address, the credential, the
  headers, the parameters and the verbs before it replaces the file. A header
  or a parameter that changes is shown whole, before and after. It reads the
  repository from `recipes.lock`, so it needs no `--from`.
- `check` compares the installed recipes with `recipes.lock`, as `configure`
  does. `check FILE` says whether a file is a valid portable recipe: use it
  while you write one.
- `install FILE` installs a file of yours. It is also how you accept a change
  you made by hand to an installed recipe: `api_recipes install
  config/api_recipes/github.recipe.yml` writes its new checksum in the lock.
  From then on the lock no longer names a repository for it, and `update`
  refuses it.

Exit codes: 0 when the work is done or there was nothing to do; 1 when a recipe
is not valid, is not found, does not match the lock or the answer is no; 2 when
the arguments are wrong, `git` fails or a file cannot be read or written.

### Private repositories

A company can keep its recipes in a repository of its own, private, on any Git
server that speaks `https` or `ssh`: GitHub, GitLab, Bitbucket, Gitea or one
you host. The repository has the layout of the cookbook, a folder `recipes`
with one `NAME.recipe.yml` per recipe, and `--from` names it:

    $ api_recipes install billing --from https://git.example.com/platform/api-recipes
    $ api_recipes install billing --from git@git.example.com:platform/api-recipes.git
    $ api_recipes update billing

**Over `ssh`** the address is written as `user@host:path` or as
`ssh://user@host:port/path`, and `ssh` works as it does for `git clone`: with
your keys, your agent and your `~/.ssh/config`. A deploy key that can read the
repository is enough, also in CI. When `ssh` has to ask something, such as the
passphrase of a key or whether to trust a host it meets for the first time, it
asks on the terminal; without a terminal it fails, and the message says what
is missing. When `ssh` warns that the key of a host has changed, the command
says so and does not suggest to trust it. An address with a password is
refused. The user of the address is written in `recipes.lock` with it: use the
one everybody shares, such as `git`, or leave it out of an `ssh://` address and
let the `ssh` configuration of each person choose.

**Over `https`** `git` uses the user name and the password it already has for
that host. When it has none and the command runs on a terminal, `git` asks for
them, as it does for a clone: they go from the terminal to `git`, and the
command never sees them. Without a terminal, as in CI, nothing is asked and the
command fails with a message that says so. They are never taken in the
address. Two ways to give them to `git` once, on a laptop and in CI:

    # a credential helper: the one of your system, or a file
    $ git config --global credential.helper store
    $ git ls-remote https://git.example.com/platform/api-recipes    # asks once, then remembers

    # or a token that git adds by itself to the addresses of that host
    $ git config --global url."https://ci:${TOKEN}@git.example.com/".insteadOf "https://git.example.com/"

`recipes.lock` records the address as you wrote it, so no credential reaches
your repository, and `update` reads it from there: whoever runs `update` needs
the same access. No other protocol is accepted. The application needs none of
this when it runs: the installed recipes are files of your project.

### What `configure` checks

Every file of `recipes_paths` must be called `NAME.recipe.yml` and must be in
the `recipes.lock` of its folder with the checksum it has now. A file that was
changed after it was installed, or that was never installed, raises
`ApiRecipes::ConfigurationError` and the previous configuration stays:

    config/api_recipes/github.recipe.yml: was changed after it was installed: its checksum is not the one in recipes.lock. To accept the file as it is now, run `api_recipes install config/api_recipes/github.recipe.yml`

A recipe never replaces an API: a name that `apis_configs`, `apis_files_paths`
or another recipe already defines is an error. Everything else works as for any
API: credentials, variables, `with`, and `api :github` in a class. To add a
`verify_with`, which a recipe cannot carry, declare it in your code:

```ruby
class GithubClient
  include ApiRecipes
  api :github, verify_with: :expected_response?
end
```

`ApiRecipes.github.definition.recipe` returns the `recipe` key of the file:
its name, its version and the rest.

### Writing a portable recipe

A portable recipe is an ordinary description of one API, with the key `recipe`:

```yaml
billing:
  recipe:
    name: billing
    version: 1.2.0                # of the recipe, not of the API
    format: 1
    summary: Billing API, invoices and customers
    homepage: https://billing.example.com/docs
  auth:
    type: header
    name: X-Api-Key
  variables:
    account:
      description: the name of your account, before .billing.example.com
    api_version:
      default: '2026-10'
  host: '{account}.billing.example.com'
  base_url: 'api/{api_version}'
  endpoints:
    invoices:
      endpoints:
        show:
          path: /:id
```

The rules, beyond those of every description:

- One API per file. The name of the API, `recipe.name` and the name of the file
  (`billing.recipe.yml`) are the same: lowercase letters, digits, `-` and `_`.
- `recipe.name` and `recipe.version` are required. The version is text made of
  digits, letters and dots: write `'1.2'` between quotes. `format` is the
  version of the format, today 1; `summary` and `homepage` are optional.
- `host` is required. A variable can be the whole host, or stand before fixed
  text that starts with a dot: `{account}.billing.example.com` and
  `s3.{region}.example.com` are accepted, `api.example.{tld}` is not.
- No `verify_with`, no ERB, and no `<%` anywhere in the file.
- Plain YAML: no anchors, aliases, tags or merge keys, no key given twice, keys
  that are text (quote `'on'`, `'no'` and numbers).
- Every name and every value is visible text: no control characters, no line
  breaks inside a value, no invisible or direction-changing characters. The
  same holds for the rest of the file, comments included: what a person reads
  in it is what is loaded.
- At most 1 MiB, 10,000 endpoints, those that `resource` adds among them, 2,000
  characters for a name or a value, and 4,000 characters for the path of an
  endpoint with the paths above it. The headers and parameters written on
  endpoints are at most 100,000, counting for each endpoint that adds some
  also those it takes from the endpoints above it.
- With `auth.type: query`, `default_params` cannot name the parameter of the
  credential.
- A credential never goes in a recipe: `auth` says where it travels, and the
  application assigns it.

A repository of recipes keeps each one in `recipes/NAME.recipe.yml`. A
published version is the tag `NAME-VERSION`, for example `billing-1.2.0`.
`api_recipes routes billing.recipe.yml` lists the calls of a recipe.

### From a file of your project

When the API is already described in a file of your project, `convert` moves
it to a portable recipe. Run it in the root of the project: a Rails
application or any other Ruby project, wherever `ApiRecipes.configure` is
called.

    $ bundle exec api_recipes convert config/apis/billing.yml.erb
    billing 1.0.0 now comes from a portable recipe: 2 calls

    Changed in the project
      created  config/api_recipes/billing.recipe.yml, with its line in config/api_recipes/recipes.lock
      edited   config/initializers/api_recipes.rb: recipes_paths and config.values
      edited   app/models/invoice.rb: verify_with on the declaration of the api
      deleted  config/apis/billing.yml.erb

    What changed in the description
      host: the ERB tag is now the variable {billing_host}, with the default written in the tag
      port: the ERB tag is now the variable {billing_port}, with the default written in the tag
      verify_with: left out, a recipe cannot carry it: give it where a class declares the api, as `api :billing, verify_with: ...`
      default_headers.Api-Key-Client: the ERB tag is now the variable {billing_client}; the value is not in the recipe

    Every change is in `git status` and `git diff`, and `git checkout` undoes it. Check the recipes with `api_recipes check`, then start the application.

The project works as before, and the values still come from where they came:
the code of each tag is moved, as it is written, to `config.values`.

```ruby
ApiRecipes.configure do |config|
  config.apis_files_paths = Dir[File.expand_path('../apis/*.yml.erb', __dir__)]
  config.values = {
    billing: { variables: {
      billing_host: (ENV['BILLING_HOST'] || 'billing.example.test'),
      billing_port: (ENV['BILLING_PORT'] || 443),
      billing_client: ENV['BILLING_CLIENT']
    }.compact }
  }
  config.recipes_paths = Dir[File.expand_path('../api_recipes/*.recipe.yml', __dir__)]
end
```

What the command does:

- **It writes the recipe**, with the key `recipe` (the name of the API,
  `--version`, `1.0.0` by default, and the format), and installs it in
  `config/api_recipes` with its line in `recipes.lock`. When the file describes
  several APIs, `--name` chooses one. Anchors, aliases and merge keys are
  written out.
- **An `<%= ... %>` tag becomes a variable**, in every place where a recipe
  can have one: the `host`, the `base_url`, a `path`, the value of a header or
  of a parameter, and the `protocol`, `port`, `timeout`, `on_bad_code`,
  `mime_type`, `verb` and `ok_code` when the tag gives the whole value. The
  variable is named after the environment variable that the tag reads, or
  after its place, and a default written in the tag as plain text or as a
  number (`ENV.fetch('NAME', 'text')`, `ENV['NAME'] || 443`) becomes the
  default of the variable. A default that a tag gave to a variable the file
  declares is given by the application from now on.
- **Nothing in the file is run**, and there is no option that runs it. The
  code of a tag goes to `config.values` as text. `.compact` leaves out a
  variable whose code gives `nil`, so the default of the recipe applies.
- **A credential is never copied into the recipe.** A header or a parameter
  whose name contains `auth`, `key`, `token`, `secret`, `passw`, `credential`,
  `signature`, `cookie` or `session` becomes a variable without a default,
  unless the file already gives it with a variable it declares, and
  its value, written in the file or given by a tag, goes to `config.values`.
  The command cannot know a secret written anywhere else: read the recipe
  before you share it.
- **The old description is removed**: the file is deleted, or only the lines
  of that API when it describes others, because a recipe never takes the place
  of an API that another source defines.
- **`verify_with`**, which a recipe cannot carry, is written on the line where
  a class declares the API.
- **What it prints never holds the code of a tag or the value of a header or
  of a parameter.** A message about an option that is not valid, such as a
  protocol that is not one, shows what was written, as `configure` does.

It changes your files only when that is safe, and all at once or not at all:

- Lines are added only to a file that git knows. A file is deleted, or lines
  are taken out of it, only when git has it committed as it is now. Outside a
  git repository the project is not changed.
- The file that calls `ApiRecipes.configure` is edited when there is exactly
  one, written as `ApiRecipes.configure do |config|`, and when `config.values`
  is not assigned yet or was written by this command. The result is read as
  Ruby, without running it, before it is written.
- When a step is not possible, nothing is written and the command says why.
  What it could not do by itself is listed under `Left to you`: a
  `verify_with` when no class declares the API, or on an endpoint.
- A tag that is not `<%= ... %>`, that gives the name of an option, or that
  gives a part of the protocol, of the port or of another such option, stops
  the command, which says the line.

To write the recipe alone, as for the repository of the recipes, name a
folder: the project is not touched, and the command says which variables the
application gives.

    $ api_recipes convert config/apis/billing.yml.erb --to ../api-recipes/recipes

The command does not publish: the recipe reaches a repository with `git`,
through the review that every recipe gets.

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

The [`default_params`](#headers-and-parameters-sent-with-every-request) of the
API and of the endpoint come first in the query string; a parameter given here
replaces the one with the same name.

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
`on_bad_code`, `mime_type`, `verify_with`, `default_headers`, `default_params`,
`variables`, `authorization` and `basic_auth`. The values are checked like the ones in a file,
and an option that is not in this list raises `ApiRecipes::ConfigurationError`.

On an endpoint, `with` takes `timeout`, `on_bad_code`, `ok_code`, `mime_type` and
`verify_with`, for that request only:

```ruby
ApiRecipes.github.users.show('octocat').with(timeout: 10, ok_code: [200, 304]).run
```

Giving an option as `nil` drops the value given before it in the same chain.
`default_headers` and `default_params` given to `with` are added to the ones
already configured:

```ruby
ApiRecipes.github.with(default_headers: { 'X-Request-Id' => 'abc123' }).users.run
```

The options of a chain are one set. A credential given to `with` is sent
wherever that chain goes, also to a `host` given by another `with` of the same
chain: give them together only when the credential is meant for that host.

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
meant for APIs used from a class or an instance. An endpoint that has no
`verify_with` of its own looks for one up the tree, as for the other options.

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
3. the class or the module that declares the API
4. the whole application

The last two are shared by every thread of the process, so they are given where
the application starts and cannot be assigned afterwards. A chain and an object
are seen only by the code that holds them: they are the place for a credential
that changes from one request to the next, as long as the object is not itself
kept where every request finds it.

**A token for the whole application**, sent as the `Authorization` header, as
it is written. It goes in `config.values`, with the variables of the API:

```ruby
ApiRecipes.configure do |config|
  config.values = { github: { authorization: "Bearer #{ENV.fetch('GITHUB_TOKEN', 'abc')}" } }
end
```

**Basic auth:**

```ruby
ApiRecipes.configure do |config|
  config.values = { github: { basic_auth: { user: 'me', pass: 'secret' } } }
end
```

**A different token for one class.** It applies to the class, to its subclasses
and to their objects, and it is given where the class declares the API:

```ruby
class AdminClient
  include ApiRecipes
  api :github, authorization: "Bearer #{ENV.fetch('ADMIN_TOKEN', 'admin')}"
end
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

The reader returns what the nearest level gives:

```ruby
ApiRecipes.configure do |config|
  config.values = { github: { authorization: 'Bearer abc' } }
end
ApiRecipes.github.authorization
# => "Bearer abc"
ApiRecipes.github.with(authorization: 'Bearer of this chain').authorization
# => "Bearer of this chain"
```

**No credential.** A credential given as `nil` means "send none" and ends the
search: it does not fall back to a level farther away. It works at every level:

```ruby
ApiRecipes.github.with(authorization: nil).users.run   # this chain sends none

class PublicClient
  include ApiRecipes
  api :github, authorization: nil                      # this class sends none
end
```

`authorization=`, `basic_auth=` and `variables=` exist for objects only: they
change the level of the object they are called on. On `ApiRecipes.github` and
on a class they raise `ApiRecipes::Error`, and the message says where the value
goes: a class that served two users at once would otherwise send the token of
one with the request of the other. They also raise on an API that `with`
returned: use `with(authorization: ...)` there. A token that expires and is
renewed while the application runs goes to `with`, read from where you keep it
at every call.

A credential is valid only for the origin it was set for: the scheme, the host
and the port. If a nearer level changes the destination (its own `host`,
`protocol` or `port`, or a variable of the host) and does not set a credential of
its own, the request raises `ApiRecipes::CredentialOriginMismatch` instead of
sending the credential somewhere else. Set the credential where you change the
destination:

```ruby
class EnterpriseClient
  include ApiRecipes
  api :github, host: 'github.example.com', authorization: "Bearer #{ENV.fetch('ENTERPRISE_TOKEN', 'enterprise')}"
end
```

An API or an endpoint kept in a variable keeps the destination it was created
with. If a later `configure` moves the API to another origin, a request made
through it raises the same error instead of sending a credential of the levels
to the old origin: ask `ApiRecipes` (or the class, or the object) for the API
again. A `configure` that does not move the origin changes nothing for it.

The readers `authorization` and `basic_auth` return the nearest credential that
was assigned. They do not apply that check: only a request does.

A credential with a line break or another control character raises
`ApiRecipes::InvalidCredential`. The message never contains the value. A client
restored from a serialized form has no credential.

An API can say where its credential goes with `auth`:

| `auth.type` | The credential given as `authorization` goes |
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
raises `ApiRecipes::InvalidCredential`. Give the value as `authorization`.

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
`on_bad_code`, `mime_type`, `verify_with`, `default_headers`, `default_params`,
`auth`, `variables`, `endpoints`, `routes` and `to_h`. For an endpoint: `name`,
`full_name`, `path`, `full_path`, `path_params`, `path_variables`, `verb`,
`route?`, `ok_code`, `timeout`, `on_bad_code`, `mime_type`, `verify_with`,
`default_headers`, `default_params`, `parent`, `endpoints` and `to_h`. The
`default_headers` and `default_params` of an endpoint are the ones written on
it and on the endpoints above it, without those of the API. A path is shown as
it is written, with its `:name` and `{name}`. The endpoints that `resource`
adds are endpoints like the others.
A definition never holds a credential, wherever it was given, nor the value of
a variable. It does return the
`default_headers` and the `default_params` as they are configured, so do not
write a credential there if you pass definitions around; `to_h` and `inspect`
hide their values.

`routes` lists every endpoint that can be called, with the call that reaches it:

```ruby
route = ApiRecipes.github.definition.routes.find { |r| r.call.end_with?('.contributors') }
[route.call, route.verb, route.url].join(' ')
# => "github.repos(owner, repo).contributors get https://api.github.com/repos/:owner/:repo/contributors"
```

The command line gives the same list for the recipes in one or more files,
which is handy after an import:

```
$ api_recipes routes config/apis/github.yml
github.users                                           GET    https://api.github.com/users
github.users.show(username)                            GET    https://api.github.com/users/:username
github.repos.issues(owner, repo).create                POST   https://api.github.com/repos/:owner/:repo/issues
```

A file that contains ERB is read only with `--erb`, because that runs the code
in it.

## Recipes

### Rails setup

```ruby
# config/initializers/api_recipes.rb
ApiRecipes.configure do |config|
  config.logger = Rails.logger
  config.apis_files_paths = Dir[Rails.root.join('config', 'apis', '*.yml').to_s]
  config.values = { github: { authorization: "Bearer #{Rails.application.credentials.github_token}" } }
end
```

A value that depends on the user who is signed in does not go there: see
[Variables](#variables) for the request of a controller.

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
global configuration, the API methods defined on the module, the values of the
application and those assigned to objects, so each example can start clean.
What a class gives to `api` is part of its code and stays:

```ruby
RSpec.configure do |config|
  config.before(:each) { ApiRecipes.reset! }
end
```

## Security

What ApiRecipes does:

- **Path parameters** are encoded one by one. A value cannot add a segment, a
  query string or a fragment. `nil`, an empty value, `.` and `..` are refused.
- **Variables** are checked for the place where they end up: a host, a path, a
  header or a query parameter. In a path a value is one encoded segment, like a
  path parameter.
- **Parameters sent with every request** cannot take the place of the
  credential: with `auth.type: query`, `default_params` that name its parameter
  are refused, and the credential is always the only parameter with its name.
- **Shared values.** The credential and the variables that the whole
  application or a class uses are read by every thread. They are given only
  where the application starts, to `config.values` and to `api`: on
  `ApiRecipes.github` and on a class the writers raise, so code that serves
  several users cannot leave the token of one of them where the request of
  another finds it. A `configure` changes the descriptions and those values in
  one step.
- **Credentials** are sent only to the origin they were set for, and a request
  that would send one elsewhere raises. A value with a control character is
  refused, so a credential cannot add a header.
- **Redirects.** With `follow`, a redirect to another origin drops the
  credentials, the `Cookie` header and the credential query parameter. They are
  not sent again if the chain comes back.
- **Before sending**, the address that http.rb will contact is checked against
  the origin that was validated.
- **`api_recipes import`** reads one local file, follows only the references
  inside it, never uses the network and runs nothing of the description. Text of
  the description cannot add keys to the recipe and cannot become ERB in it.
- **Portable recipes** are data only. A file of `recipes_paths` is never
  evaluated with ERB and is read as plain YAML, without anchors, aliases or
  tags. It cannot carry `verify_with`, cannot take the name of an API you
  already have, and cannot let a variable decide where its host ends. Its
  text, comments included, holds only visible characters. It is loaded only if
  it matches the checksum in `recipes.lock`.
- **`api_recipes install` and `update`** show where the requests and the
  credential go, the headers and the parameters sent with every request, those
  that an endpoint adds, and which calls are not GET, the ones that `resource`
  adds among them, before they write. They read one
  file from the repository without checking it out, only over `https` or `ssh`,
  and run `git` without a shell. An `https` address with a user name or a
  password and an `ssh` address with a password are refused, so no secret can
  end up in `recipes.lock`. The commands say which address they read before
  `git` connects to it: `update` takes it from `recipes.lock`, so read a change
  to that file as you read a change to the code.
- **Logs, errors and `inspect`.** A log line and an error message of the gem
  never contain a credential, a header value, a body or a query string. Neither
  does the `inspect` or the `pp` of an API, an endpoint, a response, a
  definition or the configuration, nor their `to_s`, except that the `to_s` of
  a response is its body, as for the http.rb response. `definition` never holds
  a credential, wherever it was given.
  It does hold the values of `default_headers` and `default_params`, which its
  readers return; its `inspect`, its `to_h` and its JSON show them as
  `[FILTERED]`.
- **Serialization.** An API, an endpoint and a response refuse `Marshal.dump`,
  `YAML.dump`, `as_json` and `to_json`, and raise `TypeError`: serialize
  `response.data` or `response.body.to_s` instead. A definition refuses
  `Marshal.dump` and `YAML.dump`, and its JSON is the one of `to_h`.
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
- An object that every request reaches, such as a client kept in a constant or
  memoized on a class, is as shared as a class: do not assign the credential or
  the variables of one user on it. Use `with`, or an object made for the request.
- `response.original_response` is the raw http.rb response, and it gives access
  to the request that was sent, headers included. Do not log or serialize it.
- ERB in a configuration file runs code. Load only files you trust.
- Read what `api_recipes install` shows before you answer yes. ApiRecipes checks
  the form of a recipe, not whose host it names. Commit the installed recipes
  and `recipes.lock`, and review their changes as you review code: the lock
  makes a change visible, it does not stop someone who can change both files.
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
| `recipes_paths` | Array of installed portable recipes (`NAME.recipe.yml`), read as data only and checked against `recipes.lock` |
| `values` | for each API, its credential and the values of its variables for the whole application, as `{ api_name: { authorization: '...', variables: { name: value } } }`; `basic_auth` in place of `authorization` |
| `logger` | a Logger to use |
| `log_to` | path or IO for the default logger (default: STDERR) |
| `log_level` | level of the default logger (default: the `LOG_LEVEL` variable, or warn) |
| `print_urls` | log the URL of each request at info level (default: false) |
| `upgrade_warnings` | warn when a path parameter value contains `/` or looks already percent-encoded (default: true) |

### API

| Option | Default | Meaning |
| --- | --- | --- |
| `protocol` | `https` | `http` or `https`; can be a `{variable}` |
| `host` | `localhost` | host name, which can contain `{variables}` |
| `port` | port of the protocol | port number; can be a `{variable}` |
| `base_url` | none | prefix of every path, for example `api/v1`; can contain `{variables}` |
| `timeout` | `3` | seconds allowed for the whole request; can be a `{variable}`, as `on_bad_code` and `mime_type` |
| `default_headers` | none | headers sent with every request; a value can contain `{variables}` |
| `default_params` | none | query parameters sent with every request; a value is text, a number or a boolean, and can contain `{variables}` |
| `on_bad_code` | `raise` | `raise` or `ignore` when the response is not a success |
| `mime_type` | from the response | content type used by `response.data` |
| `verify_with` | none | method that decides whether a response is a success |
| `auth` | none | where the credential goes: `type` (`none`, `bearer`, `basic`, `header`, `query`) and `name` (for `header` and `query`) |
| `variables` | none | the variables of the API, each with an optional `default` and `description` |
| `endpoints` | none | the endpoints of the API |

### Endpoint

| Option | Default | Meaning |
| --- | --- | --- |
| `path` | the endpoint name | segment added to the parent path; `''` adds nothing; can contain `:name` and `*name` placeholders and `{variables}` |
| `verb` | `get` | HTTP verb; can be a `{variable}`, as `ok_code` (one status), `timeout`, `on_bad_code` and `mime_type` |
| `route` | `yes` | `no` makes the endpoint a group that cannot be called |
| `ok_code` | any 2xx | the status, or the list of statuses, accepted as a success |
| `timeout` | looked for up the tree | seconds allowed for the whole request |
| `on_bad_code` | looked for up the tree | `raise` or `ignore` |
| `mime_type` | looked for up the tree | content type used by `response.data` |
| `verify_with` | looked for up the tree | method that decides whether a response is a success |
| `default_headers` | none | headers added to those of the API, for this endpoint and the ones below it |
| `default_params` | none | query parameters added to those of the API, for this endpoint and the ones below it |
| `resource` | `no` | `yes` adds the endpoints `show`, `create`, `update`, `replace` and `delete`; a list adds only the ones it names |
| `endpoints` | none | nested endpoints |

"Looked for up the tree" means: in the endpoints that contain this one, from
the nearest, then in the API; the first that sets the option gives the value,
and the default of the API table applies when none does. `default_headers` and
`default_params` are looked for in the same way, one name at a time. `ok_code`
is read only on its endpoint: the status that means success belongs to one
operation, as its verb does.

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
- **Constants seen by a class that includes `ApiRecipes`.** Ruby looks a constant
  up in the ancestors of a class before the top level, so inside a class that
  includes `ApiRecipes` the constants of the gem win over the constants of your
  application with the same name: `Api`, `Endpoint`, `Response`, `Configuration`,
  `Internals`, `VERSION`, `Error` and the error classes (`ApiConfigIsNotAnHash`,
  `ApiNameClashError`, `ConfigurationError`, `CredentialOriginMismatch`,
  `InvalidCredential`, `InvalidPathParameter`, `InvalidUrl`, `InvalidVariable`,
  `MissingVariable`, `NoRouteExists`, `PathParamsMismatch`, `RecipeFileError`,
  `ResponseCodeNotAsExpected` and `UnknownEndpoint`). If your application has a
  class with one of these names, write it with a leading `::` inside the classes
  that include `ApiRecipes`, for example `::Response`. The internal classes of
  the gem are all under `ApiRecipes::Internals`, so they hide nothing else.
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
looks for the changes in your code. A YAML file that is valid for 2.x keeps
working, apart from the cases listed there.

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
