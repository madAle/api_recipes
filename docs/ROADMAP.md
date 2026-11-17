# Roadmap

What the next major version contains and how it is delivered.

## 3.0

One major version, published in stages as pre-releases. `2.10.x` stays the
stable line until `3.0.0` is final.

| Stage | Content |
| --- | --- |
| `3.0.0.beta1` | the new core, the fixes that change behaviour and the upgrade guide |
| `3.0.0.beta2` | the OpenAPI importer |
| `3.0.0.beta3` | portable recipes and a command to install them; variables in paths, `default_params` and `resource`; options looked for up the tree; values of the application and of a class given at startup |
| `3.0.0.beta4` | `upgrade` without arguments and `convert`, which moves an api of a project to a portable recipe, both with the code to paste; variables in the protocol, the port and the other options of a request |
| `3.0.0` | all of the above, after real use |

A part that is not mature when the others are ships marked as experimental
instead of delaying the release.

### New core

The DSL stays the same: `ApiRecipes.github.users.show('octocat').run`. What
changes is underneath.

- The configuration is compiled once into an immutable tree of endpoint
  definitions, and validated at that moment.
- Every node is reachable by name with `[]`, whatever the name:
  `api[:users][:show, 'octocat']`. An endpoint whose name equals an existing
  method becomes usable.
- The DSL methods are generated once per node and delegate to `[]`. No method is
  defined while a request is being built.
- The URL and the http.rb client are built once, when the request is sent.
- The tree does not depend on where it comes from: YAML files, a Hash and
  imported descriptions are interchangeable sources.
- `with` returns a copy of an api or of an endpoint with some options changed,
  for the chain or the request that follows it, and stores nothing:
  `github.with(host: 'github.example.com')`, `users.show('octocat').with(timeout: 10)`.
- Two api options arrive with `3.0.0.beta1`, because they change how a request
  is made: `auth` says where the credential goes (a header, the query string),
  and `variables` declares `{name}` placeholders for `host`, `base_url` and
  header values, with values taken along the same chain as credentials.
- The credential and the variables that the whole application or a class uses
  are shared by every thread, so they are given where the application starts:
  `config.values` for the application, the options of `api` for a class. The
  writers `authorization=`, `basic_auth=` and `variables=` work on an object
  only; `with` gives a value to one chain.
- `definition` gives a read-only description of an api or of an endpoint, and
  `inspect` never shows a credential.
- Requests are made with http.rb 6 (`>= 6.0.4, < 7`); http.rb 5 is no longer
  supported.

### Fixes that change behaviour

Each item is a known defect of the 2.x line.

| Area | In 2.x | In 3.0 |
| --- | --- | --- |
| Errors | inherit from `Exception`; a bare `rescue` does not catch them | one base class `ApiRecipes::Error < StandardError` |
| Path parameters | inserted as given: `/` spans two segments, `nil` builds the parent URL, a `:` in a value breaks nested endpoints, `/:name.json` loses the suffix | URL encoded per segment; `nil`, empty, `.` and `..` raise |
| Credentials | set on a class api they are lost; set on the global api they are shared by every thread | looked up along a chain: the instance, then its class, then the global api |
| Configuration | unknown options and unknown `on_bad_code` values are accepted silently; `verb` is not checked | validated when the api is configured |
| Api and endpoint names | a name equal to an existing method is skipped silently or replaces that method | reported when the api is configured; reachable with `[]` |
| `verify_with` errors | the message contains the response body | the body stays on `error.response` only |
| `Response` | `respond_to?` is false for the methods it forwards | explicit delegation |
| `fill` | `Route#fill` swallows every error raised by a setter | `Response#fill` skips only missing writers |
| YAML files | a missing or empty file fails without context | a clear `ApiRecipes` error naming the file |
| Core extensions | methods added to `Hash` and `Array`; `URI::DEFAULT_PARSER` replaced with uri < 1.0 | no monkey patches |
| Logging | STDOUT at debug level by default; `print_urls` uses `puts` | silent by default; URLs go to the logger |
| Dead code | unused public methods, constants and four error classes | removed |
| Ruby | `required_ruby_version >= 2.7.0` | Ruby 3.3 or higher |

### Upgrading from 2.x

- `UPGRADING.md` lists what stops with a message, what changes without one,
  what was removed, what is new and what to check for security.
- The gem logs a warning, once for each endpoint, when a path parameter value is
  sent differently than in 2.x. `config.upgrade_warnings = false` turns it off.
- `api_recipes upgrade` searches the Ruby code and the configuration files of an
  application for what changed. It never changes a file.

### OpenAPI importer

A command turns an OpenAPI description into a recipe file, for example:

    $ api_recipes import openapi.yml --only 'repos/*' > config/apis/github.yml

- The description is imported once, not read when the application starts: a
  recipe contains only the endpoints that are used, and stays readable.
- The importer takes host, paths, parameters, expected status codes and the
  kind of authorization. It does not validate requests or responses against
  schemas.
- Paths become the endpoint tree. Several verbs on one path get conventional
  names that can be changed in the generated file.
- OpenAPI is the only imported format. Other formats can be converted to
  OpenAPI with existing tools.
- `api_recipes routes` lists the calls that a recipe offers, with the verb and
  the address: it shows what an import produced.

### Portable recipes

- A recipe meant to be shared is data only: no ERB, declared placeholders for
  host and credentials, and metadata such as name, version and kind of
  authorization.
- Recipes are shared through a Git repository, the
  [cookbook](https://github.com/madAle/api_recipes-cookbook), with contributions
  by pull request. `api_recipes install` downloads a recipe, shows where the
  requests and the credential go and pins its version in `recipes.lock`;
  `api_recipes update` shows what changes before replacing it; `api_recipes
  check` validates a recipe and compares the installed ones with the lock.
- The application loads the installed recipes with `config.recipes_paths` and
  downloads nothing when it starts. A recipe that does not match the lock stops
  the configuration.
- The content of that repository grows on its own schedule and is not a
  requirement for the release.
- A company can keep its recipes in a private repository of its own, reached
  over `https` with the credentials that `git` already has, or over `ssh` with
  its keys.

### Less text for the same API

Four additions arrive with portable recipes, because they are part of what a
recipe can hold.

- A `{name}` variable in the `path` of an endpoint, for a value that many calls
  share and no call should repeat: `/accounts/{account}/orders`.
- `default_params`, the query parameters sent with every request, and
  `default_headers` and `default_params` on an endpoint, for that endpoint and
  the ones below it.
- `resource: true`, which adds the endpoints of a REST resource (`show`,
  `create`, `update`, `replace`, `delete`) under an endpoint.
- An option is written once, at the highest place where it holds: an endpoint
  that does not set `timeout`, `on_bad_code`, `mime_type` or `verify_with`
  looks for it up the tree, in the endpoints that contain it and then in the
  API.

## Later

Additions that do not break existing code.

- Retries, and separate connect and read timeouts.
- Hooks to instrument requests.
- Persistent connections.
- RuboCop, introduced when no feature branch is open.
