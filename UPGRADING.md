# Upgrading from 2.x to 3.0

Version 3.0 keeps the way you use the gem: `ApiRecipes.configure`, `api :name`
in a class and the chain `ApiRecipes.github.users.show('octocat').run` work as
before. The YAML description of an API becomes a portable recipe, with the same
options and endpoints: `api_recipes convert` moves every description of a
project to one, as part 2 describes. What changes is how the gem behaves around
them: it checks more, it refuses more, and a few results are different.

This guide has six parts:

1. [Before you start](#1-before-you-start)
2. [What stops at once, with a message](#2-what-stops-at-once-with-a-message)
3. [What changes without a message](#3-what-changes-without-a-message)
4. [What was removed, and what to use instead](#4-what-was-removed-and-what-to-use-instead)
5. [What is new](#5-what-is-new)
6. [Security](#6-security)

Then it explains [the `api_recipes upgrade` command](#the-api_recipes-upgrade-command),
which looks for these changes in your code. Each part is ordered from what is
most likely to affect you to what is least likely.

The examples that show a result use this configuration:

```yaml
github:
  host: api.github.com
  endpoints:
    users:
      endpoints:
        show:
          path: /:login
        files:
          path: /:login/files/*path
    repos:
      route: no
      path: /repos/:owner/:repo
      endpoints:
        show:
          path: ''
    with:
```

## 1. Before you start

- **Stay on 2.x until you are ready.** In your Gemfile, `gem 'api_recipes', '~> 2.10'`
  keeps you on the current line. A pre-release such as `3.0.0.beta1` is never
  picked by that version rule: ask for it by its number.
- **Ruby 3.3 or higher.** The gem refuses to install on an older Ruby. If you
  cannot upgrade Ruby yet, stay on 2.10.
- **http.rb 6.** The gem needs `http` 6.0.4 or higher, below 7. http.rb 5 is no
  longer supported.
- **Run `api_recipes upgrade`** in the root of your project (see
  [below](#the-api_recipes-upgrade-command)). It finds your code and your
  configuration files by itself, then the removed
  `route`, `base_configs`, `ApiRecipes.print_urls`, the removed error classes and
  `Hash` and `Array` methods, and a few lines that deserve a look (manual
  encoding of path parameters, a bare `rescue`, `follow:`). It then lists what it
  cannot find, such as the removed accessors of `Endpoint` and `Api`.
- **Read your logs after the first run.** The gem now logs warnings, to STDERR, when
  a path parameter value changes meaning and when an endpoint name cannot become
  a method.

## 2. What stops at once, with a message

These show up the first time the code runs. The message says what to do.

### The configuration is checked when it is loaded

Unknown options, values that are not valid and verbs that do not exist used to be
accepted without a word. Now `ApiRecipes.configure` raises
`ApiRecipes::ConfigurationError` and lists every problem in one message:

```
4 problems in the configuration
  github: unknown option 'hots'
  github.timeout: must be a positive number
  github.on_bad_code: 'explode' is not one of raise, ignore
  github.endpoints.users.verb: 'yell' is not a verb known to http.rb
```

Fix them all and run again. A failed `configure` leaves the previous
configuration in place. Four things are worth knowing:

- Keys that start with `x-` are free. Use them for your own notes.
- A `base_url` with a path placeholder (`:name` or `*name`) is an error. In 2.x
  it silently became a required parameter of every root endpoint. For a value
  that changes, declare a [variable](README.md#variables) and write `{name}`.
- A word in braces, such as `{id}`, in a value of `default_headers` or of
  `default_params`, in the `base_url` or in the `path` of an endpoint is now a
  variable, which a request asks a value for. In 2.x it was sent as text.
  `api_recipes convert` keeps it text: it writes `\{id}` in a path and in the
  `base_url`, and for a header or a parameter it declares a variable whose
  default is the text and uses the variable, as in
  `variables: { template: { default: '{id}' } }` with the header value
  `'{template}'`. Braces around anything else, such as a JSON value, are sent
  as they are. In a path, if you meant a value that changes at every call,
  write a placeholder, `/items/:id`.
- A file that is missing, empty, not valid YAML or not valid UTF-8 raises
  `ApiRecipes::RecipeFileError`, which names the file. Files are read with
  `YAML.safe_load`: plain values, symbols and aliases are accepted, and nothing
  else. A file called `something.recipe.yml` is refused: it is a portable
  recipe, and goes in `recipes_paths`.

### An API is described by a portable recipe

2.x loaded the files of `apis_files_paths`: YAML that the gem evaluated with
ERB. 3.0 loads only portable recipes, files called `NAME.recipe.yml` that
hold data and no code, and `apis_configs`. Assigning `apis_files_paths` raises
`ApiRecipes::Error`, and the message names the command to run:

    $ bundle exec api_recipes convert

In the root of the project, with no argument, it moves every API that a file
describes to a recipe in `config/api_recipes`, one after the other:

- what an `<%= ... %>` tag gave becomes a variable of the recipe, and the code
  of the tag moves, as it is written, to `config.values` in the file that
  calls `ApiRecipes.configure`;
- `config.recipes_paths` is added, and `config.apis_files_paths` goes with the
  last description;
- the old file is deleted, and every change is listed.

`api_recipes upgrade`, run without arguments in the root of the project,
offers the same move on a terminal, one API at a time, and shows the files it
creates, edits and deletes before it asks. A file
where ERB decides the structure, with `<% if %>` or a tag that gives a name,
cannot be converted by the command: it says so, and that description is
rewritten by hand as a recipe. The whole of what `convert` does is in the
README, under "From a file of your project".

### A class with its own destination needs its own credential

In 2.x the credential of `ApiRecipes.github` was copied to every class that
declared the API, even a class that sent its requests to another host. Now a
credential is valid only for the origin it was set for (scheme, host and port).
A class that changes `host`, `protocol` or `port` and sets no credential of its
own raises:

```
api 'github': the credential is bound to "https://api.github.com" but the request goes to
"https://ent.example.test". Set the credential at the level that changes the destination,
or set it to nil to send none
```

Give the credential where the class declares the API:

```ruby
class EnterpriseClient
  include ApiRecipes
  api :github, host: 'ent.example.test', authorization: "Bearer #{ENV.fetch('ENTERPRISE_TOKEN')}"
end
```

### Credentials are given when the application starts

In 2.x the usual line was `ApiRecipes.github.authorization = '...'`, and code
that served several users assigned it before each call. What `ApiRecipes.github`
and a class use is shared by every thread of the process, so a request could
leave with the token of another user. Now `authorization=`, `basic_auth=` and
`variables=` raise `ApiRecipes::Error` on `ApiRecipes.github` and on a class,
and the message says where the value goes:

```ruby
# the whole application: once, in configure
ApiRecipes.configure do |config|
  config.values = { github: { authorization: "Bearer #{ENV.fetch('GITHUB_TOKEN')}" } }
end

# one class: where it declares the API
class AdminClient
  include ApiRecipes
  api :github, authorization: "Bearer #{ENV.fetch('ADMIN_TOKEN')}"
end

# one user, one request: the chain, or an object of its own
ApiRecipes.github.with(authorization: "Bearer #{user.token}").users.run
```

The writers still work on an object, as in `client.github.authorization = ...`.

### `nil` or an empty path parameter

`show(nil)` and `show('')` built the URL of the parent. They now raise
`ApiRecipes::InvalidPathParameter`:

```
invalid value for path parameter 'login' of 'github.users.show': is nil
```

If you wanted the parent, call the parent endpoint. The values `.` and `..` raise
too.

### Methods that were removed

These raise `NoMethodError` or `NameError`. Part 4 gives the replacement of each:

- `endpoint.route` and `endpoint.route.fill(object)`
- `Endpoint#name`, `#params`, `#children`, `#api`
- `Api#name`, `#configs`, `#base_configs`, `#object`
- `ApiRecipes.print_urls` and `ApiRecipes.print_urls = ...`
- `configuration.setup` and `response.request`
- `ApiRecipes::RouteNameClashWithExistentMethod`, `ApiRecipes::Route` and
  `ApiRecipes::Settings`
- the error classes `RouteAndResourceNamesClashError`, `MissingRouteAttribute`,
  `ProvidedObjectNotAsResponseData` and `NoConfigurationGivenForEndpoint`, which
  nothing ever raised: a `rescue` clause that names one raises `NameError`
- the methods the gem added to `Hash` and `Array`

Beware of one case. A name such as `name` or `params`, which used to be an
accessor, now reaches the endpoint of that name if your configuration has one.
Otherwise it raises `NoMethodError`.

### The name of an API in a class

`api :open`, `api :test`, `api :format` and any other name that is already a method
of the class, private ones of `Kernel` included, raise
`ApiRecipes::ApiNameClashError`. 2.x accepted them. Use `as:` to give the method
another name:

```ruby
api :format, as: :formats
```

An API can also be declared only once in a class and its ancestors, modules
included. A second declaration raises the same error. Declare it once and use
`with(...)` where you need other options.

### Credentials with a line break

A credential with a line break or another control character raises
`ApiRecipes::InvalidCredential`. The message never contains the value. So does a
credential that is not a String, such as a Symbol or a number, which 2.x passed
on to http.rb: convert it with `to_s`.

The `headers:` given with a request are checked in the same way before anything
is sent. They must be a Hash (a list of pairs and `HTTP::Headers` are accepted
too), and a name or a value with a control character raises
`ApiRecipes::ConfigurationError`, which names the header and never shows the
value. A tab inside a value is allowed.

### `follow` with something else than `true`, `false` or a Hash

`follow` accepts `true`, `false`, `nil` or a Hash with the keys `strict`,
`max_hops` and `on_redirect`. Anything else raises
`ApiRecipes::ConfigurationError` before the request is sent.

## 3. What changes without a message

Nothing stops here: the code runs and does something different. Search your code
for each case.

### Errors can be rescued with a bare `rescue`

The errors of 2.x inherited from `Exception`, so a bare `rescue` did not catch
them. Now they inherit from `ApiRecipes::Error`, a `StandardError`.

```ruby
begin
  ApiRecipes.github.users.show('octocat').run
rescue => e   # catches ApiRecipes errors now
  notify(e)
end
```

A `rescue => e` or `rescue StandardError` around a call now handles a bad status,
a missing variable and the other errors of the gem as well. Rescue
`ApiRecipes::ResponseCodeNotAsExpected` by name where you meant it. A `rescue
Exception` keeps working.

### Path parameters are encoded

2.x inserted a value into the path as it was. Now each value is encoded:

```ruby
ApiRecipes.github.users.show('a/b').url.to_s
# => "https://api.github.com/users/a%2Fb"
```

- **Values you encoded yourself.** Remove the encoding (`ERB::Util.url_encode`,
  `CGI.escape`): `%2F` would be sent as `%252F`. The gem logs a warning, once for
  each endpoint, when a value looks already encoded.
- **A `/` in a value** that was used to cover several segments is now `%2F`. Write
  the placeholder with a `*` instead: each segment is encoded and the slashes stay.
  The gem logs a warning, once for each endpoint, when a value contains a `/`.

```ruby
ApiRecipes.github.users.files('octocat', 'docs/readme.md').url.to_s
# => "https://api.github.com/users/octocat/files/docs/readme.md"
```

The warnings name the endpoint and never the value. `config.upgrade_warnings = false`
turns them off. Two more effects: a `:` in a value no longer breaks nested
endpoints, and a suffix after a placeholder, as in `/:name.json`, is kept.

### Credentials on an instance take effect

In 2.x `client.github.authorization = '...'` was lost, because every call
returned a new object. Now it is kept for that object. If your code assigned
one and relied on it having no effect, it now sends a credential. The nearest
level wins: the chain (`with`), the object, the class that declares the API,
then the whole application. A credential given as `nil` means "send none".

### Logging

- The default logger writes to STDERR at warn level. In 2.x it wrote to STDOUT at
  debug level. If you read those lines from STDOUT, set `log_to` and `log_level`.
- `print_urls` no longer prints with `puts`: it logs each URL at info level. The
  level of the default logger is `log_level`, then `LOG_LEVEL`, then info when
  `print_urls` is on, otherwise warn: a level you chose is never lowered.
- A debug line per request shows the verb, the URL, the status and the time. It
  never shows a query string, a header, a body or a credential.

### The block of `run`

`run` with a block yields the response and now returns the `Response`. In 2.x it
returned the route, and `route.response` was the response. Code that used the
returned value must use the response.

```ruby
ApiRecipes.github.users.show('octocat').run { |response| response.code }.class
# => "ApiRecipes::Response"
```

### `verify_with` and the message of the error

The message of `ResponseCodeNotAsExpected` no longer contains the response body.
Read it from `error.response`:

```ruby
begin
  ApiRecipes.github.users.show('nobody-here').run
rescue ApiRecipes::ResponseCodeNotAsExpected => e
  e.response.body.to_s
end
```

### An endpoint looks for its options up the tree

In 2.x an endpoint took `timeout`, `on_bad_code` and `mime_type` from the API,
whatever the endpoint that contained it said, and one written without options
did not take `verify_with` from its parent. Now an endpoint that does not set
one of these four options looks for it in the endpoints that contain it, from
the nearest, then in the API, and takes the first value it finds. Look at the
endpoints that set one of them and also contain other endpoints: those now
find it there. `ok_code` is read only on its endpoint.

### Endpoints named like a method

An endpoint called `with`, `definition`, `authorization`, `basic_auth` or `variables`
(on an API), or `run`, `url`, `with` or `definition` (on an endpoint), used to be skipped or to
replace the method. Now no method is generated for it, a warning is logged when the
configuration is loaded, and the endpoint is reached with `[]`:

```ruby
ApiRecipes.github[:with].url.to_s
# => "https://api.github.com/with"
```

### Redirects and credentials

With `follow`, a redirect to another origin drops the `Authorization` header, the
header named by `auth.name`, the `Cookie` header and the credential query
parameter. In 2.x `follow: true` together with a credential sent the credential
to the other host. Cookies that a server sets during a chain of redirects are not
carried to the next hop any more (they were with http.rb 5). A page that sets a
cookie and redirects to itself now ends in the redirect-loop error of http.rb.

### `fill`

`fill` calls only public writers. It used to call private ones, and it swallowed
every error raised by a writer. Make the setters public, and handle the errors you
expect. Keys that are not plain attribute names are skipped.

### Constants seen by a class that includes `ApiRecipes`

A class that includes `ApiRecipes` finds the constants of the gem before the
top-level constants of your application. In 2.x those names were `Api`,
`Endpoint`, `Route`, `Response`, `Settings`, `Configuration` and the error
classes. In 3.0 `Route` and `Settings` are gone, so a top-level `Route` or
`Settings` of yours is found again. `Error`, `Internals`, `VERSION` and the new
error classes (`ConfigurationError`, `CredentialOriginMismatch`,
`InvalidCredential`, `InvalidPathParameter`, `InvalidUrl`, `InvalidVariable`,
`MissingVariable`, `RecipeFileError`, `UnknownEndpoint`) are new, and hide a
top-level constant of yours with the same name. Inside the classes that include
`ApiRecipes`, write it with a leading `::`, for example `::Error`. The
[README](README.md#good-to-know) lists all the names.

### Other changes in results

- The `Response` answers `respond_to?` for the methods it forwards.
- Serializing an API, an endpoint or a response (`Marshal.dump`, `YAML.dump`,
  `as_json`) raises `TypeError`. Serialize `response.data` or
  `response.body.to_s`.
- An object of your class that is restored from a serialized form (`Marshal`,
  YAML) has no credential and inherits none.
- `response.uri` leaves out the credential query parameter when the API declares
  `auth: { type: 'query' }`.
- `response.request` was removed, because the request holds the credentials that
  were sent. `response.uri` and the other readers stay, and the http.rb response
  is still `response.original_response`.
- `response.to_s` returns the body, as the http.rb response does. In 2.x it was
  the default text of the object.
- A redirect to a host with non-ASCII characters needs the `addressable` gem;
  without it the request raises `ApiRecipes::InvalidUrl`.

## 4. What was removed, and what to use instead

| Removed | Use |
| --- | --- |
| `endpoint.route`, `endpoint.route.fill(object)` | `response.fill(object)` |
| `Endpoint#name`, `#params`, `#children`, `#api` | `endpoint.definition` (`name`, `full_name`, `path_params`, `endpoints`, `parent`) |
| `Api#name`, `#configs`, `#base_configs`, `#object` | `api.definition` (`name`, `host`, `timeout`, `endpoints`...) |
| the error classes `RouteAndResourceNamesClashError`, `MissingRouteAttribute`, `ProvidedObjectNotAsResponseData`, `NoConfigurationGivenForEndpoint` | nothing: nothing raised them, so remove the `rescue` clause that names one |
| `ApiRecipes::Route` | nothing: a request is sent with `run` |
| `ApiRecipes::Settings` | nothing: the defaults are in the [options of the README](README.md#api) |
| `response.request` | `response.uri`, or `response.original_response` for the http.rb response |
| `ApiRecipes::RouteNameClashWithExistentMethod` | nothing: a name clash is a warning, and the endpoint is reached with `[]` |
| `ApiRecipes.print_urls` | `config.print_urls = true` inside `ApiRecipes.configure` |
| `configuration.setup` | nothing: `configure` loads the configuration |
| the internal methods of the 2.x core (names with `_aprcps_`, `set_authorization_for_api`, `set_basic_auth_for_api`, `copy_global_authorizations_to_api`) | nothing: they were not part of the public interface |
| `deep_merge`, `deep_symbolize_keys`, `deep_stringify_keys`, `symbolize_keys`, `stringify_keys`, `extract_options!`, `assert_valid_keys` on `Hash` and `Array` | define them in your code, or load ActiveSupport |
| the patch that let `URI` accept underscores in a host (uri older than 1.0) | nothing: `host: billing_service` still works |
| Ruby older than 3.3, http.rb 5 | Ruby 3.3 or higher, http.rb 6 |

```ruby
ApiRecipes.github.definition.endpoints.keys.inspect
# => "[:users, :repos, :with]"

ApiRecipes.github.users.show('octocat').definition.path_params.inspect
# => "[:login]"
```

## 5. What is new

You can adopt these when you are ready. The [README](README.md) describes each one.

- **`[]`**: every endpoint is reachable by name,
  `ApiRecipes.github[:users][:show, 'octocat']`, whatever the name.
- **`with`**: options for one chain or one request, without changing anything
  stored: `ApiRecipes.github.with(host: 'github.example.com')`.
- **Credentials along a chain**: the chain, the object, the class that declares
  the API, then the whole application. A credential is bound to its origin.
- **`variables`**: `{name}` placeholders in `host`, `base_url`, the `path` of an
  endpoint, the values of `default_headers` and `default_params`, and in
  `protocol`, `port`, `timeout`, `on_bad_code`, `mime_type`, `verb` and
  `ok_code`, with values given at any of those levels.
- **`default_params`**: query parameters sent with every request, as
  `default_headers` does for headers. Both can be written on an endpoint: a
  request looks for them on its endpoint, then on each endpoint that contains
  it, then on the API.
- **`resource`**: `resource: true` on an endpoint adds `show`, `create`,
  `update`, `replace` and `delete` under it.
- **`auth`**: says where the credential goes: the `Authorization` header, a header
  of your choice or a query parameter.
- **`ok_code`** accepts a list of statuses, and `response.success?` tells whether a
  response passed the rule of its endpoint.
- **`definition`**, `routes` and a safe `inspect` on APIs and endpoints.
- **Validated configuration**, with every problem reported at once.
- **`config.values`**, which gives each API its credential and the values of
  its variables for the whole application, **`config.upgrade_warnings`** and
  the logging options described above.
- **The `api_recipes` command**, with `upgrade`, `import`, `routes`, `install`,
  `update` and `check`.
- **Portable recipes**: recipes written by others, installed with
  `api_recipes install` and loaded with `config.recipes_paths`. See
  [Portable recipes](README.md#portable-recipes) in the README.

## 6. Security

3.0 changes what the gem does for you. What it does:

- Path parameters are encoded, and `nil`, empty, `.` and `..` are refused.
- Variables are checked where they end up: host, path or header.
- A credential is sent only to the origin it was set for, and a value with a
  control character is refused.
- Redirects to another origin drop the credentials and cookies.
- Logs, error messages of the gem and `inspect` never show a credential, a
  header value, a body or a query string. The `to_h` and the JSON of a
  `definition` hide the values of `default_headers`.
- An API, an endpoint, a response and a definition refuse `Marshal.dump` and
  `YAML.dump`; the first three refuse JSON too.
- Configuration files are read with `YAML.safe_load`.

What stays with your application:

- The gem checks the form of a host, not who owns it. Never pass a value chosen by
  an end user as a whole host (`with(host: ...)`, or a variable that is the entire
  host). Check it against a list of hosts you know.
- `response.original_response` is the raw http.rb response and gives access to the
  request that was sent, headers included. Do not log or serialize it.
- ERB in a configuration file runs code: load only files you trust.

See [Security in the README](README.md#security) for the same list in its place.

## The `api_recipes upgrade` command

The gem installs a command that looks for the changes of this guide. It changes
a file only when you say yes to a change it shows you. Run it in the root of
your project, with no argument:

    $ bundle exec api_recipes upgrade

It finds by itself what to check, and says what it checked:

- **The Ruby files of the project**, `*.rb` and `*.rake`. It leaves out the
  folders `vendor`, `node_modules`, `tmp`, `log`, `coverage`, `public` and
  `storage` at the top of the project, `node_modules` wherever it is, what
  starts with a dot, and every symbolic link. Code that stops working is marked
  `[breaks]`; a line that deserves a look because its result changes is marked
  `[check]`: a manual encoding of a path parameter, a bare `rescue`, `follow:`,
  `response.request`, the removed `Hash` and `Array` methods.
- **What a line alone does not tell.** The command also reads each Ruby file
  as a tree, without running it, and finds: a credential assigned in the body
  of a class, through a variable, over two lines or with `send`; a credential
  that is not text; `api :format` and the other names that are already
  methods; a class that gives an API its own `host`, `protocol` or `port`
  and no credential; `apis_configs` assigned after the files; a block passed
  to `run` whose value is used; `request`, `to_s` and `respond_to?` called on
  what `run` returned, whatever the variable is called; and `Error`,
  `VERSION` or the name of an error of the gem written alone in a class that
  includes `ApiRecipes`. A file that is not valid Ruby is read line by line
  only.
- **The files that describe an API**: the YAML files (`.yml`, `.yaml`, also
  followed by `.erb`) where a name has `endpoints`, each with its options or
  with none, and the files called `NAME.recipe.yml`. Those under `spec`, `test`
  and `features` are fixtures and are left out. Each is checked with the rules
  of 3.0 (marked `[config]`). Two changes that give no error are marked
  `[check]`: `timeout`, `on_bad_code`, `mime_type` or `verify_with` set on an
  endpoint whose inner endpoints do not set it, which now find it there, and
  an endpoint whose name is a method of the object that would have it.
- **Less noise.** A bare `rescue` or a call to `CGI.escape` is in every
  application. The checks that also match code that has nothing to do with the
  gem are applied only to the files whose code names `ApiRecipes` or calls one
  of your APIs by its name, and the one about the `Hash` methods is left out
  when the project has ActiveSupport.
- **A file that contains ERB is checked without running its code.** The value
  that a `<%= ... %>` tag gives is not checked, and the command says how many
  it left out; the other values are. A file where a tag gives a name, a
  mapping or whole lines, or where a `<% ... %>` tag decides which lines exist,
  is not guessed: the command says so, and reads it only with `--erb`, which
  evaluates the file. That runs the code in it, and outside your application a
  value read from the environment may be missing.
- **It gives the code to paste** where what to write is known. The values
  that lines such as `ApiRecipes.print_urls = ...` and
  `ApiRecipes.github.authorization = ...` gave when the application started
  are put together in the whole block of `ApiRecipes.configure`, to paste over
  the one that is there, with the file and its lines. Where what to write
  depends on the code around it, the replacement is shown under the finding.
  The code holds what the line assigned, the value of a credential too, so
  that it works when pasted: `--no-code` leaves it out, as in a CI whose
  output is kept. A line is never printed as it is, and the command copies
  only what it is sure of: one whole expression, with no `if`, `unless`,
  `rescue`, `and` or `or` after it, on a line that is always run.

What needs an answer comes last, where the terminal stops: what was checked,
the changes the command cannot find, the findings, and what to do.

```
Checked 214 Ruby files, 6 of them use api_recipes
Checked 2 configuration files: config/apis/billing.yml, config/apis/github.yml
app/models/shop.rb:4: declares the api 'shopify', and no configuration file found here describes it
config/apis/billing.yml: 2 values come from ERB and were not checked

What this command cannot find
(the list of the changes that a search in the text cannot find)

app/client.rb:5: [breaks] endpoint.route was removed: use response.fill or endpoint.definition
app/client.rb:6: [check] a bare rescue now catches ApiRecipes errors too
config/apis/github.yml: [config] github: unknown option 'hots'

Code to paste

In config/initializers/api_recipes.rb, replace the block of ApiRecipes.configure (lines 1 to 3) with:

    ApiRecipes.configure do |config|
      config.recipes_paths = Dir['config/api_recipes/*.recipe.yml']
      config.values = {
        github: { authorization: "Bearer #{ENV['GITHUB_TOKEN']}" }
      }
    end

Then remove the lines that gave these values: config/initializers/github.rb:1

3 findings

What to do now
  1. Fix the 1 line marked breaks: that code stops working, and each line says what to use instead
  2. Correct what is marked config (1): each is a problem in a file that describes an api
  3. Read the 1 line marked check: the result changes, and only you can tell whether the code still does what it should. A check line is reported at every run
  4. Go through what this command cannot find: look in the code for the changes that concern the project
  5. Run this command again: go on when only check lines that you have read are left
  6. Start the application and run its tests: ApiRecipes.configure checks the whole configuration when it loads, also what an ERB tag gives, and lists every problem at once
```

**On a terminal the command offers to make the changes it is sure of**, one
at a time. Today they are the values that a line gave when the application
started: `ApiRecipes.print_urls = ...` moves into the block of
`ApiRecipes.configure`, and the credentials assigned on `ApiRecipes.NAME`
become `config.values`. For a `rescue` that names no class, or
`StandardError`, it offers to put before it `rescue ApiRecipes::Error` with a
`raise`, which is what 2.x did: the errors of the gem go on to the code that
called. Answer no when that rescue should handle them from now on. Each change
is shown as a diff of the files it touches, and is made only when you answer
`y` or `yes`:

```
Move print_urls into the block of ApiRecipes.configure

config/initializers/api_recipes.rb:1
  ApiRecipes.configure do |config|
    config.recipes_paths = Dir['config/api_recipes/*.recipe.yml']
+   config.print_urls = true
  end
- ApiRecipes.print_urls = true

Make this change? [y/N]
```

- A change is all the files it needs or none: the line that gave the value
  is taken out together with the line that is added.
- It touches only files that git has committed as they are now, so that
  `git diff` shows the change and `git checkout` undoes it. Otherwise the
  command says why, and gives the code to paste as before. A file saved while
  the question waits is not written over: the command says so and writes
  nothing. A file whose lines end with CR LF is left to you.
- A line is taken out only when it is the assignment and nothing else, and
  the value reads nothing that only that place has: a local variable, an
  instance variable, a method of the file. A value given after other code
  that may prepare it, as a `require`, two credentials for one API, a block of
  `configure` that the command cannot read whole or that already assigns the
  value, are left to you, with the code to paste.
- A rescue is changed only in a file that names the gem. A change you refuse
  stays among the findings, with its code to paste. A `rescue` that comes
  after one that catches the errors of the gem first (`ApiRecipes::Error`,
  `StandardError`, `Exception`, or one that names no class) is not a finding.
- Given files or folders to check, the command moves no API to a recipe and
  does not take `apis_files_paths` out: it does not know the rest of the
  project. Run it without arguments in the root of the project for those.
- It asks only when it reads the answers from a terminal and shows the
  results on one. Away from a terminal, as in a CI or with the results sent
  to a file, and with `--no-code`, the command asks nothing and changes
  nothing.

The steps at the end are those of what was found: a kind of finding that is
not there has no step. On a terminal the same results are shown in sections,
with a colour for each kind of finding and lines that fit the width of the
window. Away from a terminal, as in a CI or through a pipe, and with
`NO_COLOR` set, the text is the one above, with no colours.

The line about `api :shopify` is said of a declaration in the code when no file
found in the project describes that API and the code never assigns
`apis_configs`: look for where its description comes from.

To check something else, name it: every directory is searched for `*.rb` and
`*.rake` files, a file you name is read whatever its name, and `--config FILE`,
once for each file, checks a description. Every check then applies to every
file.

    $ api_recipes upgrade app lib --config config/apis/github.yml

The list of the changes that a search in the text cannot find is the same at
every run: you check them by hand, and this guide has the details of each. The
summary line is `Nothing to change`, `1 finding` or `N findings`. When it found
no description of an API it says so instead of `Nothing to change`. The summary
line is left out when there is no finding and something could not be read.

A file or a directory that could not be read (missing, binary, not valid UTF-8,
or not readable for lack of permission) is reported on the error stream, as
`<file>: <reason>`, and is not a finding. The exit code is 1 when there is at
least one finding, even if something could not be read; otherwise it is 2 when
something could not be read, and 0 when there is nothing to change. It can run
in a CI.

The command does not rewrite code: it gives the code to paste where it is sure
of it. What matters most depends on values that exist only when the program
runs, and an automatic rewrite would give a false sense of safety. For those,
use the warnings that the gem logs.
