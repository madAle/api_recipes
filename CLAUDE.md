# api_recipes

A Ruby gem that turns a YAML description of an HTTP API into a chain of Ruby
methods (`ApiRecipes.github.users.show('octocat').run`). Requests are made with
http.rb. User documentation is in [README.md](README.md).

## Commands

```sh
bundle install
bundle exec rspec                               # whole suite, no network
bundle exec rspec spec/unit/url_building_spec.rb
URI_VERSION='~> 1.0' bundle exec rspec          # pick the uri gem: '~> 1.0' or '< 1.0'
gem build api_recipes.gemspec -o /tmp/check.gem # packaging check
```

SimpleCov writes the coverage report to `coverage/` at every run. On CI the suite
fails under 90% line coverage. What is left uncovered is dead code that 3.0
removes: do not write specs for it.

## Layout

| Path | Role |
| --- | --- |
| `lib/api_recipes.rb` | the `api` class macro, `configure`, global apis, `reset!`, the `URI` patch |
| `lib/api_recipes/configuration.rb` | options of `ApiRecipes.configure`, YAML and ERB loading, logger |
| `lib/api_recipes/api.rb` | one configured api; defines a method per root endpoint |
| `lib/api_recipes/endpoint.rb` | one node of the chain: builds the path, defines nested endpoints |
| `lib/api_recipes/route.rb` | builds the URL and the http.rb client, sends the request, checks the outcome |
| `lib/api_recipes/response.rb` | wraps the http.rb response and adds `data` |
| `lib/api_recipes/settings.rb` | defaults of api and endpoint options |
| `lib/api_recipes/exceptions.rb` | error classes |
| `lib/api_recipes/utils.rb` | methods added to `Hash` and `Array` |
| `spec/unit`, `spec/integration` | specs; integration specs stub HTTP with WebMock |
| `spec/support/test_apis.rb` | shared configuration and helpers for specs |
| `spec/fixtures` | YAML files for configuration specs |
| `examples` | runnable scripts that call public APIs |
| `docs/ROADMAP.md` | what the next major version contains |

## How a call works

1. `ApiRecipes.configure` stores the api descriptions and defines one method per
   api on the `ApiRecipes` module. `api :name` in a class defines the same method
   on the class and on its instances.
2. That method returns an `Api`. Each endpoint method returns a new `Endpoint`,
   which builds its path from the parent path, its own `path` and the arguments.
3. An endpoint with a route creates a `Route`, which builds the URL and the
   http.rb client (headers, timeout, credentials).
4. `run`, or a block, sends the request. `Route` checks the outcome (`ok_code`,
   `on_bad_code`, `verify_with`) and returns a `Response`.

Objects are created again at every step of the chain. Nothing is cached except
the global apis.

## Rules for changes

- Specs never use the network: `WebMock.disable_net_connect!` stays on.
- A spec for existing behaviour must pass without touching `lib/`. Do not write
  a spec that pins one of the known defects listed in `docs/ROADMAP.md`: those
  are going to change.
- A behaviour change comes with its spec, written first.
- The gemspec still declares Ruby `>= 2.7.0`. Until that floor is raised, avoid
  endless `def`, `{ x: }` hash shorthand, the `it` block parameter and `=>`
  pattern matching.
- Do not add monkey patches. `logger` and `http` are the only runtime
  dependencies.
- Every code example in the README must be true: check it against the library
  before changing it.
- Repository content is in English. Commit messages are in English, imperative,
  with no prefix and no trailer, for example `Bump version number`.
- Do not use the em dash character in any file.

## Spec helpers

`spec/spec_helper.rb` calls `ApiRecipes.reset!` before each example and includes
`TestApis`:

- `configure_test_apis(apis = TEST_APIS)` configures ApiRecipes with a silent logger.
- `new_client_class` returns an anonymous class that declares the `svc` and
  `versioned` test apis.
- `base_url` is `https://api.example.test`, the host of the `svc` test api.

Helpers are methods, not constants: a constant of the module is not visible
from an example.

## Releases

The repository uses git-flow: `develop` and `master`, branches `feature/*` and
`release/*`. Tags have the `v` prefix; versions on RubyGems do not.

1. Finish the feature branch into `develop`.
2. Start `release/X.Y.Z`. Rename the `Unreleased` section of `CHANGELOG.md` and
   set `VERSION` in `lib/api_recipes/version.rb`.
3. Merge into `master`, create the annotated tag `vX.Y.Z` with message
   `Version X.Y.Z`, merge back into `develop`, delete the release branch.
   Do these steps by hand: `git flow release finish -m` fails on macOS when the
   message contains spaces.
4. `git push origin master develop vX.Y.Z`, then `bundle exec rake release`
   from `master`.

Never push, tag on the remote or publish without the explicit confirmation of
the maintainer. A version number published on RubyGems cannot be reused.

## Things that surprise

- CI runs on every push to `develop`, `master`, `feature/**`, `release/**` and
  `hotfix/**`: push the branch and read the jobs before merging.
- CI tests only the Ruby versions that are still maintained.
- The "already initialized constant Gem::Platform" warnings printed by Bundler
  come from the local installation, not from the project.
- With two versions of the uri gem installed for the same Ruby, switching
  `URI_VERSION` can fail with "You have already activated uri". Run
  `bundle update uri` after changing it.
- `Gemfile.lock`, `coverage/`, `.superpowers/`, `docs/superpowers/` and
  `docs/decisions/` are not versioned. The last one holds local design notes.
