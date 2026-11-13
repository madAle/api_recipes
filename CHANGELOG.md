## Unreleased

The first pre-release of 3.0. The DSL is the same, and a valid YAML file needs no
change. Read [UPGRADING.md](UPGRADING.md) before you move: it lists what stops, what
changes silently and what was removed, and explains `api_recipes upgrade`, which
looks for them in your code.

#### Requirements

- Requires Ruby >= 3.3 and http.rb 6 (`>= 6.0.4, < 7`). http.rb 5 is no longer
  supported.

#### What stops at once, with a message

- The configuration is validated when `ApiRecipes.configure` ends. Unknown options,
  invalid values and unknown verbs raise `ApiRecipes::ConfigurationError`, which
  lists every problem. Keys starting with `x-` are free. A failed `configure`
  leaves the previous configuration active.
- A `base_url` with a path placeholder is a configuration error: use a variable.
- A credential is valid only for the origin (scheme, host, port) of the level that
  set it. A class with its own `host`, `protocol` or `port` needs its own
  credential, or the request raises `ApiRecipes::CredentialOriginMismatch`.
- A path parameter that is `nil`, empty, `.` or `..` raises
  `ApiRecipes::InvalidPathParameter`.
- `api :open`, `api :test` and other names of existing methods raise
  `ApiNameClashError`; use `as:`. An api can be declared once in a class hierarchy.
- A credential with a line break or a control character raises
  `ApiRecipes::InvalidCredential`.
- Empty names and names with control characters are refused for apis and
  endpoints.
- `follow` accepts only `true`, `false`, `nil` or a Hash with `strict`,
  `max_hops` and `on_redirect`.
- Files are read with `YAML.safe_load`. A missing, empty or invalid file raises
  `ApiRecipes::RecipeFileError`, which names it. A file called `*.recipe.yml` is
  refused.

#### What changes without a message

- The errors inherit from `ApiRecipes::Error < StandardError`, so a bare `rescue`
  catches them.
- Path parameters are encoded one by one: a `/` becomes `%2F`, `*name` covers
  several segments, and a value you encoded yourself is encoded twice. The gem
  logs a warning once per endpoint (`config.upgrade_warnings = false` turns it off).
- Credentials set on a class or an instance take effect.
- The default logger writes to STDERR at warn level, and `print_urls` logs the URL
  at info level instead of printing it. A debug line shows each request: verb,
  URL, status and duration.
- `run` with a block returns the `Response`.
- The message of the error of `verify_with` no longer contains the response body.
- A nested endpoint without options inherits `verify_with` from its parent.
- The sources of the configuration apply in the order they are assigned.
- An endpoint named like a method of the object is no longer skipped or
  replacing it: a warning is logged and it is reached with `[]`.
- A redirect to another origin drops the credentials, the `Cookie` header and the
  credential query parameter. Cookies set during a redirect chain are not carried
  to the next hop.
- `Response#fill` calls only public writers and no longer swallows their errors.
- `Response#uri` leaves out the credential query parameter when the api declares
  `auth: { type: 'query' }`.
- `Api`, `Endpoint` and `Response` refuse serialization.

#### Removed

- `Endpoint#route` and `Route#fill`: use `Response#fill`.
- `Endpoint#name`, `#params`, `#children`, `#api` and `Api#name`, `#configs`,
  `#base_configs`, `#object`: use `definition`.
- `ApiRecipes.print_urls`: use `config.print_urls`.
- The error classes `RouteAndResourceNamesClashError`, `MissingRouteAttribute`,
  `ProvidedObjectNotAsResponseData` and `NoConfigurationGivenForEndpoint`, which
  nothing raised.
- `RouteNameClashWithExistentMethod`, `ApiRecipes::Route`, `ApiRecipes::Settings`,
  `Configuration#setup` and the internal methods of the 2.x core.
- The methods the gem added to `Hash` and `Array`, and the patch of `URI`.

#### New

- Every endpoint is reachable with `[]`: `ApiRecipes.github[:users][:show, 'octocat']`.
- `with` on an api and on an endpoint: options for one chain or one request.
- Credentials and variables are looked up along a chain: `with`, the object, the
  class and its ancestors, the global api. Assigning `nil` means "no credential".
- The `auth` option (`none`, `bearer`, `basic`, `header`, `query`) and the
  `variables` option, with `config.variables`.
- `ok_code` accepts a list of statuses. `Response#success?`.
- `definition` and `definition.routes` on apis and endpoints, and a safe `inspect`.
- `config.upgrade_warnings`, `LOG_LEVEL` in any letter case, `log_to` and
  `log_level` for the default logger.
- The `api_recipes` command with `upgrade`, and the guide UPGRADING.md.
- The examples of README.md and UPGRADING.md are checked by `spec/docs`; every
  protection of the Security section has an example in `spec/security`.

## Version 2.10.4

- Declares `logger` as a dependency: from Ruby 4.0 it is no longer a default gem.
- Adds `ApiRecipes.reset!`, which clears the global configuration and the apis defined
  on the module. It is meant for test suites.
- Adds changelog and source code links to the gem metadata.
- The README is now a complete usage guide.

## Version 2.10.3 - uri 1.x and Ruby 3.4

- `Hash#transform_keys` and `#transform_keys!` are no longer redefined: Ruby's own are
  used. The replacements broke Hash subclasses whose constructor needs arguments (e.g.
  `Dotenv::Environment` in dotenv 3) and the hash argument added in Ruby 3.0.
- Works with the uri gem 1.x: the patch that lets hostnames contain underscores is
  applied only to the RFC 2396 parser of uri < 1.0, since the RFC 3986 parser of
  uri 1.x accepts them already. Requiring api_recipes with uri 1.x raised
  `ArgumentError`.
- Allows http up to 5.x (was `<= 5.1`). http 5.1.0 requires base64 without declaring
  it, so api_recipes failed to load on Ruby 3.4.

## Version 2.10.2

- The default message of `ResponseCodeNotAsExpected` no longer includes the response
  body.

## Version 2.10.1

**SYNTAX COMPLETELY CHANGED**

#### A lot of new stuff

## Version 2.10.0

- Adds the `apis_files_paths` configuration option: api configurations can be loaded
  from YAML files.

## Version 2.9.0

- Requires Ruby >= 2.7.0. Upgrades dependencies.

## Version 2.8.1

- Fixes the deep merge of global configurations.

## Version 2.8.0

- `ResponseCodeNotAsExpected` gives access to the response object.

## Version 2.7.1

- More robust handling of port and protocol settings.

## Version 2.7.0

- Adds the `verify_with` option.

## Version 2.6.2

- Builds urls with `URI::Generic.build2`.

## Version 2.6.1

- Escapes the url path.

## Version 0.6.0 - Default to HTTPS

**POSSIBLE BREAKING CHANGES**

Requests now default to HTTPS. If you still want to use (unsecure) HTTP you have to specify it in your configs through the dedicated `protocol` option e.g.

```yaml
github:
  protocol: http
  host: api.github.com
```

## Version 0.5.0 - Better Exceptions

Exceptions now include attributes that can be accessed during the `rescue` phase in order to execute specific actions
