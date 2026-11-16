## Unreleased

The third pre-release of 3.0 adds portable recipes: recipes written by others,
which are data only, and the commands that install them.

- `config.recipes_paths` loads the installed recipes. A file there is called
  `NAME.recipe.yml`, holds one api with the key `recipe` (its `name` and
  `version`), is never evaluated with ERB and is read as plain YAML: no anchors,
  aliases, tags or merge keys, no key given twice, only visible text, comments
  included, and limits on its size. It cannot
  carry `verify_with`, cannot take the name of an api that another source
  defines, and a variable of its `host` cannot decide where the host ends.
- Every file of `recipes_paths` must match the checksum that the `recipes.lock`
  of its folder holds for it. A file changed after it was installed, or never
  installed, raises `ApiRecipes::ConfigurationError`.
- `api_recipes install NAME` reads `recipes/NAME.recipe.yml` from the
  [cookbook](https://github.com/madAle/api_recipes-cookbook), or from the Git
  repository given with `--from`, at the head or at the tag `NAME-VERSION` given
  with `--version`. It shows the address, where the credential goes, the
  headers sent with every request, the variables and every call that is not a
  GET, then asks before it writes the
  recipe and `recipes.lock` in `config/api_recipes`, or in the folder given with
  `--to`. `api_recipes install FILE` installs a file. The download is done by
  `git`, over `https` or `ssh` only, without a working copy.
- `api_recipes update NAME` replaces an installed recipe with the one its
  repository has now, after showing what changes in the address, the
  credential, the headers and the verbs.
- `api_recipes check` compares the installed recipes with `recipes.lock`;
  `api_recipes check FILE` says whether a file is a valid portable recipe.
- `api_recipes routes` also reads a portable recipe.
- A `*.recipe.yml` given to `apis_files_paths` is still refused; the message now
  says to give it to `recipes_paths`.
- A private repository of recipes works over `https` with the credentials that
  `git` already has for its host, and over `ssh` with the keys that `ssh`
  already uses: the address is `user@host:path` or `ssh://user@host/path`.
  When the repository asks for credentials that `git` does not have, when `ssh`
  does not know the host or has no key the host accepts, the message says so.

**An endpoint that does not set `timeout`, `on_bad_code` or `mime_type` now
looks for it up the tree**, as it already did for `verify_with`: in the
endpoints that contain it, from the nearest, then in the API. The first value
found is used. In the previous pre-releases and in 2.x the value came from the
API. An option is written once, at the highest place where it holds; `ok_code`
is read only on its endpoint.

It also adds three ways of describing an API with less text. They are part of
what a recipe can hold:

- A `{name}` in the `path` of an endpoint is a variable of the API, as in
  `host` and `base_url`: `/accounts/{account}/orders`. Its value is encoded as
  one segment, and `.`, `..` and an empty value raise
  `ApiRecipes::InvalidVariable`. `definition` has `path_variables`.
  **A word in braces in a path was text in the previous pre-releases and in
  2.x: it is now a variable, and one that is not declared is a configuration
  error. Write `\{word}` to keep the braces as text.**
- `default_params` sends query parameters with every request, as
  `default_headers` does for headers. A value can contain variables. The
  `params:` of a request win on the same name. With `auth.type: query` the
  parameter of the credential cannot be set there. `with` takes
  `default_params` too. `definition` hides the values in `to_h` and `inspect`.
- `default_headers` and `default_params` can be written on an endpoint: they
  hold for that endpoint and for the ones below it, on top of those of the API.
- The name of a header is compared as HTTP does, without its case and with
  `_` read as `-`, wherever a nearer level replaces it: an endpoint, `with` and
  the options of a class. `with(default_headers: { 'accept' => ... })` replaces
  the `Accept` of the API and no longer adds a second header. The same name
  written twice in one `default_headers` is a configuration error.
- `\{` keeps a brace as text in a `base_url` too.
- `resource: true` on an endpoint adds the endpoints `show`, `create`,
  `update`, `replace` and `delete` under it; a list adds only the ones it
  names. An endpoint written with one of those names completes the generated
  one.
- `api_recipes install` and `update` show the parameters sent with every
  request and the headers and parameters that an endpoint adds. A name or a
  value that is cut is followed by its length, and the address is shown whole.
  `update` compares headers and parameters as they are written, and shows one
  line for each that is new, changed or no longer sent, with the whole values.
- A recipe can hold at most 100,000 headers and parameters on its endpoints,
  counting for each endpoint that adds some those of the endpoints above it.

## Version 3.0.0.beta2

The second pre-release of 3.0 adds two commands. Nothing changes in the library.

- `api_recipes import FILE` writes a recipe from an OpenAPI 3.0 or 3.1
  description, YAML or JSON: the address, the variables and the kind of
  authorization, the tree of endpoints with their path parameters and expected
  statuses, and a comment beside each endpoint with the operation it comes from.
  `--name`, `--only`, `--except`, `--server` and `--output` choose the name of
  the api, the paths, the server and where the recipe goes. The description is
  one local file: no other file is read, the network is not used and nothing in
  it is run.
- `api_recipes routes FILE...` lists the calls that the recipes in a file offer,
  with the verb and the address.

## Version 3.0.0.beta1

The first pre-release of 3.0. The DSL is the same, and a YAML file that is valid
for 2.x needs no change, apart from what the configuration check now refuses.
Read [UPGRADING.md](UPGRADING.md) before you move: it lists what stops, what
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
- A word in braces in a value of `default_headers`, such as `{id}`, is a
  variable: one that is not declared is a configuration error.
- A credential is valid only for the origin (scheme, host, port) of the level that
  set it. A class with its own `host`, `protocol` or `port` needs its own
  credential, or the request raises `ApiRecipes::CredentialOriginMismatch`. The
  same error is raised through an api or an endpoint kept in a variable across a
  `configure` that moves the api to another origin.
- A path parameter that is `nil`, empty, `.` or `..` raises
  `ApiRecipes::InvalidPathParameter`.
- `api :open`, `api :test` and other names of existing methods raise
  `ApiNameClashError`; use `as:`. An api can be declared once in a class hierarchy.
- A credential with a line break or a control character, or one that is not a
  String, raises `ApiRecipes::InvalidCredential`.
- The `headers:` of a request must be a Hash, and a control character in a name
  or a value (a tab inside a value is allowed) raises
  `ApiRecipes::ConfigurationError`, which never shows the value.
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
- `Response#request` was removed, because the request holds the credentials;
  `Response#to_s` returns the body.
- A redirect to an address that http.rb reads only with the `addressable` gem
  raises `ApiRecipes::InvalidUrl` when the gem is missing.
- `Api`, `Endpoint` and `Response` refuse serialization, JSON included. A
  definition refuses `Marshal` and YAML, and its JSON is its `to_h`.

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
  `variables` option, with `config.variables`. A class can use the variables of
  the api in its own options, and for an api that only the class declares the
  names given in `variables:` are its variables.
- `ok_code` accepts a list of statuses. `Response#success?`.
- `definition` and `definition.routes` on apis and endpoints, and a safe `inspect`,
  also on the configuration.
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
