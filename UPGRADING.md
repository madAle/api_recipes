# Upgrading from 2.x to 3.0

Version 3.0 keeps the way you use the gem: the YAML files, `ApiRecipes.configure`,
`api :name` in a class and the chain
`ApiRecipes.github.users.show('octocat').run` work as before. A valid YAML file
needs no change. What changes is how the gem behaves around them: it checks more,
it refuses more, and a few results are different.

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
- **Run `api_recipes upgrade`** on your code and your configuration files (see
  [below](#the-api_recipes-upgrade-command)). It finds the removed
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
configuration in place. Three things are worth knowing:

- Keys that start with `x-` are free. Use them for your own notes.
- A `base_url` with a path placeholder (`:name` or `*name`) is an error. In 2.x
  it silently became a required parameter of every root endpoint. For a value
  that changes, declare a [variable](README.md#variables) and write `{name}`.
- A file that is missing, empty, not valid YAML or not valid UTF-8 raises
  `ApiRecipes::RecipeFileError`, which names the file. Files are read with
  `YAML.safe_load`: plain values, symbols and aliases are accepted, and nothing
  else. A file called `something.recipe.yml` is refused.

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

Set the credential on the class:

```ruby
class EnterpriseClient
  include ApiRecipes
  api :github, host: 'ent.example.test'
end

EnterpriseClient.github.authorization = "Bearer #{ENV.fetch('ENTERPRISE_TOKEN')}"
```

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
`ApiRecipes::InvalidCredential`. The message never contains the value.

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

### Credentials on a class or an instance take effect

In 2.x `MyClass.github.authorization = '...'` was lost, because every call
returned a new object. Now it is stored for the class, and an instance can have its
own. If your code assigned one of them and relied on it having no effect, it now
sends a credential. The nearest level wins: the chain (`with`), the object, its
class and ancestors, then `ApiRecipes.github`. Assigning `nil` means "send none".

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

### Nested endpoints inherit `verify_with`

A nested endpoint written without options, under a parent with `verify_with`, did
not inherit the verification in 2.x. Now every nested endpoint does, unless it
sets its own.

### `apis_configs` after the files

In 2.x, assigning `apis_configs` after `apis_files_paths` discarded what the
files had loaded. Now every source is used, in the order they were assigned, and a
later source replaces an API with the same name. If you assigned `apis_configs` to
get rid of the files, do not assign the files.

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

### Other changes in results

- The `Response` answers `respond_to?` for the methods it forwards.
- Serializing an API, an endpoint or a response (`Marshal.dump`, `YAML.dump`,
  `as_json`) raises `TypeError`. Serialize `response.data` or
  `response.body.to_s`.
- An object of your class that is restored from a serialized form (`Marshal`,
  YAML) has no credential and inherits none.
- `response.uri` leaves out the credential query parameter when the API declares
  `auth: { type: 'query' }`.
- A redirect to a host with non-ASCII characters needs the `addressable` gem;
  without it http.rb raises `LoadError`.

## 4. What was removed, and what to use instead

| Removed | Use |
| --- | --- |
| `endpoint.route`, `endpoint.route.fill(object)` | `response.fill(object)` |
| `Endpoint#name`, `#params`, `#children`, `#api` | `endpoint.definition` (`name`, `full_name`, `path_params`, `endpoints`, `parent`) |
| `Api#name`, `#configs`, `#base_configs`, `#object` | `api.definition` (`name`, `host`, `timeout`, `endpoints`...) |
| the error classes `RouteAndResourceNamesClashError`, `MissingRouteAttribute`, `ProvidedObjectNotAsResponseData`, `NoConfigurationGivenForEndpoint` | nothing: nothing raised them, so remove the `rescue` clause that names one |
| `ApiRecipes::Route` | nothing: a request is sent with `run` |
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
- **Credentials along a chain**: the chain, the object, the class and its
  ancestors, then `ApiRecipes.github`. A credential is bound to its origin.
- **`variables`**: `{name}` placeholders in `host`, `base_url` and the values of
  `default_headers`, with values given at any of those levels.
- **`auth`**: says where the credential goes: the `Authorization` header, a header
  of your choice or a query parameter.
- **`ok_code`** accepts a list of statuses, and `response.success?` tells whether a
  response passed the rule of its endpoint.
- **`definition`**, `routes` and a safe `inspect` on APIs and endpoints.
- **Validated configuration**, with every problem reported at once.
- **`config.variables`**, **`config.upgrade_warnings`** and the logging options
  described above.
- **The `api_recipes` command**, with `upgrade`.

## 6. Security

3.0 changes what the gem does for you. What it does:

- Path parameters are encoded, and `nil`, empty, `.` and `..` are refused.
- Variables are checked where they end up: host, path or header.
- A credential is sent only to the origin it was set for, and a value with a
  control character is refused.
- Redirects to another origin drop the credentials and cookies.
- Logs, error messages, `inspect` and `definition` never show a credential, a
  header, a body or a query string.
- Objects that can hold a secret refuse to be serialized.
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

The gem installs a command that looks for the changes of this guide. It never
changes a file.

    $ api_recipes upgrade app lib --config config/apis/github.yml

- Every directory or file you list is searched for Ruby code that stops working
  (marked `[breaks]`) and for lines that deserve a look because their result
  changes (marked `[check]`): a manual encoding of a path parameter, a bare
  `rescue`, `follow:`, the removed `Hash` and `Array` methods.
- With `--config FILE`, each configuration file is checked with the rules of
  3.0 (marked `[config]`). Use the option once for each file.
- A file that contains ERB is evaluated only with `--erb`, because that runs the
  code in the file. Without it the file is reported and not read.
- The command prints the file, the line and what to do, never the text of the
  line, which could hold a secret.

```
app/client.rb:5: [breaks] endpoint.route was removed: use response.fill or endpoint.definition
app/client.rb:6: [check] a bare rescue now catches ApiRecipes errors too
config/apis/github.yml: [config] github: unknown option 'hots'

(the list of what the command cannot find)

3 findings
```

A directory is searched for `*.rb` files only; a file you name is read whatever
its name. The command then prints the list of changes that a search in the text
cannot find, which you check by hand (this guide has the details of each), and a
summary line: `Nothing to change`, `1 finding` or `N findings`. The summary line
is left out when there is no finding and something could not be read.

A file or a directory that could not be read (missing, binary, not valid UTF-8,
or not readable for lack of permission) is reported on the error stream, as
`<file>: <reason>`, and is not a finding. The exit code is 1 when there is at
least one finding, even if something could not be read; otherwise it is 2 when
something could not be read, and 0 when there is nothing to change. It can run
in a CI.

The command does not rewrite code. What matters most depends on values that exist
only when the program runs, and an automatic rewrite would give a false sense of
safety. For those, use the warnings that the gem logs.
