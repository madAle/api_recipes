# Roadmap

What the next major version contains and how it is delivered.

## 3.0

One major version, published in stages as pre-releases. `2.10.x` stays the
stable line until `3.0.0` is final.

| Stage | Content |
| --- | --- |
| `3.0.0.beta1` | the new core and the fixes that change behaviour |
| `3.0.0.beta2` | the OpenAPI importer |
| `3.0.0.beta3` | portable recipes and a command to install them |
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

### Fixes that change behaviour

Each item is a known defect of the 2.x line. Specs must not pin the present
behaviour of these.

| Area | Today | In 3.0 |
| --- | --- | --- |
| Errors | inherit from `Exception`; a bare `rescue` does not catch them | one base class `ApiRecipes::Error < StandardError` |
| Path parameters | inserted as given: `/` spans two segments, `nil` builds the parent URL, a `:` in a value breaks nested endpoints, `/:name.json` loses the suffix | URL encoded per segment; `nil`, empty, `.` and `..` raise |
| Credentials | set on a class api they are lost; set on the global api they are shared by every thread | looked up along a chain: the instance, then its class, then the global api |
| Configuration | unknown options and unknown `on_bad_code` values are accepted silently; `verb` is not checked | validated when the api is configured |
| Api and endpoint names | a name equal to an existing method is skipped silently or replaces that method | reported when the api is configured; reachable with `[]` |
| `verify_with` errors | the message contains the response body | the body stays on `error.response` only |
| `Response` | `respond_to?` is false for the methods it forwards | explicit delegation |
| `Route#fill` | every error raised by a setter is swallowed | only missing writers are skipped |
| YAML files | a missing or empty file fails without context | a clear `ApiRecipes` error naming the file |
| Core extensions | methods added to `Hash` and `Array`; `URI::DEFAULT_PARSER` replaced with uri < 1.0 | no monkey patches |
| Logging | STDOUT at debug level by default; `print_urls` uses `puts` | silent by default; URLs go to the logger |
| Dead code | unused public methods, constants and four error classes | removed |
| Ruby | `required_ruby_version >= 2.7.0` | the oldest maintained version |

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

### Portable recipes

- A recipe meant to be shared is data only: no ERB, declared placeholders for
  host and credentials, and metadata such as name, version and kind of
  authorization.
- Recipes are shared through a Git repository, with contributions by pull
  request. A command downloads a recipe and pins its version.
- The content of that repository grows on its own schedule and is not a
  requirement for the release.

## Later

Additions that do not break existing code.

- Retries, and separate connect and read timeouts.
- Hooks to instrument requests.
- Persistent connections.
- RuboCop, introduced when no feature branch is open.
